function Confirm-UTAction {
    param([string]$Title, [string]$Message)
    $r = [System.Windows.MessageBox]::Show($sync.form, $Message, $Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

function Start-UTUIJob {
    <#
    .SYNOPSIS
        UI-side wrapper: refuses when another job runs, flags busy, starts the worker.
    #>
    param([string]$Kind, [string]$Script, [hashtable]$Arguments, [switch]$Background)
    if ($sync.busy) { Write-UTLog 'Another task is still running, wait for it to finish' -Level Warn; return $false }
    # A background job (the automatic region measurement at startup) must not grey out every button.
    if (-not $Background) {
        $sync.busy = $true
        $sync.status = 'working: ' + $Kind
    }
    try {
        [void](Start-UTJob -Kind $Kind -Script $Script -Arguments $Arguments)
        return $true
    } catch {
        if (-not $Background) { $sync.busy = $false; $sync.status = 'ready' }
        Write-UTLog ('Could not start the {0} task: {1}' -f $Kind, $_.Exception.Message) -Level Error
        return $false
    }
}

function Invoke-UTButton {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        switch ($Name) {
            'BtnRecommended' {
                foreach ($id in @($sync.tweakBoxes.Keys)) {
                    $t = $sync.configs.tweaks.$id
                    # Leave out anything this Windows build cannot take, so the preset does not queue up a guaranteed skip.
                    $sync.tweakBoxes[$id].IsChecked = ([bool]$t.Recommended -and $t.Tier -eq 'safe' -and (Test-UTTweakEligible -Tweak $t))
                }
                Write-UTLog 'Recommended (safe) tweaks selected'
            }
            'BtnClearTweaks' { foreach ($cb in $sync.tweakBoxes.Values) { $cb.IsChecked = $false } }
            'BtnApply' {
                $ids = @($sync.tweakBoxes.Keys | Where-Object { $sync.tweakBoxes[$_].IsChecked })
                if ($ids.Count -eq 0) { Write-UTLog 'Nothing selected' -Level Warn; return }
                $risky = @($ids | Where-Object { $sync.configs.tweaks.$_.Tier -eq 'risky' })
                if ($risky.Count -gt 0) {
                    $names = ($risky | ForEach-Object { $sync.configs.tweaks.$_.Content }) -join "`n - "
                    if (-not (Confirm-UTAction -Title 'Risky tweaks selected' -Message ("These change security, boot or driver behaviour and can hurt some PCs:`n - $names`n`nApply them anyway? Undo is available afterwards."))) { return }
                }
                [void](Start-UTUIJob -Kind 'apply' -Arguments @{ Ids = $ids; RestorePoint = [bool]$sync.ChkRestorePoint.IsChecked } -Script @'
if ($Arguments.RestorePoint) { New-UTRestorePoint | Out-Null }
Invoke-UTTweaks -Ids ([string[]]$Arguments.Ids)
'@)
            }
            'BtnUndo' {
                $ids = @($sync.tweakBoxes.Keys | Where-Object { $sync.tweakBoxes[$_].IsChecked })
                if ($ids.Count -eq 0) { Write-UTLog 'Tick the tweaks you want to undo first' -Level Warn; return }
                [void](Start-UTUIJob -Kind 'undo' -Arguments @{ Ids = $ids } -Script 'Invoke-UTTweaks -Ids ([string[]]$Arguments.Ids) -Undo')
            }
            'BtnUndoAll' {
                $ids = @(Get-UTAppliedTweaks)
                if ($ids.Count -eq 0) { Write-UTLog 'Nothing to undo: unknowntweaks has not applied anything on this PC (no snapshots in the backup folder)' -Level Warn; return }
                $names = ($ids | ForEach-Object { ' - ' + $sync.configs.tweaks.$_.Content }) -join "`n"
                if (-not (Confirm-UTAction -Title 'Undo everything' -Message ("Revert all {0} tweak(s) unknowntweaks has applied on this PC?`n`n{1}`n`nEach one goes back to the value that was recorded before it was applied." -f $ids.Count, $names))) { return }
                [void](Start-UTUIJob -Kind 'undo' -Arguments @{ Ids = $ids } -Script 'Invoke-UTTweaks -Ids ([string[]]$Arguments.Ids) -Undo')
            }
            'BtnFnApply' {
                $sel = $sync.FnProfileList.SelectedItem
                $profileName = ''
                if ($sel) { $profileName = [string]$sel.Tag }
                $hidden = @($sync.fnHiddenBoxes.Keys | Where-Object { $sync.fnHiddenBoxes[$_].IsChecked })
                [void](Start-UTUIJob -Kind 'fortnite' -Arguments @{ Profile = $profileName; Hidden = $hidden } -Script 'Set-UTFortniteSettings -ProfileName $Arguments.Profile -HiddenKeys ([string[]]$Arguments.Hidden)')
            }
            'BtnFnRestore'     { [void](Start-UTUIJob -Kind 'fortnite' -Script 'Restore-UTFortniteSettings') }
            'BtnFnLock'        { [void](Start-UTUIJob -Kind 'fortnite' -Script 'Set-UTFortniteReadOnly -ReadOnly $true') }
            'BtnFnUnlock'      { [void](Start-UTUIJob -Kind 'fortnite' -Script 'Set-UTFortniteReadOnly -ReadOnly $false') }
            'BtnFnShaderCache' { [void](Start-UTUIJob -Kind 'fortnite' -Script 'Clear-UTShaderCache') }
            'BtnFnArgsApply' {
                $s = Get-UTArgsString
                [void](Start-UTUIJob -Kind 'fortnite' -Arguments @{ Args = $s } -Script 'Set-UTLaunchArgs -Arguments ([string]$Arguments.Args)')
            }
            'BtnFnArgsClear'   { [void](Start-UTUIJob -Kind 'fortnite' -Script "Set-UTLaunchArgs -Arguments ''") }
            'BtnFnProbe'       { [void](Start-UTUIJob -Kind 'fortnite' -Script 'Start-UTLaunchArgsProbe') }
            'BtnFnProbeDone'   { [void](Start-UTUIJob -Kind 'fortnite' -Script 'Complete-UTLaunchArgsProbe') }
            { $_ -in 'BtnPingRegions', 'BtnPingRegionsSide' } {
                if (Start-UTUIJob -Kind 'regions' -Script 'Measure-UTRegionPing | Out-Null') {
                    $sync.RegionBox.Text = 'pinging 9 hosts x 6 rounds...'
                }
            }
            'BtnTracert' {
                $target = 'ping-nae.ds.on.epicgames.com'
                $best = @($sync.regions | Where-Object { $_.Host -like '*epicgames.com' -and $null -ne $_.AvgMs }) | Select-Object -First 1
                if ($best) { $target = $best.Host }
                [void](Start-UTUIJob -Kind 'net' -Arguments @{ Target = $target } -Script 'Invoke-UTNetworkTool -Tool tracert -Target ([string]$Arguments.Target)')
            }
            'BtnDnsBench' {
                if (Start-UTUIJob -Kind 'dns' -Script 'Invoke-UTDnsBenchmark | Out-Null') {
                    $sync.DnsBox.Text = 'benchmarking (5 uncached queries per resolver)...'
                }
            }
            'BtnDnsSet' {
                $sel = $sync.DnsList.SelectedItem
                if (-not $sel) { Write-UTLog 'Select a resolver first' -Level Warn; return }
                [void](Start-UTUIJob -Kind 'net' -Arguments @{ Provider = [string]$sel.Tag } -Script 'Set-UTDns -Provider ([string]$Arguments.Provider)')
            }
            'BtnDnsReset'  { [void](Start-UTUIJob -Kind 'net' -Script 'Set-UTDns -Reset') }
            'BtnLinkInfo'  { [void](Start-UTUIJob -Kind 'net' -Script 'Invoke-UTNetworkTool -Tool linkinfo') }
            'BtnFlushDns'  { [void](Start-UTUIJob -Kind 'net' -Script 'Invoke-UTNetworkTool -Tool flush') }
            'BtnNetReset' {
                if (Confirm-UTAction -Title 'Reset network stack' -Message "This runs netsh winsock reset and netsh int ip reset.`nIt repairs a broken stack but also removes static IP/DNS settings and per-adapter registry tweaks, and needs a reboot.`n`nContinue?") {
                    [void](Start-UTUIJob -Kind 'net' -Script 'Invoke-UTNetworkTool -Tool reset')
                }
            }
            { $_ -in 'BtnStartupDisable', 'BtnStartupEnable' } {
                $enable = ($Name -eq 'BtnStartupEnable')
                $ids = @($sync.startupBoxes.Keys | Where-Object { $sync.startupBoxes[$_].IsChecked })
                if ($ids.Count -eq 0) { Write-UTLog 'Tick the startup entries you want to change first' -Level Warn; return }
                [void](Start-UTUIJob -Kind 'startup' -Arguments @{ Ids = $ids; Enable = $enable } -Script @'
Set-UTStartupItems -Ids ([string[]]$Arguments.Ids) -Enable:([bool]$Arguments.Enable)
'@)
            }
            'BtnStartupRefresh' { Initialize-UTStartupTab; Write-UTLog 'Startup list re-read' }
            'BtnStartupClear'   { foreach ($cb in $sync.startupBoxes.Values) { $cb.IsChecked = $false } }
            'BtnDebloatRecommended' {
                $n = 0
                foreach ($name in @($sync.debloatBoxes.Keys)) {
                    $rec = [bool]$sync.configs.debloat.$name.Recommended
                    $sync.debloatBoxes[$name].IsChecked = $rec
                    if ($rec) { $n++ }
                }
                Write-UTLog ("{0} app(s) selected: the ones with no gaming or system role" -f $n)
            }
            'BtnDebloatClear' { foreach ($cb in $sync.debloatBoxes.Values) { $cb.IsChecked = $false } }
            'BtnDebloatRemove' {
                $names = @($sync.debloatBoxes.Keys | Where-Object { $sync.debloatBoxes[$_].IsChecked })
                if ($names.Count -eq 0) { Write-UTLog 'Nothing selected' -Level Warn; return }
                $list = ($names | ForEach-Object { ' - ' + [string]$sync.configs.debloat.$_.Content }) -join "`n"
                $deprovision = [bool]$sync.ChkDeprovision.IsChecked
                $extra = ''
                if ($deprovision) { $extra = "`n`nThey will also be deprovisioned, so a new user account or a Windows feature update will not bring them back." }
                if (-not (Confirm-UTAction -Title 'Remove Windows apps' -Message ("Uninstall {0} app(s)?`n{1}`n`nThis is the one thing in unknowntweaks that Undo cannot reverse: the packages are uninstalled, not switched off. The names are saved to backup\removed-apps.txt and you can reinstall any of them from the Microsoft Store.{2}" -f $names.Count, $list, $extra))) { return }
                [void](Start-UTUIJob -Kind 'debloat' -Arguments @{ Names = $names; AllUsers = $deprovision } -Script @'
Remove-UTBloatApps -Names ([string[]]$Arguments.Names) -AllUsers:([bool]$Arguments.AllUsers)
'@)
            }
            'BtnInstall' {
                $names = @($sync.appBoxes.Keys | Where-Object { $sync.appBoxes[$_].IsChecked })
                if ($names.Count -eq 0) { Write-UTLog 'Nothing selected' -Level Warn; return }
                [void](Start-UTUIJob -Kind 'install' -Arguments @{ Names = $names } -Script 'Install-UTApps -Names ([string[]]$Arguments.Names)')
            }
            'BtnAppsClear'   { foreach ($cb in $sync.appBoxes.Values) { $cb.IsChecked = $false } }
            'BtnOpenLogs'    { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $sync.logDir + '"') }
            'BtnOpenBackups' { Start-Process -FilePath explorer.exe -ArgumentList ('"' + $sync.backupDir + '"') }
            'BtnRefreshInfo' { [void](Start-UTUIJob -Kind 'refresh' -Script '$sync.sysinfo = Get-UTSystemInfo; Update-UTTweakStates') }
            'BtnClearLog'    { $sync.ConsoleBox.Clear() }
            'BtnBoostGame' {
                $snap = $sync.metrics.Snapshot
                if (-not $snap -or -not $snap.Foreground -or -not $snap.Foreground.IsGame) { Write-UTLog 'No game window is in the foreground right now (alt-tab back to the game and press this within a second, or use the tweak in the Risky section for Fortnite)' -Level Warn; return }
                $p = Get-Process -Id $snap.Foreground.Pid -ErrorAction SilentlyContinue
                if (-not $p) { Write-UTLog 'Process not found' -Level Warn; return }
                try {
                    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                    Write-UTLog ("{0} (pid {1}) set to High priority for this session" -f $p.ProcessName, $p.Id) -Level Ok
                } catch {
                    Write-UTLog ("{0}: priority change refused ({1}). Anti-cheat protected games block this; for Fortnite use the 'process priority Above Normal' tweak in the Risky section." -f $p.ProcessName, $_.Exception.Message) -Level Warn
                }
            }
            default { Write-UTLog "No action for $Name" -Level Warn }
        }
    } catch {
        Write-UTLog ("{0}: {1}" -f $Name, $_.Exception.Message) -Level Error
        # Never release the lock here: a job may already be running, and unlocking mid-flight would let
        # a second one start against the same registry keys. The worker clears it when it finishes.
    }
}
