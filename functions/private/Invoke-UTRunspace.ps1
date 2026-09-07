function New-UTSessionState {
    <#
    .SYNOPSIS
        InitialSessionState carrying $sync and every *-UT* function, so worker runspaces can call any helper.
    #>
    if ($sync.sessionState) { return $sync.sessionState }
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in (Get-ChildItem -Path function:\ | Where-Object { $_.Name -match '-UT' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $f.Name, $f.Definition))
    }
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null))
    $sync.sessionState = $iss
    return $iss
}

function Start-UTJob {
    <#
    .SYNOPSIS
        Runs a script in a background runspace. The script sees $sync and all UT functions, never WPF objects.
        When it finishes, its Kind is pushed to $sync.jobDone so the UI timer can react.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Script,
        [hashtable]$Arguments
    )
    $wrapped = @"
param(`$Arguments)
`$ErrorActionPreference = 'Stop'
try {
$Script
} catch {
    Write-UTLog ('Job $Kind failed: ' + `$_.Exception.Message) -Level Error
} finally {
    # Announce completion first and release the lock last: between the two the UI thread may start a
    # new job, and clearing status afterwards would report 'ready' while that job is running.
    try { `$sync.jobDone.Enqueue('$Kind') } catch { }
    `$sync.status = 'ready'
    `$sync.busy = `$false
}
"@
    $rs = [runspacefactory]::CreateRunspace((New-UTSessionState))
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($wrapped)
    if ($null -eq $Arguments) { $Arguments = @{} }
    [void]$ps.AddArgument($Arguments)
    $handle = $ps.BeginInvoke()
    $job = @{ Kind = $Kind; PowerShell = $ps; Runspace = $rs; Handle = $handle; Started = (Get-Date) }
    [void]$sync.jobs.Add($job)
    return $job
}

function Remove-UTFinishedJobs {
    <#
    .SYNOPSIS
        Disposes completed worker runspaces and surfaces their error streams. Called from the UI timer.
    #>
    foreach ($job in @($sync.jobs)) {
        if (-not $job.Handle.IsCompleted) { continue }
        try {
            foreach ($e in $job.PowerShell.Streams.Error) { Write-UTLog ("Job {0}: {1}" -f $job.Kind, $e.ToString()) -Level Error }
            $job.PowerShell.EndInvoke($job.Handle) | Out-Null
        } catch {
            Write-UTLog ("Job {0} ended with: {1}" -f $job.Kind, $_.Exception.Message) -Level Error
        }
        try { $job.PowerShell.Dispose(); $job.Runspace.Close(); $job.Runspace.Dispose() } catch { }
        $sync.jobs.Remove($job)
    }
}

function Stop-UTJobs {
    foreach ($job in @($sync.jobs)) {
        try { $job.PowerShell.Stop() } catch { }
        try { $job.PowerShell.Dispose(); $job.Runspace.Close(); $job.Runspace.Dispose() } catch { }
    }
    $sync.jobs.Clear()
}
