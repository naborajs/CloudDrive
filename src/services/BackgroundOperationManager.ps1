Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-NSBackgroundOperation(
    [Parameter(Mandatory = $true)]
    [scriptblock]$ScriptBlock,
    [object[]]$ArgumentList = @()
) {
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()

    $powerShell = [System.Management.Automation.PowerShell]::Create()
    $powerShell.Runspace = $runspace

    try {
        [void]$powerShell.AddScript($ScriptBlock.ToString())
        foreach ($argument in $ArgumentList) {
            [void]$powerShell.AddArgument($argument)
        }

        $handle = $powerShell.BeginInvoke()
        return [pscustomobject]@{
            PowerShell = $powerShell
            Runspace = $runspace
            Handle = $handle
            StartedAt = [DateTime]::UtcNow
        }
    } catch {
        $powerShell.Dispose()
        $runspace.Dispose()
        throw
    }
}

function Test-NSBackgroundOperationCompleted([object]$Operation) {
    return ($null -ne $Operation -and $null -ne $Operation.Handle -and $Operation.Handle.IsCompleted)
}

function Complete-NSBackgroundOperation([Parameter(Mandatory = $true)][object]$Operation) {
    if (-not (Test-NSBackgroundOperationCompleted $Operation)) {
        throw 'The background operation has not completed.'
    }

    try {
        $completionError = $null
        try {
            $output = $Operation.PowerShell.EndInvoke($Operation.Handle)
        } catch {
            $output = @()
            $completionError = $_
        }
        $errors = @($Operation.PowerShell.Streams.Error)
        if ($completionError) { $errors += $completionError }
        return [pscustomobject]@{
            Output = @($output)
            Errors = $errors
            HadErrors = [bool]($errors.Count -gt 0 -or $Operation.PowerShell.HadErrors -or $completionError)
            Duration = ([DateTime]::UtcNow - $Operation.StartedAt)
        }
    } finally {
        $Operation.PowerShell.Dispose()
        $Operation.Runspace.Dispose()
    }
}

function Stop-NSBackgroundOperation([object]$Operation) {
    if ($null -eq $Operation) { return }
    try {
        if (-not (Test-NSBackgroundOperationCompleted $Operation)) {
            $Operation.PowerShell.Stop()
        }
    } catch { }
    try { $Operation.PowerShell.Dispose() } catch { }
    try { $Operation.Runspace.Dispose() } catch { }
}
