function Get-UTStartupApprovedPath {
    <#
    .SYNOPSIS
        The StartupApproved key that holds the enable/disable flag for one startup source.
    .NOTES
        StartupApproved is what Task Manager's Startup tab and the Settings app write. Disabling
        through it leaves the Run value or the shortcut exactly where it is, so an entry can be put
        back byte for byte, and Task Manager agrees with us about the state. Deleting Run values,
        the way most debloat scripts do, is not reversible and hides the entry from the user.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('HKLMRun', 'HKLMRun32', 'HKCURun', 'UserFolder', 'CommonFolder')][string]$Source)
    switch ($Source) {
        'HKLMRun'      { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        'HKLMRun32'    { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        'HKCURun'      { return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        'UserFolder'   { return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
        'CommonFolder' { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder' }
    }
}

function Test-UTStartupApprovedEnabled {
    <#
    .SYNOPSIS
        Reads one 12-byte StartupApproved blob. $true when the entry runs at logon.
    .NOTES
        Byte 0 carries the flag: 0x02 and 0x06 mean enabled, 0x03 means disabled, i.e. bit 0 set is
        "disabled". Bytes 4..11 hold the FILETIME of when it was disabled and are zero while enabled.
        Read off a live Windows 10 19045 machine and matched against the format documented at
        windowsir.blogspot.com. No value at all means nobody ever disabled it, so: enabled.
    #>
    param($Blob)
    $bytes = @($Blob)
    if ($bytes.Count -lt 1 -or $null -eq $bytes[0]) { return $true }
    return ((([int]$bytes[0]) -band 1) -eq 0)
}

function New-UTStartupApprovedBlob {
    <#
    .SYNOPSIS
        Builds the 12-byte StartupApproved value for an enabled or disabled entry.
    .NOTES
        Byte 0 is the flag, bytes 1..3 are padding, bytes 4..11 are the FILETIME of the moment the
        entry was disabled - what Task Manager shows as "Disabled on ...". An enabled entry carries
        a zero timestamp, which is exactly what Windows writes when you tick something back on.
    #>
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    $bytes = New-Object 'byte[]' 12
    if ($Enabled) {
        $bytes[0] = 2
    } else {
        $bytes[0] = 3
        $stamp = [BitConverter]::GetBytes((Get-Date).ToFileTime())
        [Array]::Copy($stamp, 0, $bytes, 4, 8)
    }
    return $bytes
}

function Get-UTLogonTasks {
    <#
    .SYNOPSIS
        Third-party scheduled tasks that fire at logon: the vendor updaters and tray helpers.
    .NOTES
        Tasks under \Microsoft\ are skipped on purpose. The documented telemetry ones are handled by
        name in config/tweaks.json, and the rest of Windows' own logon tasks are not ours to guess at.
    #>
    $out = @()
    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            if ($task.TaskPath -like '\Microsoft\*') { continue }
            $logon = @($task.Triggers | Where-Object { $_ -and $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
            if ($logon.Count -eq 0) { continue }
            $full = $task.TaskPath.TrimEnd('\') + '\' + $task.TaskName
            $cmd = (@($task.Actions | ForEach-Object { [string]$_.Execute }) -join ' ').Trim()
            # A task in the library root has TaskPath '\', which trims to nothing; say where it is.
            $folder = $task.TaskPath.TrimEnd('\')
            if ([string]::IsNullOrEmpty($folder)) { $folder = 'Task Scheduler root' }
            $out += [pscustomobject]@{
                Id      = 'Task|' + $full
                Name    = [string]$task.TaskName
                Command = $cmd
                Source  = 'Task'
                Where   = 'scheduled task at logon'
                Scope   = $folder
                Enabled = ([string]$task.State -ne 'Disabled')
            }
        }
    } catch { }
    return $out
}

function Get-UTStartupItems {
    <#
    .SYNOPSIS
        Everything that runs at logon from the Run keys, the Startup folders and third-party logon
        scheduled tasks, with its current enabled state. The read-only half of the STARTUP tab.
    .NOTES
        Deliberately narrower than Sysinternals Autoruns: no drivers, no services, no COM hijacks,
        no Winlogon, AppInit or image-hijack entries. Those are where Autoruns lets an unsure user
        make a machine unbootable, and none of them are what "too much starts with Windows" means.
    #>
    $items = @()
    $runKeys = @(
        @{ Source = 'HKLMRun';   Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Scope = 'all users' },
        @{ Source = 'HKLMRun32'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Scope = 'all users (32-bit)' },
        @{ Source = 'HKCURun';   Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Scope = 'this account' }
    )
    foreach ($k in $runKeys) {
        if (-not (Test-Path -LiteralPath $k.Path)) { continue }
        $approvedPath = Get-UTStartupApprovedPath -Source $k.Source
        $approved = $null
        if (Test-Path -LiteralPath $approvedPath) { $approved = Get-ItemProperty -LiteralPath $approvedPath -ErrorAction SilentlyContinue }
        $props = Get-ItemProperty -LiteralPath $k.Path -ErrorAction SilentlyContinue
        foreach ($v in @($props.PSObject.Properties)) {
            if ($v.Name -like 'PS*') { continue }
            $blobValue = $null
            if ($approved -and $approved.PSObject.Properties[$v.Name]) { $blobValue = $approved.PSObject.Properties[$v.Name].Value }
            $items += [pscustomobject]@{
                Id      = $k.Source + '|' + $v.Name
                Name    = [string]$v.Name
                Command = [string]$v.Value
                Source  = $k.Source
                Where   = 'registry Run'
                Scope   = $k.Scope
                Enabled = (Test-UTStartupApprovedEnabled -Blob $blobValue)
            }
        }
    }
    $folders = @(
        @{ Source = 'UserFolder';   Path = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup');     Scope = 'this account' },
        @{ Source = 'CommonFolder'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'); Scope = 'all users' }
    )
    foreach ($f in $folders) {
        if (-not (Test-Path -LiteralPath $f.Path)) { continue }
        $approvedPath = Get-UTStartupApprovedPath -Source $f.Source
        $approved = $null
        if (Test-Path -LiteralPath $approvedPath) { $approved = Get-ItemProperty -LiteralPath $approvedPath -ErrorAction SilentlyContinue }
        foreach ($file in @(Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'desktop.ini') { continue }
            $blobValue = $null
            if ($approved -and $approved.PSObject.Properties[$file.Name]) { $blobValue = $approved.PSObject.Properties[$file.Name].Value }
            $items += [pscustomobject]@{
                Id      = $f.Source + '|' + $file.Name
                Name    = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                Command = $file.FullName
                Source  = $f.Source
                Where   = 'Startup folder'
                Scope   = $f.Scope
                Enabled = (Test-UTStartupApprovedEnabled -Blob $blobValue)
            }
        }
    }
    foreach ($t in @(Get-UTLogonTasks)) { $items += $t }
    return @($items | Sort-Object Name)
}

function Set-UTStartupItem {
    <#
    .SYNOPSIS
        Enables or disables one startup entry, the same way Task Manager does.
    .OUTPUTS
        $true when the entry is now in the requested state.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )
    $parts = $Id -split '\|', 2
    if ($parts.Count -ne 2) { Write-UTLog "Malformed startup id $Id" -Level Error; return $false }
    $source = $parts[0]
    $name = $parts[1]
    if ($source -eq 'Task') {
        try {
            $leaf = Split-Path -Path $name -Leaf
            $path = Split-Path -Path $name -Parent
            if ([string]::IsNullOrEmpty($path)) { $path = '\' }
            if (-not $path.StartsWith('\')) { $path = '\' + $path }
            if (-not $path.EndsWith('\')) { $path = $path + '\' }
            $task = Get-ScheduledTask -TaskPath $path -TaskName $leaf -ErrorAction Stop
            if ($Enabled) { $task | Enable-ScheduledTask -ErrorAction Stop | Out-Null }
            else { $task | Disable-ScheduledTask -ErrorAction Stop | Out-Null }
            Write-UTLog ("Logon task {0} -> {1}" -f $leaf, $(if ($Enabled) { 'enabled' } else { 'disabled' }))
            return $true
        } catch {
            Write-UTLog ("Logon task {0} could not be changed: {1}" -f $name, $_.Exception.Message) -Level Error
            return $false
        }
    }
    $approvedPath = Get-UTStartupApprovedPath -Source $source
    $bytes = New-UTStartupApprovedBlob -Enabled $Enabled
    $csv = (@($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ',')
    if (-not (Set-UTRegistry -Path $approvedPath -Name $name -Type Binary -Value $csv)) { return $false }
    Write-UTLog ("Startup entry {0} -> {1}" -f $name, $(if ($Enabled) { 'enabled' } else { 'disabled' }))
    return $true
}

function Set-UTStartupItems {
    <#
    .SYNOPSIS
        Bulk enable/disable from the STARTUP tab. Runs inside a worker runspace.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Ids, [switch]$Enable)
    $want = [bool]$Enable
    $ok = 0
    $failed = 0
    foreach ($id in $Ids) {
        if (Set-UTStartupItem -Id $id -Enabled $want) { $ok++ } else { $failed++ }
    }
    $verb = 'disabled'
    if ($want) { $verb = 'enabled' }
    $msg = 'Startup: {0} {1}, {2} failed' -f $ok, $verb, $failed
    if ($failed -gt 0) { Write-UTLog $msg -Level Warn } else { Write-UTLog $msg -Level Ok }
    if (-not $want -and $ok -gt 0) {
        Write-UTLog 'Nothing was deleted. Every entry is still in the registry or the Startup folder, flagged disabled exactly the way Task Manager flags it, so you can turn any of it back on here or in Task Manager.'
    }
    $sync.status = 'ready'
}
