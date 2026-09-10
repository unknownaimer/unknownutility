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
                if (-not $snap -or -not $snap.Foreground -or -not $snap.Foreground.IsGame) { Write-UTLog 'No game is running right now (for Fortnite use the tweak in the Risky section instead)' -Level Warn; return }
                $p = Get-Process -Id $snap.Foreground.Pid -ErrorAction SilentlyContinue
                if (-not $p) { Write-UTLog 'Process not found' -Level Warn; return }
                try {
                    $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                    Write-UTLog ("{0} (pid {1}) set to High priority for this session" -f $p.ProcessName, $p.Id) -Level Ok
                } catch {
                    Write-UTLog ("{0}: priority change refused ({1}). Anti-cheat protected games block this; for Fortnite use the 'process priority Above Normal' tweak in the Risky section." -f $p.ProcessName, $_.Exception.Message) -Level Warn
                }
            }
            'BtnExportSel' {
                $dlg = New-Object Microsoft.Win32.SaveFileDialog
                $dlg.Filter = 'unknowntweaks selection (*.json)|*.json'
                $dlg.FileName = 'unknowntweaks-selection.json'
                if ($dlg.ShowDialog($sync.form)) { Export-UTSelection -Path $dlg.FileName }
            }
            'BtnImportSel' {
                $dlg = New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Filter = 'unknowntweaks selection (*.json)|*.json'
                if ($dlg.ShowDialog($sync.form)) { Import-UTSelection -Path $dlg.FileName }
            }
            'BtnModeSimple'   { Set-UTMode -Mode 'Simple' }
            'BtnModeAdvanced' { Set-UTMode -Mode 'Advanced' }
            'BtnSimpleUndo'   { Invoke-UTButton -Name 'BtnUndoAll' }
            'BtnSimpleOptimize' {
                $game = [string]$sync.simpleGame
                if (-not $game) { Write-UTLog 'Pick a game first' -Level Warn; return }
                $steps = @(Get-UTSimplePlan -Game $game | Where-Object { $_.Applies })
                $list = ($steps | ForEach-Object { ' - ' + $_.Text }) -join "`n"
                if (-not (Confirm-UTAction -Title ('Optimize for ' + $sync.configs.simple.Games.$game.Content) -Message ("This will run {0} step(s):`n{1}`n`nA restore point is taken first and every tweak is recorded before it changes anything, so Undo everything puts it all back.`n`nGo ahead?" -f $steps.Count, $list))) { return }
                [void](Start-UTUIJob -Kind 'simple' -Arguments @{ Game = $game } -Script 'Invoke-UTSimpleOptimize -Game ([string]$Arguments.Game)')
            }
            'BtnNvProfileApply' {
                $sel = $sync.NvProfileList.SelectedItem
                if (-not $sel) { Write-UTLog 'Select a driver preset first' -Level Warn; return }
                $name = [string]$sel.Tag
                if ($name -eq 'Potato' -and -not (Confirm-UTAction -Title 'Potato driver profile' -Message "This forces anisotropic filtering off and a +3.0 texture LOD bias in the NVIDIA driver profile for Fortnite. Textures will look blurry, which is the point.`n`nThe driver only applies LOD bias on DirectX 11, so tick the -high -d3d11 launch argument too or nothing will change. Restore driver defaults undoes all of it.`n`nApply it?")) { return }
                [void](Start-UTUIJob -Kind 'nvprofile' -Arguments @{ Preset = $name } -Script 'Set-UTNvProfile -PresetName ([string]$Arguments.Preset)')
            }
            'BtnNvProfileRestore' { [void](Start-UTUIJob -Kind 'nvprofile' -Script 'Restore-UTNvProfile') }
            'BtnNvProfileRefresh' { Update-UTNvProfileStatus }
            'BtnFnLiveStatus' {
                if (Start-UTUIJob -Kind 'fnstatus' -Script 'Get-UTFortniteStatus | Out-Null') { $sync.FnLiveStatusBox.Text = 'asking status.epicgames.com...' }
            }
            'BtnVaApply' {
                $sel = $sync.VaProfileList.SelectedItem
                if (-not $sel) { Write-UTLog 'Select a profile first' -Level Warn; return }
                [void](Start-UTUIJob -Kind 'valorant' -Arguments @{ Profile = [string]$sel.Tag } -Script 'Set-UTValorantSettings -ProfileName ([string]$Arguments.Profile)')
            }
            'BtnVaRestore'     { [void](Start-UTUIJob -Kind 'valorant' -Script 'Restore-UTValorantSettings') }
            'BtnVaLaunch'      { [void](Start-UTUIJob -Kind 'valorant' -Script 'Start-UTValorant') }
            'BtnVaShaderCache' { [void](Start-UTUIJob -Kind 'valorant' -Script 'Clear-UTShaderCache') }
            'BtnVaRefresh'     { Update-UTValorantStatus }
            'BtnStretchRefresh' { Update-UTStretchedStatus }
            'BtnStretchAddMode' {
                $r = Get-UTStretchSelection
                if (-not $r) { return }
                [void](Start-UTUIJob -Kind 'stretched' -Arguments @{ W = $r.Width; H = $r.Height } -Script 'Add-UTCustomMode -Width ([int]$Arguments.W) -Height ([int]$Arguments.H)')
            }
            'BtnStretchStart' {
                $r = Get-UTStretchSelection
                if (-not $r) { return }
                $game = 'None'
                if ($sync.StretchGameList.SelectedItem) { $game = [string]$sync.StretchGameList.SelectedItem.Tag }
                $warn = "Switch the desktop to {0}x{1} stretched" -f $r.Width, $r.Height
                if ($game -eq 'Valorant') { $warn += ", disable the monitor device while VALORANT runs (it is re-enabled when the game closes, or from Restore desktop)" }
                if (-not (Confirm-UTAction -Title 'True stretched' -Message ($warn + "?`n`nIf the screen goes black, wait 15 seconds: Windows reverts a mode nobody confirms. Restore desktop puts everything back at any time."))) { return }
                [void](Start-UTUIJob -Kind 'stretched' -Background -Arguments @{ W = $r.Width; H = $r.Height; Game = $game } -Script 'Start-UTStretched -Width ([int]$Arguments.W) -Height ([int]$Arguments.H) -Game ([string]$Arguments.Game)')
            }
            'BtnStretchRestore' { [void](Start-UTUIJob -Kind 'stretched' -Script 'Restore-UTStretched') }
            'BtnGameReadyRefresh' { Initialize-UTGameReadyList }
            'BtnGameReadyClear'   { foreach ($cb in $sync.gameReadyBoxes.Values) { $cb.IsChecked = $false } }
            'BtnGameReadyClose' {
                $names = @($sync.gameReadyBoxes.Keys | Where-Object { $sync.gameReadyBoxes[$_].IsChecked })
                if ($names.Count -eq 0) { Write-UTLog 'Tick the apps to close first' -Level Warn; return }
                $list = @($names | ForEach-Object { ' - ' + [string]$sync.gameReadyBoxes[$_].Content }) -join "`n"
                if (-not (Confirm-UTAction -Title 'Game Ready' -Message ("Close {0} app(s)?`n{1}`n`nUnsaved work in them is lost. Start them again yourself afterwards." -f $names.Count, $list))) { return }
                [void](Start-UTUIJob -Kind 'gameready' -Arguments @{ Names = $names } -Script 'Stop-UTGameReadyProcesses -Names ([string[]]$Arguments.Names) | Out-Null')
            }
            'BtnBenchmark' {
                if (Start-UTUIJob -Kind 'benchmark' -Script 'Invoke-UTBenchmark | Out-Null') { $sync.BenchBox.Text = 'running, about ten seconds...' }
            }
            'BtnRecommendForPc' { Update-UTRecommendPanel }
            'BtnRecommendTick' {
                $n = 0
                foreach ($r in @(Get-UTRecommendations)) {
                    if ($r.Tick -and $sync.tweakBoxes.ContainsKey($r.Id)) { $sync.tweakBoxes[$r.Id].IsChecked = $true; $n++ }
                }
                Write-UTLog ("{0} tweak(s) ticked in TWEAKS for this PC; risky ones are listed but never ticked automatically" -f $n)
            }
            default { Write-UTLog "No action for $Name" -Level Warn }
        }
    } catch {
        Write-UTLog ("{0}: {1}" -f $Name, $_.Exception.Message) -Level Error
        # Never release the lock here: a job may already be running, and unlocking mid-flight would let
        # a second one start against the same registry keys. The worker clears it when it finishes.
    }
}
