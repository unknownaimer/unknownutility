function New-UTTextBlock {
    param([string]$Text, [string]$StyleKey = 'Body', [string]$Color)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    if ($StyleKey) { $tb.Style = $sync.form.FindResource($StyleKey) }
    if ($Color) { $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color)) }
    return $tb
}

function New-UTToolTip {
    <#
    .SYNOPSIS
        The hover card behind every checkbox: what the item does, and for tweaks, why it works and
        where that comes from. The list itself stays to one line per item.
    #>
    param([string]$Description, [string]$Evidence)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.MaxWidth = 560
    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $Description
    $d.TextWrapping = 'Wrap'
    [void]$sp.Children.Add($d)
    if ($Evidence) {
        $h = New-Object System.Windows.Controls.TextBlock
        $h.Text = 'WHY IT WORKS'
        $h.FontWeight = 'Bold'
        $h.Margin = '0,8,0,2'
        $h.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#4EC9B0'))
        [void]$sp.Children.Add($h)
        $e = New-Object System.Windows.Controls.TextBlock
        $e.Text = $Evidence
        $e.TextWrapping = 'Wrap'
        [void]$sp.Children.Add($e)
    }
    return $sp
}

function New-UTCheckBox {
    param([string]$Id, [string]$Content, [string]$Description, [string]$Evidence, [System.Windows.Controls.Panel]$Panel, [bool]$Checked = $false)
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $Content
    $cb.Tag = $Id
    $cb.IsChecked = $Checked
    if ($Description -or $Evidence) {
        $cb.ToolTip = New-UTToolTip -Description $Description -Evidence $Evidence
        # The default 5 s is not enough to read an evidence card.
        [System.Windows.Controls.ToolTipService]::SetShowDuration($cb, 120000)
        [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($cb, 250)
    }
    [void]$Panel.Children.Add($cb)
    return $cb
}

function Get-UTTweakLabel {
    param([string]$Id, $Tweak)
    $label = [string]$Tweak.Content
    $state = ''
    # Prefer the state a worker computed; only fall back to reading the registry on the UI thread when
    # nothing has been computed yet (the very first build of the window).
    if ($sync.tweakStates -and $sync.tweakStates.ContainsKey($Id)) { $state = [string]$sync.tweakStates[$Id] }
    else { try { $state = Test-UTTweakApplied -Id $Id -Tweak $Tweak } catch { } }
    if ($state -eq 'applied') { $label += '   [applied by unknowntweaks]' }
    elseif ($state -eq 'set') { $label += '   [already set]' }
    if (-not (Test-UTTweakEligible -Tweak $Tweak)) { $label += ('   [needs Windows build {0}, this PC is {1}]' -f $Tweak.MinBuild, $sync.sysinfo.Build) }
    if ($Tweak.Reboot) { $label += '   (reboot)' }
    elseif ($Tweak.SignOut) { $label += '   (sign-out)' }
    return $label
}

function Update-UTTweakLabels {
    foreach ($id in @($sync.tweakBoxes.Keys)) {
        $tweak = $sync.configs.tweaks.$id
        if ($tweak) { $sync.tweakBoxes[$id].Content = Get-UTTweakLabel -Id $id -Tweak $tweak }
    }
}

function Initialize-UTTweaksTab {
    $panel = $sync.TweaksPanel
    $tiers = @(
        @{ Tier = 'safe';     Title = 'SAFE  (recommended preset)'; Color = '#4EC9B0'; Text = 'Documented Windows settings with a real mechanism and no meaningful downside. All reversible; originals are snapshotted before the first apply.' },
        @{ Tier = 'optional'; Title = 'OPTIONAL';                    Color = '#DCDCAA'; Text = 'Help some setups (laptops, older GPUs, specific games) and do nothing for others. Read the note under each one.' },
        @{ Tier = 'risky';    Title = 'RISKY  (read every line before ticking)'; Color = '#F14C4C'; Text = 'Real upside for some PCs, real cost for all: security, stability or boot risk. Never part of a preset. Each one records what it changed so Undo can put it back.' }
    )
    $all = @()
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) { $all += [pscustomobject]@{ Id = $p.Name; Tweak = $p.Value } }
    foreach ($t in $tiers) {
        $hdr = New-UTTextBlock -Text $t.Title -StyleKey 'SectionHeader' -Color $t.Color
        $hdr.ToolTip = $t.Text
        [void]$panel.Children.Add($hdr)
        $items = @($all | Where-Object { $_.Tweak.Tier -eq $t.Tier } | Sort-Object { [int]$_.Tweak.Order })
        $lastCat = ''
        foreach ($it in $items) {
            $cat = [string]$it.Tweak.Category
            if ($cat -ne $lastCat -and $t.Tier -ne 'risky') {
                $c = New-UTTextBlock -Text ('// ' + $cat) -StyleKey 'Dim' -Color '#569CD6'
                $c.Margin = '8,10,8,0'
                [void]$panel.Children.Add($c)
                $lastCat = $cat
            }
            $cb = New-UTCheckBox -Id $it.Id -Content (Get-UTTweakLabel -Id $it.Id -Tweak $it.Tweak) -Description ([string]$it.Tweak.Description) -Evidence ([string]$it.Tweak.Evidence) -Panel $panel
            if ($t.Tier -eq 'risky') { $cb.Foreground = $sync.form.FindResource('Orange') }
            $sync.tweakBoxes[$it.Id] = $cb
        }
    }
}

function Update-UTFortniteStatus {
    try {
        $fn = Get-UTFortnite
        $sync.fortnite = $fn
        $lines = @()
        if ($fn.Installed) { $lines += 'install: ' + $fn.InstallLocation + '   version: ' + $fn.Version } else { $lines += 'install: not found in the Epic launcher install list (the config file can still be edited)' }
        if ($fn.GameIniExists) {
            $ro = ''
            try { if ((Get-Item -LiteralPath $fn.GameIni).IsReadOnly) { $ro = '  [READ-ONLY]' } } catch { }
            $lines += 'config:  ' + $fn.GameIni + $ro
        } else { $lines += 'config:  GameUserSettings.ini not found yet (start Fortnite once)' }
        if ($fn.LauncherIniExists) { $lines += 'launcher settings: ' + $fn.LauncherIni } else { $lines += 'launcher settings: not found (open the Epic Games Launcher once)' }
        if ($fn.AccountId) { $lines += 'epic account id: ' + $fn.AccountId }
        $loc = Find-UTLaunchArgsKey -Fortnite $fn
        $cur = ''
        if ($null -ne $loc.Current) { $cur = "  (current: '" + $loc.Current + "')" }
        $lines += ('launch args key: [' + $loc.Section + '] ' + $loc.Key + '  source: ' + $loc.Source + $cur)
        if ($fn.GameRunning) { $lines += 'FORTNITE IS RUNNING: close it before writing settings' }
        $sync.FnStatusText.Text = ($lines -join "`r`n")
    } catch { $sync.FnStatusText.Text = 'detection failed: ' + $_.Exception.Message }
}

function Get-UTArgsString {
    # $sync.fnArgOrder keeps the order from config/fortnite.json; a hashtable's key order is undefined
    $parts = @()
    foreach ($id in @($sync.fnArgOrder)) {
        $cb = $sync.fnArgBoxes[$id]
        if ($cb -and $cb.IsChecked) { $parts += [string]$cb.Tag }
    }
    $extra = ''
    try { $extra = $sync.FnArgsExtra.Text.Trim() } catch { }
    if ($extra) { $parts += $extra }
    return (($parts -join ' ').Trim())
}

function Invoke-UTArgExclusion {
    <#
    .SYNOPSIS
        Unticks the option a just-ticked option declares as mutually exclusive (a rendering mode flag
        cannot be combined with another one).
    #>
    param([string]$Id)
    $cb = $sync.fnArgBoxes[$Id]
    if (-not $cb -or -not $cb.IsChecked) { return }
    $mine = [string]$cb.Tag
    $excl = [string]$sync.fnArgExcludes[$Id]
    foreach ($otherId in @($sync.fnArgOrder)) {
        if ($otherId -eq $Id) { continue }
        $other = $sync.fnArgBoxes[$otherId]
        if (-not $other -or -not $other.IsChecked) { continue }
        $otherArg = [string]$other.Tag
        $otherExcl = [string]$sync.fnArgExcludes[$otherId]
        # exclusion counts in both directions, so it does not matter which one was ticked first
        if (($excl -and $otherArg -eq $excl) -or ($otherExcl -and $mine -eq $otherExcl)) {
            $other.IsChecked = $false
            Write-UTLog ("{0} and {1} cannot be combined, unticked {1}" -f $mine, $otherArg)
        }
    }
}

function Update-UTArgsPreview {
    $s = Get-UTArgsString
    if ($s) { $sync.FnArgsPreview.Text = 'will write: ' + $s } else { $sync.FnArgsPreview.Text = 'will write: (empty = remove all launch arguments)' }
}

function Initialize-UTFortniteTab {
    $cfg = $sync.configs.fortnite
    foreach ($p in $cfg.Profiles.PSObject.Properties) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = [string]$p.Value.Content
        $item.Tag = $p.Name
        [void]$sync.FnProfileList.Items.Add($item)
    }
    $sync.FnProfileList.Add_SelectionChanged({
        try {
            $sel = $sync.FnProfileList.SelectedItem
            if ($sel) { $sync.FnProfileDesc.Text = [string]$sync.configs.fortnite.Profiles.($sel.Tag).Description }
        } catch { }
    })
    $sync.FnProfileList.SelectedIndex = 0
    foreach ($p in $cfg.HiddenKeys.PSObject.Properties) {
        $cb = New-UTCheckBox -Id $p.Name -Content ([string]$p.Value.Content) -Description ([string]$p.Value.Description) -Panel $sync.FnHiddenPanel
        $sync.fnHiddenBoxes[$p.Name] = $cb
    }
    $i = 0
    $order = New-Object System.Collections.ArrayList
    foreach ($o in @($cfg.LaunchArgs.Options)) {
        $i++
        $id = 'arg' + $i
        $cb = New-UTCheckBox -Id $id -Content ($o.Arg + '   ' + $o.Content) -Description ([string]$o.Description) -Panel $sync.FnArgsPanel -Checked ([bool]$o.Default)
        $cb.Tag = [string]$o.Arg
        $cb.Name = $id
        $cb.Add_Checked({ Invoke-UTArgExclusion -Id $this.Name; Update-UTArgsPreview })
        $cb.Add_Unchecked({ Update-UTArgsPreview })
        $sync.fnArgBoxes[$id] = $cb
        if ($o.Excludes) { $sync.fnArgExcludes[$id] = [string]$o.Excludes }
        [void]$order.Add($id)
    }
    $sync.fnArgOrder = $order
    $sync.FnArgsExtra.Add_TextChanged({ Update-UTArgsPreview })
    Update-UTArgsPreview
    Update-UTFortniteStatus
}

function Initialize-UTNetworkTab {
    foreach ($p in $sync.configs.dns.PSObject.Properties) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = ('{0}  ({1})' -f $p.Name, $p.Value.Primary)
        $item.Tag = $p.Name
        $item.ToolTip = [string]$p.Value.Note
        [void]$sync.DnsList.Items.Add($item)
    }
    $sync.DnsList.SelectedIndex = 0
}

function Initialize-UTAppsTab {
    $panel = $sync.AppsPanel
    $apps = @()
    foreach ($p in $sync.configs.applications.PSObject.Properties) { $apps += [pscustomobject]@{ Name = $p.Name; Cat = [string]$p.Value.Category; Id = [string]$p.Value.Winget; Note = [string]$p.Value.Note } }
    foreach ($group in ($apps | Group-Object Cat | Sort-Object Name)) {
        [void]$panel.Children.Add((New-UTTextBlock -Text $group.Name -StyleKey 'SectionHeader'))
        foreach ($a in ($group.Group | Sort-Object Name)) {
            $desc = 'winget id: ' + $a.Id
            if ($a.Note) { $desc = $a.Note + '  |  ' + $desc }
            $cb = New-UTCheckBox -Id $a.Name -Content $a.Name -Description $desc -Panel $panel
            $sync.appBoxes[$a.Name] = $cb
        }
    }
}


function Initialize-UTStartupTab {
    <#
    .SYNOPSIS
        Fills the STARTUP list from what actually runs at logon on this machine.
    .NOTES
        Rebuilt rather than patched on refresh: entries appear and disappear as software is installed,
        so there is no stable set of checkboxes to keep around.
    #>
    $panel = $sync.StartupPanel
    $panel.Children.Clear()
    $sync.startupBoxes = @{}
    $items = @()
    try { $items = @(Get-UTStartupItems) } catch {
        [void]$panel.Children.Add((New-UTTextBlock -Text ('could not read the startup entries: ' + $_.Exception.Message) -StyleKey 'Dim'))
        return
    }
    if ($items.Count -eq 0) {
        [void]$panel.Children.Add((New-UTTextBlock -Text 'nothing starts with Windows on this account' -StyleKey 'Dim'))
        return
    }
    foreach ($group in ($items | Group-Object Where | Sort-Object Name)) {
        [void]$panel.Children.Add((New-UTTextBlock -Text $group.Name -StyleKey 'SectionHeader'))
        foreach ($it in ($group.Group | Sort-Object @{ Expression = { -not $_.Enabled } }, Name)) {
            $label = $it.Name
            if (-not $it.Enabled) { $label += '   [already disabled]' }
            $desc = '{0}  |  {1}' -f $it.Scope, $it.Command
            $cb = New-UTCheckBox -Id $it.Id -Content $label -Description $desc -Panel $panel
            $sync.startupBoxes[$it.Id] = $cb
        }
    }
}

function Initialize-UTDebloatTab {
    <#
    .SYNOPSIS
        Fills the DEBLOAT list with catalogue entries that are actually installed here.
    #>
    $panel = $sync.DebloatPanel
    $panel.Children.Clear()
    $sync.debloatBoxes = @{}
    $apps = @()
    try { $apps = @(Get-UTBloatApps) } catch {
        [void]$panel.Children.Add((New-UTTextBlock -Text ('could not read the installed Store apps: ' + $_.Exception.Message) -StyleKey 'Dim'))
        return
    }
    if ($apps.Count -eq 0) {
        [void]$panel.Children.Add((New-UTTextBlock -Text 'none of the catalogue apps are installed: nothing to remove' -StyleKey 'Dim'))
        return
    }
    foreach ($group in ($apps | Group-Object Category | Sort-Object Name)) {
        [void]$panel.Children.Add((New-UTTextBlock -Text $group.Name -StyleKey 'SectionHeader'))
        foreach ($a in ($group.Group | Sort-Object Content)) {
            $desc = $a.Note
            if (-not $a.Recommended) { $desc = 'not in the recommended set. ' + $desc }
            $cb = New-UTCheckBox -Id $a.Name -Content $a.Content -Description $desc -Panel $panel
            $sync.debloatBoxes[$a.Name] = $cb
        }
    }
}

function Update-UTInfoBox {
    $s = $sync.sysinfo
    if (-not $s) { $sync.InfoBox.Text = 'no system info'; return }
    $lines = @()
    $lines += ('{0} {1} (build {2}.{3}) {4}' -f $s.OSName, $s.DisplayVersion, $s.Build, $s.UBR, $s.Edition)
    $lines += ('CPU      {0}  ({1} cores / {2} threads)' -f $s.CPU, $s.Cores, $s.Threads)
    foreach ($g in @($s.GPUs)) { if ($g) { $lines += ('GPU      {0}  {1} GB  driver {2}' -f $g.Name, $g.VramGB, $g.Driver) } }
    $lines += ('RAM      {0} GB' -f $s.RamGB)
    $lines += ('Disk     {0} {1}  free {2} / {3} GB on {4}' -f $s.DiskType, $s.DiskBus, $s.DiskFreeGB, $s.DiskSizeGB, $env:SystemDrive)
    $form = 'desktop'
    if ($s.IsLaptop) { $form = 'laptop (battery-sensitive tweaks show a warning)' }
    $lines += ('Form     {0}' -f $form)
    $lines += ('Power    {0}' -f $s.PowerPlan)
    $lines += ('HAGS     {0}' -f $(if ($s.HAGS) { 'on' } else { 'off' }))
    $vbs = 'off'
    if ($s.VBSStatus -eq 2) { $vbs = 'running' } elseif ($s.VBSStatus -eq 1) { $vbs = 'enabled, not running' }
    $lines += ('VBS      {0}   memory integrity: {1}   credential guard: {2}' -f $vbs, $(if ($s.HVCIRunning) { 'on' } else { 'off' }), $(if ($s.CredentialGuardRunning) { 'on' } else { 'off' }))
    # $s.BitLocker is 'On' / 'Off' / 'Unknown'. It must be compared, not tested for truthiness: every
    # non-empty string is true in PowerShell, so "Off" would have displayed as ON.
    $bl = switch ([string]$s.BitLocker) {
        'On'      { 'ON (boot-setting tweaks suspend it for one reboot first)' }
        'Off'     { 'off' }
        default   { 'could not be determined, so boot-setting tweaks treat it as ON' }
    }
    $lines += ('Boot     secure boot {0}   bitlocker/device encryption {1}' -f $(if ($s.SecureBoot) { 'on' } else { 'off' }), $bl)
    $lines += ('User     running as {0}   console user {1}' -f $s.RunningAs, $s.ConsoleUser)
    if ($s.DifferentUser) { $lines += 'WARNING  you elevated with a different account than the one signed in: HKCU (per-user) tweaks will land on the admin account, not on the signed-in user.' }
    $lines += ''
    $lines += ('logs     {0}' -f $sync.logDir)
    $lines += ('backups  {0}' -f $sync.backupDir)
    $lines += ('source   {0}' -f $sync.repo)
    $credits = Get-UTCredits
    $lines += ''
    $lines += ('support  {0}' -f $credits.Support)
    $lines += ('tiktok   {0}' -f $credits.TikTok)
    $lines += ('made by  {0}' -f $credits.Author)
    $sync.InfoBox.Text = ($lines -join "`r`n")
}

function Initialize-UTUI {
    <#
    .SYNOPSIS
        Builds every dynamic part of the window and wires all buttons to Invoke-UTButton.
    #>
    $sync.VersionText.Text = 'v' + $sync.version
    if ($sync.beta) { $sync.VersionText.Text += '  private beta' }
    $credits = Get-UTCredits
    $sync.CreditText.Text = 'MADE BY ' + $credits.Author
    Set-UTHyperlink -Link $sync.SupportHyperlink -Url $credits.Support
    Set-UTHyperlink -Link $sync.TikTokHyperlink -Url $credits.TikTok
    [void](New-UTGraphCard -Key cpu  -Title 'CPU'         -Color '#4EC9B0' -Parent $sync.GraphPanel)
    [void](New-UTGraphCard -Key ram  -Title 'MEMORY'      -Color '#569CD6' -Parent $sync.GraphPanel)
    [void](New-UTGraphCard -Key gpu  -Title 'GPU'         -Color '#CE9178' -Parent $sync.GraphPanel)
    [void](New-UTGraphCard -Key disk -Title 'DISK ACTIVE' -Color '#DCDCAA' -Parent $sync.GraphPanel)
    [void](New-UTGraphCard -Key net  -Title 'NETWORK'     -Color '#C586C0' -AutoScale -MinScale 64 -Parent $sync.GraphPanel)
    Initialize-UTTweaksTab
    Initialize-UTFortniteTab
    Initialize-UTNetworkTab
    Initialize-UTAppsTab
    Initialize-UTStartupTab
    Initialize-UTDebloatTab
    Update-UTInfoBox
    $buttons = @()
    foreach ($k in @($sync.Keys)) {
        if ($sync[$k] -is [System.Windows.Controls.Button]) {
            $sync[$k].Add_Click({ Invoke-UTButton -Name $this.Name })
            if ($k -notin 'BtnClearLog', 'BtnOpenLogs', 'BtnOpenBackups', 'BtnRefreshInfo', 'BtnRecommended', 'BtnClearTweaks', 'BtnAppsClear', 'BtnBoostGame') { $buttons += $k }
        }
    }
    $sync.actionButtons = $buttons
    if ($sync.sysinfo -and $sync.sysinfo.DifferentUser) {
        Write-UTLog 'You elevated with a different account than the signed-in user. Per-user (HKCU) tweaks will apply to the admin account. Sign in as an administrator to tweak this user.' -Level Warn
    }
}
