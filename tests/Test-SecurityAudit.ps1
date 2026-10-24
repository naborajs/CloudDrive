# Test-SecurityAudit.ps1 - security property regression tests (Phase 16)
#
# Locks the audited security properties into automated checks instead of a
# report nobody can re-run later. Scope: TLS bypass absence, OAuth callback
# validation, credential storage mechanics (DPAPI + strict ACL, no plaintext
# writes), process-argument escaping behavior, registry write scope, and log
# redaction ordering. These verify properties of the CURRENT code; they are
# not a claim that every possible vulnerability has been eliminated.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$failed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failed++; Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

# ---- 1. No TLS / certificate-validation bypass anywhere ----
$allSources = @()
foreach ($root in @((Join-Path $repoRoot 'src'), (Join-Path $repoRoot 'scripts'))) {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        $allSources += [pscustomobject]@{ Path = $file.FullName; Text = (Get-Content -LiteralPath $file.FullName -Raw) }
    }
}
$badTls = @($allSources | Where-Object { $_.Text -match 'ServerCertificateValidationCallback|ServicePointManager|SkipCertificateCheck|CheckCertificateRevocationList\s*=\s*\$?false' })
Assert-True (@($badTls).Count -eq 0) "No TLS or certificate-validation bypass in src/ or scripts/"

# ---- 2. OAuth loopback validation ----
$googlePath = Join-Path $repoRoot 'src\providers\GoogleDriveProvider.ps1'
$google = Get-Content -LiteralPath $googlePath -Raw
Assert-True ($google -match '\$state -ne \$expectedState') 'OAuth callback state is compared exactly with the expected value'
Assert-True ($google -match 'State parameter mismatch \(possible CSRF or invalid request\)') 'State mismatch is treated as a security failure'
Assert-True ($google -match 'HtmlEncode\(\$error\)') 'Untrusted browser-reported error is HTML-encoded before display'

# The response page never includes the authorization code
$responseStart = $google.IndexOf('function Wait-OAuthLoopbackResponse')
$responseBlock = $google.Substring($responseStart, [Math]::Min(3600, $google.Length - $responseStart))
Assert-True ($responseBlock -notmatch '\$code[^\r\n]*OutputStream') 'OAuth response page never echoes the authorization code'

# ---- 3. Credential storage (Google + TeraBox) ----
$state = Get-Content -LiteralPath (Join-Path $repoRoot 'src\models\ConnectionState.ps1') -Raw
$terabox = Get-Content -LiteralPath (Join-Path $repoRoot 'src\providers\TeraBoxProvider.ps1') -Raw
Assert-True ($google -match 'ConvertTo-SecureString|PSCredential') 'Google tokens stored as DPAPI-backed PSCredential'
Assert-True ($google -match 'function Set-StrictCredentialAcl') 'Google credential store applies a strict ACL'
Assert-True ($google -match 'SetAccessRuleProtection\(\$true, \$false\)') 'ACL replaces inherited rights instead of adding on top'
Assert-True ($terabox -match 'ConvertTo-SecureString|PSCredential') 'TeraBox session stored as DPAPI-backed PSCredential'
Assert-True ($terabox -match 'function Set-StrictTeraBoxCredentialAcl') 'TeraBox credential store applies a strict ACL'
Assert-True ($state -match 'ndus' -and $state -match 'bduss') 'Session-cookie key material is covered by the shared sanitizer'

# No plaintext credential writes: a write call followed by password/ndus/bduss/token on the same line
$plaintextViolations = @($allSources | Where-Object { $_.Text -match "(?im)(Set-Content|Out-File|WriteAllText|Add-Content)[^\r\n]*\b(password|ndus\s*=|BDUSS\s*=|access_token)\b" })
Assert-True (@($plaintextViolations).Count -eq 0) "No code path writes credential material via plain file writes (violations: $(@($plaintextViolations | ForEach-Object { [System.IO.Path]::GetFileName($_.Path) } | Select-Object -Unique) -join ', '))"

# ---- 4. Process argument escaping (behavioral, real generators) ----
$originalLocalAppData = $env:LOCALAPPDATA
$sandbox = Join-Path $env:TEMP ('NSCloudDrive_SecurityAudit_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:LOCALAPPDATA = $sandbox
try {
    . (Join-Path $repoRoot 'scripts\CachePathSafety.ps1')
    . (Join-Path $repoRoot 'src\models\ConnectionState.ps1')
    . (Join-Path $repoRoot 'src\services\SettingsManager.ps1')
    . (Join-Path $repoRoot 'src\services\TeraBoxBridgeManager.ps1')
    . (Join-Path $repoRoot 'src\services\VirtualDriveManager.ps1')

    $mount = [pscustomobject]@{ Plain = (Format-SafeProcessArgument 'plainarg'); Letter = (Format-SafeProcessArgument 'G:') }
    Assert-True (($mount.Plain -eq 'plainarg') -and ($mount.Letter -eq 'G:')) 'Plain arguments stay unquoted'
    Assert-True ((Format-SafeProcessArgument 'with space') -eq '"with space"') 'Spaced arguments are quoted'
    Assert-True ((Format-SafeProcessArgument 'quote " inject') -eq ('"quote \" inject"')) 'Injected quotes are escaped inside quoting'
    Assert-True ((Format-SafeProcessArgument 'path\one\') -eq ('"path\one\\"')) 'Trailing backslashes are doubled under quoting for Windows parsing'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    # The sandbox was LOCALAPPDATA during the dot-sources; delete only it.
    try { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

# Both helper implementations must share one escaping policy (identical body).
$mountHelper = Get-Content -LiteralPath (Join-Path $repoRoot 'src\services\VirtualDriveManager.ps1') -Raw
$transferHelper = Get-Content -LiteralPath (Join-Path $repoRoot 'src\services\CloudTransferManager.ps1') -Raw
$mountBody = [regex]::Match($mountHelper, 'function Format-SafeProcessArgument[\s\S]*?\n\}').Value
$transferBody = [regex]::Match($transferHelper, 'function Format-SafeProcessArgument[\s\S]*?\n\}').Value
Assert-True ($mountBody.Length -gt 0 -and $transferBody.Length -gt 0) 'Both escaping helpers exist'
Assert-True (($mountBody -replace '\s', '') -eq ($transferBody -replace '\s', '')) 'Both escaping helpers share one identical policy (no divergent behavior)'

# ---- 5. Registry write scope ----
$explorer = Get-Content -LiteralPath (Join-Path $repoRoot 'src\services\ExplorerIntegration.ps1') -Raw
Assert-True ($explorer -match 'HKEY_CURRENT_USER|HKCU') 'Explorer icons live under per-user registry'
Assert-True ($explorer -notmatch "(?im)(New-Item|Set-Item|Set-ItemProperty|Remove-Item|Get-Item|Remove-ItemProperty)[^\r\n]*HKEY_LOCAL_MACHINE") 'No HKLM registry access in Explorer integration (code, not comments)'
Assert-True ($explorer -match 'NSCloudDriveOwner') 'App-owned icon entries carry an owner marker'
Assert-True ($explorer -match "State = 'Conflict'") 'Foreign icon registrations fail closed instead of being overwritten'

# ---- 6. Log writes sanitize before storing permanently ----
Assert-True ($state -match 'message\s*=\s*\(Format-SanitizedDiagnosticMessage \$Message\)') 'Shared log entries are sanitized BEFORE the file write'
Assert-True ($state -match 'ApplicationLogRotateBytes = 2MB') 'Shared log has a bounded size'

if ($failed -gt 0) { throw "$failed security assertions failed." }
Write-Output '  [PASS] Security property regression suite passed.'
