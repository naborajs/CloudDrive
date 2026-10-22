[CmdletBinding()]
param(
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra')
)

$ErrorActionPreference = 'Stop'

$repository = 'https://github.com/gulp79/rclone-extra.git'
$tag = 'v1.75.2-extra'
$expectedCommit = '56bf13885494819bc801302ddf881279bdac7262'
$patchPath = Join-Path $PSScriptRoot '..\patches\rclone-terabox-v1.75.2-extra-secret-safety.patch'
$sourcePath = Join-Path $BuildRoot 'source'
$executablePath = Join-Path $BuildRoot 'rclone.exe'

if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
    throw "Required source patch was not found: $patchPath"
}
if (Test-Path -LiteralPath $BuildRoot) {
    throw "Build folder already exists; choose a new -BuildRoot to avoid changing existing files: $BuildRoot"
}
foreach ($tool in @('git', 'go')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required build tool is missing from PATH: $tool"
    }
}

$goVersionText = (& go version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $goVersionText -notmatch 'go version go(?<major>\d+)\.(?<minor>\d+)') {
    throw 'Could not determine the installed Go version.'
}
if ([int]$Matches.major -lt 1 -or ([int]$Matches.major -eq 1 -and [int]$Matches.minor -lt 26)) {
    throw "Go 1.26 or newer is required by the pinned source; found: $goVersionText"
}

New-Item -ItemType Directory -Path $BuildRoot | Out-Null
& git clone --depth 1 --branch $tag $repository $sourcePath
if ($LASTEXITCODE -ne 0) { throw 'Could not clone the pinned public source tag.' }

$actualCommit = (& git -C $sourcePath rev-parse HEAD | Out-String).Trim()
if ($actualCommit -ne $expectedCommit) {
    throw "Pinned source commit mismatch: expected $expectedCommit, found $actualCommit"
}

& git -C $sourcePath apply --check $patchPath
if ($LASTEXITCODE -ne 0) { throw 'The security patch does not apply cleanly to the pinned source.' }
& git -C $sourcePath apply $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Could not apply the security patch.' }

$previousEnvironment = @{
    GOOS = $env:GOOS
    GOARCH = $env:GOARCH
    CGO_ENABLED = $env:CGO_ENABLED
}

try {
    $env:GOOS = 'windows'
    $env:GOARCH = 'amd64'
    # cgofuse supports !cgo on Windows; keep the source build independent of
    # MinGW and WinFsp development headers. WinFsp is still required at runtime.
    $env:CGO_ENABLED = '0'

    $linkFlags = "-s -w -buildid= -X github.com/rclone/rclone/fs.Version=$tag"
    Push-Location $sourcePath
    try {
        & go build -v -trimpath -mod=readonly -tags cmount -ldflags $linkFlags -o $executablePath .
        if ($LASTEXITCODE -ne 0) { throw 'The backend-enabled Windows build failed.' }
    }
    finally {
        Pop-Location
    }
}
finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}

$versionOutput = (& $executablePath version | Out-String)
if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch '(?m)^go/tags:.*\bcmount\b') {
    throw 'Built executable did not report the required cmount build tag.'
}
if ($versionOutput -notmatch '(?m)^os/arch: windows/amd64') {
    throw 'Built executable does not report the expected Windows amd64 target.'
}

$providersOutput = (& $executablePath --config= config providers | Out-String)
if ($LASTEXITCODE -ne 0 -or $providersOutput -notmatch '(?i)terabox') {
    throw 'Built executable did not report the TeraBox provider.'
}

$manifest = [ordered]@{
    sourceRepository = $repository
    sourceTag = $tag
    sourceCommit = $actualCommit
    patchSha256 = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
    executableSha256 = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    target = 'windows/amd64'
    buildTag = 'cmount'
    backend = 'terabox'
}
$manifestPath = Join-Path $BuildRoot 'rclone.build.json'
$manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Output "Build verified: $executablePath"
Write-Output "Build record: $manifestPath"
Write-Output "SHA-256: $($manifest.executableSha256)"
Write-Output 'This verifies provider registration and mount build tags only; it does not authenticate or test a TeraBox account.'
