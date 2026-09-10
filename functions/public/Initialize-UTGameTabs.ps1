function Initialize-UTNvProfileTab {
    foreach ($p in $sync.configs.nvprofile.Presets.PSObject.Properties) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = [string]$p.Value.Content
        $item.Tag = $p.Name
        [void]$sync.NvProfileList.Items.Add($item)
    }
    $sync.NvProfileList.Add_SelectionChanged({
        try {
            $sel = $sync.NvProfileList.SelectedItem
            if ($sel) { $sync.NvProfileDesc.Text = [string]$sync.configs.nvprofile.Presets.($sel.Tag).Description }
            Update-UTNvProfileStatus
        } catch { }
    })
    $sync.NvProfileList.SelectedIndex = 0
    Update-UTNvProfileStatus
}

function Update-UTNvProfileStatus {
    try {
        $preset = 'Potato'
        if ($sync.NvProfileList.SelectedItem) { $preset = [string]$sync.NvProfileList.SelectedItem.Tag }
        $s = Get-UTNvProfileState -PresetName $preset
        if (-not $s.Available) { $sync.NvProfileStatusText.Text = 'no NVIDIA driver on this PC: AMD and Intel have their own control panels for these settings'; return }
        $head = '{0}: {1} of {2} setting(s) already match {3}' -f $s.Application, $s.Matching, $s.Total, $preset
        if ($s.Total -eq 0) { $head = '{0}: the driver has no profile entry for it yet' -f $s.Application }
        $sync.NvProfileStatusText.Text = (@($head) + $s.Lines) -join "`r`n"
    } catch { $sync.NvProfileStatusText.Text = 'driver profile unavailable: ' + $_.Exception.Message }
}

function Initialize-UTValorantTab {
    foreach ($p in $sync.configs.valorant.Profiles.PSObject.Properties) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = [string]$p.Value.Content
        $item.Tag = $p.Name
        [void]$sync.VaProfileList.Items.Add($item)
    }
    $sync.VaProfileList.Add_SelectionChanged({
        try {
            $sel = $sync.VaProfileList.SelectedItem
            if ($sel) { $sync.VaProfileDesc.Text = [string]$sync.configs.valorant.Profiles.($sel.Tag).Description }
        } catch { }
    })
    $sync.VaProfileList.SelectedIndex = 0
    Update-UTValorantStatus
}

function Update-UTValorantStatus {
    try {
        $v = Get-UTValorant
        $lines = @()
        if ($v.Installed) { $lines += 'install: ' + $v.InstallLocation } else { $lines += 'install: not found in the Riot client install list' }
        if ($v.PlayerId) { $lines += ('player:  {0}   game settings {1}   riot settings {2}' -f $v.PlayerId, $(if ($v.GameIniExists) { 'found' } else { 'missing' }), $(if ($v.RiotIniExists) { 'found' } else { 'missing' })) }
        else { $lines += 'player:  no settings folder yet (start the game once)' }
        $lines += ('vanguard: {0}' -f $(if (-not $v.VanguardInstalled) { 'not installed' } elseif ($v.VanguardRunning) { 'running' } else { 'installed, not running' }))
        if ($v.GameRunning) { $lines += 'VALORANT IS RUNNING: close it before writing settings' }
        elseif ($v.ClientRunning) { $lines += 'the Riot client is running: close it from the tray before writing settings' }
        $sync.VaStatusText.Text = ($lines -join "`r`n")
    } catch { $sync.VaStatusText.Text = 'detection failed: ' + $_.Exception.Message }
}

function Initialize-UTStretchedTab {
    Update-UTStretchedPresetList
    foreach ($g in $sync.configs.stretched.Games.PSObject.Properties) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = [string]$g.Value.Content
        $item.Tag = $g.Name
        [void]$sync.StretchGameList.Items.Add($item)
    }
    $sync.StretchPresetList.SelectedIndex = 0
    $sync.StretchGameList.SelectedIndex = 0
    Update-UTStretchedStatus
}

function Update-UTStretchedPresetList {
    <#
    .SYNOPSIS
        Rebuilds the resolution table for this monitor: one row per ratio per usable height, with the
        aspect, whether Windows already lists it, and whether VALORANT will take it.
    #>
    $list = $sync.StretchPresetList
    $selected = ''
    if ($list.SelectedItem) { $selected = [string]$list.SelectedItem.Tag }
    $list.Items.Clear()
    foreach ($p in @(Get-UTStretchedPresets)) {
        $flags = @()
        if ($p.Valorant) { $flags += 'VALORANT ok' } else { $flags += 'Fortnite only' }
        if ($p.Offered) { $flags += 'already listed' } else { $flags += 'will be created' }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = '{0,-11} {1,-7} {2}' -f $p.Tag, $p.RatioName, ($flags -join ', ')
        $item.Tag = $p.Tag
        $item.ToolTip = ('{0} at {1}: {2}. Common in: {3}.{4}' -f $p.RatioName, $p.Tag, $p.Label, $p.Common,
            $(if ($p.Valorant) { '' } else { ' VALORANT will not take this one: it is either below the 1280x720 minimum the game supports or a ratio its video settings do not offer. Fortnite takes any resolution.' }))
        [void]$list.Items.Add($item)
    }
    foreach ($item in $list.Items) { if ([string]$item.Tag -eq $selected) { $list.SelectedItem = $item } }
    if (-not $list.SelectedItem -and $list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
}

function Update-UTStretchedStatus {
    try {
        $d = Get-UTDisplayState
        Update-UTStretchedPresetList
        $mon = @($d.Monitors | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Status }) -join ', '
        if (-not $mon) { $mon = 'none present' }
        $nv = 'NO NVIDIA DRIVER: custom modes and the VALORANT route are unavailable'
        if ($d.Nvidia) { $nv = ('NVIDIA driver ready; custom modes are created at {0} Hz, this panel''s maximum' -f (Get-UTMaxRefresh)) }
        $session = ''
        if ($d.Active) { $session = "`r`nA STRETCHED SESSION IS ACTIVE: Restore desktop puts it back" }
        $sync.StretchStatusText.Text = ('desktop {0}x{1}@{2}   scaling: {3}   monitor: {4}{5}{6}' -f $d.Width, $d.Height, $d.Hz, $d.ScalingName, $mon, "`r`n$nv", $session)
    } catch { $sync.StretchStatusText.Text = 'display state unavailable: ' + $_.Exception.Message }
}

function Get-UTStretchSelection {
    $text = ''
    try { $text = $sync.StretchCustom.Text.Trim() } catch { }
    if (-not $text -and $sync.StretchPresetList.SelectedItem) { $text = [string]$sync.StretchPresetList.SelectedItem.Tag }
    if ($text -notmatch '^\s*(\d{3,4})\s*[xX*]\s*(\d{3,4})\s*$') { Write-UTLog 'Pick a preset or type a resolution like 1440x1080' -Level Warn; return $null }
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    if ($w -lt 640 -or $h -lt 480 -or $w -gt 7680 -or $h -gt 4320) { Write-UTLog 'That resolution is outside 640x480 .. 7680x4320' -Level Warn; return $null }
    return @{ Width = $w; Height = $h }
}

function Initialize-UTGameReadyTab {
    $sync.GameReadyGameList.Items.Clear()
    $items = New-Object System.Collections.ArrayList
    try {
        $snap = $sync.metrics.Snapshot
        if ($snap -and $snap.Foreground -and $snap.Foreground.IsGame) { [void]$items.Add(@{ Content = ('running now: ' + $snap.Foreground.Title); Tag = [string]$snap.Foreground.Process }) }
    } catch { }
    [void]$items.Add(@{ Content = 'Fortnite'; Tag = [string]$sync.configs.fortnite.GameProcess })
    [void]$items.Add(@{ Content = 'VALORANT'; Tag = [string]$sync.configs.valorant.GameProcess })
    [void]$items.Add(@{ Content = 'another game (nothing is exempt but Windows)'; Tag = '' })
    foreach ($i in $items) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = [string]$i.Content
        $item.Tag = [string]$i.Tag
        [void]$sync.GameReadyGameList.Items.Add($item)
    }
    if (-not $sync.gameReadyWired) {
        $sync.GameReadyGameList.Add_SelectionChanged({ try { Initialize-UTGameReadyList } catch { } })
        $sync.gameReadyWired = $true
    }
    $sync.GameReadyGameList.SelectedIndex = 0
}

function Initialize-UTGameReadyList {
    $panel = $sync.GameReadyPanel
    $panel.Children.Clear()
    $sync.gameReadyBoxes = @{}
    $game = ''
    if ($sync.GameReadyGameList.SelectedItem) { $game = [string]$sync.GameReadyGameList.SelectedItem.Tag }
    $rows = @()
    try { $rows = @(Get-UTGameReadyCandidates -GameProcess $game) } catch {
        [void]$panel.Children.Add((New-UTTextBlock -Text ('could not read the process list: ' + $_.Exception.Message) -StyleKey 'Dim'))
        return
    }
    if ($rows.Count -eq 0) { [void]$panel.Children.Add((New-UTTextBlock -Text 'nothing else is running in your session' -StyleKey 'Dim')); return }
    $groups = @(
        @{ Title = 'apps with a window';     Rows = @($rows | Where-Object { -not $_.Keep -and $_.HasWindow }) },
        @{ Title = 'background';             Rows = @($rows | Where-Object { -not $_.Keep -and -not $_.HasWindow }) },
        @{ Title = 'kept unless you tick them'; Rows = @($rows | Where-Object { $_.Keep }) }
    )
    foreach ($g in $groups) {
        if ($g.Rows.Count -eq 0) { continue }
        [void]$panel.Children.Add((New-UTTextBlock -Text $g.Title -StyleKey 'SectionHeader'))
        foreach ($r in $g.Rows) {
            $procs = $r.Name
            if ($r.Count -gt 1) { $procs = '{0} x{1}' -f $r.Name, $r.Count }
            $label = '{0}   ({1}, {2:N0} MB)' -f $r.Label, $procs, $r.MemoryMB
            $desc = $r.Reason
            if (-not $desc) { $desc = '{0} process(es) named {1}' -f $r.Count, $r.Name }
            $cb = New-UTCheckBox -Id $r.Name -Content $label -Description $desc -Panel $panel -Checked (-not $r.Keep)
            $cb.Tag = $r.Name
            $sync.gameReadyBoxes[$r.Name] = $cb
        }
    }
}

function Initialize-UTSystemTab {
    $s = $sync.sysinfo
    $kind = 'desktop'
    if ($s.IsLaptop) { $kind = 'laptop' }
    $vbs = 'off'
    if ($s.VBSStatus -eq 2 -or $s.HVCIRunning) { $vbs = 'ON (the biggest FPS item in the catalogue)' }
    $sync.SysTierText.Text = ('{0}   {1}   {2} GB RAM   {3} system disk   {4}   VBS {5}' -f $s.CPU, $s.GPU, $s.RamGB, $s.DiskType, $kind, $vbs)
    Update-UTBenchBox
    Update-UTRecommendPanel
}

function Update-UTBenchBox {
    $b = $sync.benchmark
    if (-not $b) { return }
    $lines = @(
        ('CPU single core   {0,6} Mops/s   score {1,4}' -f $b.CpuSingleMops, $b.CpuSingleScore),
        ('CPU all cores     {0,6} Mops/s   score {1,4}' -f $b.CpuMultiMops, $b.CpuMultiScore),
        ('memory copy       {0,6} GB/s     score {1,4}' -f $b.MemoryGBps, $b.MemoryScore),
        ('disk read         {0,6} MB/s     score {1,4}' -f $b.DiskReadMBps, $b.DiskScore),
        ('disk write        {0,6} MB/s' -f $b.DiskWriteMBps),
        '',
        ('tier: {0}   (100 = Ryzen 7 5800XT, DDR4-3200, NVMe)   {1}' -f $b.Tier, $b.When)
    )
    $sync.BenchBox.Text = ($lines -join "`r`n")
}

function Update-UTRecommendPanel {
    $panel = $sync.RecommendPanel
    $panel.Children.Clear()
    $recs = @()
    try { $recs = @(Get-UTRecommendations) } catch { [void]$panel.Children.Add((New-UTTextBlock -Text ('no recommendations: ' + $_.Exception.Message) -StyleKey 'Dim')); return }
    $colors = @{ safe = '#4EC9B0'; optional = '#DCDCAA'; risky = '#F14C4C' }
    foreach ($tier in 'safe', 'optional', 'risky') {
        $rows = @($recs | Where-Object { $_.Tier -eq $tier })
        if ($rows.Count -eq 0) { continue }
        $title = switch ($tier) { 'safe' { 'SAFE, ticked for you' } 'optional' { 'OPTIONAL, ticked for you' } 'risky' { 'RISKY, read the cost, tick it yourself' } }
        [void]$panel.Children.Add((New-UTTextBlock -Text $title -StyleKey 'SectionHeader' -Color $colors[$tier]))
        foreach ($r in $rows) {
            $tb = New-UTTextBlock -Text $r.Content -StyleKey 'Body'
            $tb.Margin = '8,4,8,0'
            $tb.ToolTip = New-UTToolTip -Description ([string]$sync.configs.tweaks.($r.Id).Description) -Evidence ([string]$sync.configs.tweaks.($r.Id).Evidence)
            [void]$panel.Children.Add($tb)
            $why = New-UTTextBlock -Text ('why: ' + $r.Why) -StyleKey 'Dim'
            $why.Margin = '24,0,8,4'
            [void]$panel.Children.Add($why)
        }
    }
    if ($recs.Count -eq 0) { [void]$panel.Children.Add((New-UTTextBlock -Text 'nothing beyond the safe preset applies to this PC' -StyleKey 'Dim')) }
}
