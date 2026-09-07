function Invoke-UTScript {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Script)
    $block = [scriptblock]::Create($Script)
    & $block
}

function Test-UTTweakGuard {
    <#
    .SYNOPSIS
        Runs a tweak's GuardScript BEFORE anything is snapshotted or changed. A guard that throws stops
        the tweak cleanly, leaving no snapshot and no "applied" label behind.
    #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$Tweak)
    foreach ($g in @($Tweak.GuardScript | Where-Object { $_ })) {
        Invoke-UTScript -Name $Id -Script $g
    }
}
function Test-UTTweakEligible {
    <#
    .SYNOPSIS
        $true when this Windows build is new enough for the tweak.
    .DESCRIPTION
        A tweak that names a MinBuild the machine does not meet is not a failure, it simply does not
        exist on this Windows. The UI says so on the label and leaves it out of the recommended
        preset, so "Select recommended" does not end in red on every Windows 10 machine.
    #>
    param([Parameter(Mandatory = $true)]$Tweak)
    if (-not $Tweak.MinBuild) { return $true }
    if (-not $sync.sysinfo) { return $true }
    return ([int]$sync.sysinfo.Build -ge [int]$Tweak.MinBuild)
}


function Invoke-UTTweakApply {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$Tweak)
    if (-not (Test-UTTweakEligible -Tweak $Tweak)) {
        # Not a failure: the tweak simply does not exist on this Windows. Reporting it as one makes
        # "Select recommended" end in red on every Windows 10 machine.
        Write-UTLog ("{0} needs Windows build {1} or newer and this PC is {2}, so it was skipped." -f $Tweak.Content, $Tweak.MinBuild, $sync.sysinfo.Build) -Level Warn
        return 'skipped'
    }
    if ($Tweak.LaptopWarning -and $sync.sysinfo -and $sync.sysinfo.IsLaptop) {
        Write-UTLog "Laptop detected: $($Tweak.LaptopWarning)" -Level Warn
    }
    # Anything that can refuse this tweak runs first, so a refusal cannot leave a half-applied machine.
    Test-UTTweakGuard -Id $Id -Tweak $Tweak

    if (Test-UTBackupExists -Id $Id) {
        Write-UTLog "$($Tweak.Content) is already applied; re-running it would record the tweaked values as the originals, so it was skipped. Undo it first if you want to apply it again." -Level Warn
        return 'skipped'
    }

    Save-UTBackup -Id $Id -Tweak $Tweak
    $failed = 0
    foreach ($r in @($Tweak.registry | Where-Object { $_ })) {
        if (-not (Set-UTRegistry -Path $r.Path -Name $r.Name -Type $r.Type -Value ([string]$r.Value))) { $failed++ }
    }
    foreach ($s in @($Tweak.service | Where-Object { $_ })) {
        if (-not (Set-UTService -Name $s.Name -StartupType $s.StartupType)) { $failed++ }
    }
    foreach ($t in @($Tweak.ScheduledTask | Where-Object { $_ })) {
        if (-not (Set-UTScheduledTask -Name $t.Name -State $t.State)) { $failed++ }
    }
    foreach ($script in @($Tweak.InvokeScript | Where-Object { $_ })) {
        Invoke-UTScript -Name $Id -Script $script
    }
    if ($failed -gt 0) { throw "$failed change(s) could not be made; the snapshot was kept so Undo still works" }
    return 'done'
}

function Invoke-UTTweakUndo {
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)]$Tweak, [switch]$Force)
    $backup = Get-UTBackup -Id $Id
    if (-not $backup) {
        if (-not $Force) {
            # Without a snapshot the tool would be writing its own idea of the Windows default onto a
            # machine it may never have touched. Refuse instead of guessing.
            Write-UTLog "$($Tweak.Content) was not applied by unknowntweaks on this PC (no snapshot), so there is nothing to undo. Nothing was changed." -Level Warn
            return 'skipped'
        }
        Write-UTLog "No snapshot for $($Tweak.Content); forcing the documented Windows defaults" -Level Warn
    } else {
        Write-UTLog "Restoring from the snapshot taken when $Id was applied"
    }

    # The snapshot, not the catalogue, is the record of what this machine actually had changed. An
    # entry dropped from config/tweaks.json after someone applied it would otherwise never be put
    # back: the undo would walk the new, shorter list and silently leave the old change in place.
    $failed = 0
    $regTargets = @()
    foreach ($r in @($Tweak.registry | Where-Object { $_ })) {
        $regTargets += [pscustomobject]@{ Path = [string]$r.Path; Name = [string]$r.Name; Type = [string]$r.Type; OriginalValue = [string]$r.OriginalValue }
    }
    foreach ($e in @($backup.Registry | Where-Object { $_ })) {
        if (@($regTargets | Where-Object { $_.Path -eq $e.Path -and $_.Name -eq $e.Name }).Count -gt 0) { continue }
        Write-UTLog ("{0}\{1} is in the snapshot but no longer in the catalogue; restoring it anyway" -f $e.Path, $e.Name)
        $regTargets += [pscustomobject]@{ Path = [string]$e.Path; Name = [string]$e.Name; Type = [string]$e.Kind; OriginalValue = '' }
    }
    foreach ($r in $regTargets) {
        $entry = $null
        if ($backup -and $backup.Registry) {
            $entry = @($backup.Registry) | Where-Object { $_.Path -eq $r.Path -and $_.Name -eq $r.Name } | Select-Object -First 1
        }
        $ok = $true
        if ($entry) {
            if ($entry.Exists) { $ok = Set-UTRegistry -Path $r.Path -Name $r.Name -Type $entry.Kind -Value ([string]$entry.Value) }
            else { $ok = Set-UTRegistry -Path $r.Path -Name $r.Name -Type $r.Type -Value '<RemoveEntry>' }
        } else {
            $orig = [string]$r.OriginalValue
            if ([string]::IsNullOrEmpty($orig)) { $orig = '<RemoveEntry>' }
            $ok = Set-UTRegistry -Path $r.Path -Name $r.Name -Type $r.Type -Value $orig
        }
        if (-not $ok) { $failed++ }
    }

    $svcNames = @(@($Tweak.service | Where-Object { $_ }) | ForEach-Object { [string]$_.Name })
    foreach ($e in @($backup.Service | Where-Object { $_ })) {
        if ($e.Name -and $svcNames -notcontains [string]$e.Name) {
            Write-UTLog ("Service {0} is in the snapshot but no longer in the catalogue; restoring it anyway" -f $e.Name)
            $svcNames += [string]$e.Name
        }
    }
    foreach ($name in $svcNames) {
        $target = $null
        if ($backup -and $backup.Service) {
            $entry = @($backup.Service) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($entry -and $entry.StartupType) { $target = [string]$entry.StartupType }
        }
        if (-not $target) {
            $cfg = @($Tweak.service | Where-Object { $_ -and $_.Name -eq $name }) | Select-Object -First 1
            if ($cfg) { $target = [string]$cfg.OriginalType }
        }
        if ($target) { if (-not (Set-UTService -Name $name -StartupType $target)) { $failed++ } }
    }

    $taskNames = @(@($Tweak.ScheduledTask | Where-Object { $_ }) | ForEach-Object { [string]$_.Name })
    foreach ($e in @($backup.Task | Where-Object { $_ })) {
        if ($e.Name -and $taskNames -notcontains [string]$e.Name) {
            Write-UTLog ("Task {0} is in the snapshot but no longer in the catalogue; restoring it anyway" -f $e.Name)
            $taskNames += [string]$e.Name
        }
    }
    foreach ($name in $taskNames) {
        $target = $null
        if ($backup -and $backup.Task) {
            $entry = @($backup.Task) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($entry -and $entry.State) { $target = [string]$entry.State }
        }
        if (-not $target) {
            $cfg = @($Tweak.ScheduledTask | Where-Object { $_ -and $_.Name -eq $name }) | Select-Object -First 1
            if ($cfg) { $target = [string]$cfg.OriginalState }
        }
        if ($target -in 'Enabled', 'Disabled') { if (-not (Set-UTScheduledTask -Name $name -State $target)) { $failed++ } }
    }

    foreach ($script in @($Tweak.UndoScript | Where-Object { $_ })) {
        Invoke-UTScript -Name $Id -Script $script
    }
    if ($failed -gt 0) { throw "$failed change(s) could not be reverted; the snapshot was kept so you can retry" }
    Remove-UTBackup -Id $Id
    return 'done'
}

function Invoke-UTTweaks {
    <#
    .SYNOPSIS
        Applies or undoes a list of tweak ids from $sync.configs.tweaks. Runs inside a worker runspace.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Ids, [switch]$Undo, [switch]$Force)
    $verb = 'Applying'
    if ($Undo) { $verb = 'Undoing' }
    $ok = 0; $failed = 0; $skipped = 0; $reboot = $false; $signOut = $false
    foreach ($id in $Ids) {
        $tweak = $sync.configs.tweaks.$id
        if (-not $tweak) { Write-UTLog "Unknown tweak id $id" -Level Warn; continue }
        $sync.status = '{0}: {1}' -f $verb, $tweak.Content
        Write-UTLog ('----- {0}: {1}' -f $verb, $tweak.Content)
        try {
            # The worker reports what it did; inferring it from the snapshot file would miscount one-shot
            # actions (clearing temp files), which deliberately leave no snapshot behind.
            $result = if ($Undo) { Invoke-UTTweakUndo -Id $id -Tweak $tweak -Force:$Force } else { Invoke-UTTweakApply -Id $id -Tweak $tweak }
            if (@($result) -contains 'skipped') {
                $skipped++
            } else {
                $ok++
                if ($tweak.Reboot) { $reboot = $true }
                if ($tweak.SignOut) { $signOut = $true }
            }
        } catch {
            $failed++
            Write-UTLog ('{0} failed: {1}' -f $tweak.Content, $_.Exception.Message) -Level Error
        }
    }
    $summary = '{0} done: {1} succeeded, {2} failed, {3} skipped' -f $verb, $ok, $failed, $skipped
    if ($failed -gt 0) { Write-UTLog $summary -Level Warn } else { Write-UTLog $summary -Level Ok }
    if ($reboot) { Write-UTLog 'At least one change needs a reboot to take effect' -Level Warn }
    elseif ($signOut) { Write-UTLog 'At least one change needs a sign-out (or reboot) to take effect' -Level Warn }
    # Never clear a pending reboot that an earlier run raised.
    if ($reboot) { $sync.needReboot = $true }
    $sync.status = 'ready'
}
