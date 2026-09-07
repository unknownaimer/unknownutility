function Get-UTScheduledTaskParts {
    param([Parameter(Mandatory = $true)][string]$FullName)
    $leaf = Split-Path -Path $FullName -Leaf
    $folder = Split-Path -Path $FullName -Parent
    if ([string]::IsNullOrEmpty($folder)) { $folder = '\' }
    if (-not $folder.StartsWith('\')) { $folder = '\' + $folder }
    if (-not $folder.EndsWith('\')) { $folder = $folder + '\' }
    return @{ Path = $folder; Name = $leaf }
}

function Get-UTScheduledTaskState {
    <#
    .SYNOPSIS
        Returns 'Enabled', 'Disabled', or $null when the task does not exist on this build.
    #>
    param([Parameter(Mandatory = $true)][string]$FullName)
    $parts = Get-UTScheduledTaskParts -FullName $FullName
    $task = Get-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    if ([string]$task.State -eq 'Disabled') { return 'Disabled' }
    return 'Enabled'
}

function Set-UTScheduledTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Enabled', 'Disabled')][string]$State
    )
    $parts = Get-UTScheduledTaskParts -FullName $Name
    $task = Get-ScheduledTask -TaskPath $parts.Path -TaskName $parts.Name -ErrorAction SilentlyContinue
    if (-not $task) { Write-UTLog "Task $($parts.Name) not present on this Windows build, skipped"; return $true }
    try {
        if ($State -eq 'Disabled') { $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null }
        else { $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null }
        Write-UTLog "Task $($parts.Name) -> $State"
        return $true
    } catch {
        Write-UTLog "Task $($parts.Name) could not be changed: $($_.Exception.Message)" -Level Error
        return $false
    }
}
