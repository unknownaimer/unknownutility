function Invoke-UTNative {
    <#
    .SYNOPSIS
        Runs a console executable and returns its combined output and exit code.
    .DESCRIPTION
        Worker runspaces run with $ErrorActionPreference = 'Stop'. In Windows PowerShell 5.1 a native
        command's stderr redirected with 2>&1 arrives as ErrorRecords, which that preference turns into
        terminating errors, so a tool that merely prints a warning to stderr would abort the whole job.
        This runs the command with the preference relaxed and reports the exit code instead.
    .OUTPUTS
        A hashtable with Output (string), Lines (string[]) and ExitCode.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
        return @{ Output = ($lines -join [Environment]::NewLine); Lines = $lines; ExitCode = $code }
    } catch {
        return @{ Output = $_.Exception.Message; Lines = @([string]$_.Exception.Message); ExitCode = -1 }
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Write-UTLog {
    <#
    .SYNOPSIS
        Logs a line to the UI console (through a thread-safe queue), the log file, and the host.
    .NOTES
        Safe to call from any runspace: it never touches WPF objects. The UI timer drains $sync.log.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Level = 'Info'
    )
    $tag = switch ($Level) { 'Ok' { ' OK ' } 'Warn' { 'WARN' } 'Error' { 'ERR ' } default { 'INFO' } }
    $line = '[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $tag, $Message
    try { if ($sync.log) { $sync.log.Enqueue($line) } } catch { }
    try { if ($sync.logPath) { Add-Content -LiteralPath $sync.logPath -Value $line -ErrorAction SilentlyContinue } } catch { }
    if (-not $sync.form) {
        $color = switch ($Level) { 'Ok' { 'Green' } 'Warn' { 'Yellow' } 'Error' { 'Red' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
}
