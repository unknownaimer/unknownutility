function Set-UTMode {
    <#
    .SYNOPSIS
        Switches between the one-click view and the full tool, and paints the toggle.
    #>
    param([Parameter(Mandatory = $true)][ValidateSet('Simple', 'Advanced')][string]$Mode)
    $simple = ($Mode -eq 'Simple')
    $sync.SimpleRoot.Visibility = $(if ($simple) { 'Visible' } else { 'Collapsed' })
    $sync.AdvancedRoot.Visibility = $(if ($simple) { 'Collapsed' } else { 'Visible' })
    $live = $sync.form.FindResource('Live')
    $dim = $sync.form.FindResource('FgDim')
    $bg = $sync.form.FindResource('Bg2')
    $sync.BtnModeSimple.Background = $(if ($simple) { $bg } else { [System.Windows.Media.Brushes]::Transparent })
    $sync.BtnModeSimple.Foreground = $(if ($simple) { $live } else { $dim })
    $sync.BtnModeAdvanced.Background = $(if ($simple) { [System.Windows.Media.Brushes]::Transparent } else { $bg })
    $sync.BtnModeAdvanced.Foreground = $(if ($simple) { $dim } else { $live })
    $sync.mode = $Mode
    if ($simple) { Update-UTSimplePlan }
}

function Initialize-UTSimpleTab {
    <#
    .SYNOPSIS
        Builds the game tiles from config/simple.json, marking which are actually installed here.
    #>
    $panel = $sync.SimpleGamePanel
    $panel.Children.Clear()
    $sync.simpleTiles = @{}
    $installed = @{}
    try { $installed['Fortnite'] = [bool](Get-UTFortnite).Installed } catch { $installed['Fortnite'] = $false }
    try { $installed['Valorant'] = [bool](Get-UTValorant).Installed } catch { $installed['Valorant'] = $false }
    $games = @($sync.configs.simple.Games.PSObject.Properties | Sort-Object { [int]$_.Value.Order })
    foreach ($g in $games) {
        $name = $g.Name
        $state = 'ready'
        if ($installed.ContainsKey($name)) { $state = $(if ($installed[$name]) { 'installed' } else { 'not found on this PC' }) }
        elseif ($name -eq 'Other') { $state = 'Windows-side tweaks only' }
        $stack = New-Object System.Windows.Controls.StackPanel
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = [string]$g.Value.Content; $title.FontWeight = 'Bold'; $title.FontSize = 13
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = $state; $sub.FontSize = 11; $sub.Margin = '0,4,0,0'
        $sub.Foreground = $sync.form.FindResource('FgDim')
        [void]$stack.Children.Add($title); [void]$stack.Children.Add($sub)
        $tile = New-Object System.Windows.Controls.Button
        $tile.Style = $sync.form.FindResource('GameTile')
        $tile.Content = $stack
        $tile.Tag = $name
        $tile.Add_Click({ Select-UTSimpleGame -Game ([string]$this.Tag) })
        [void]$panel.Children.Add($tile)
        $sync.simpleTiles[$name] = $tile
    }
    $first = @($games | Where-Object { -not $installed.ContainsKey($_.Name) -or $installed[$_.Name] } | Select-Object -First 1)
    if ($first.Count -gt 0) { Select-UTSimpleGame -Game $first[0].Name } else { Select-UTSimpleGame -Game 'Other' }
}

function Select-UTSimpleGame {
    param([Parameter(Mandatory = $true)][string]$Game)
    $sync.simpleGame = $Game
    $live = $sync.form.FindResource('Live')
    $border = $sync.form.FindResource('BorderBrush')
    foreach ($k in @($sync.simpleTiles.Keys)) {
        $sync.simpleTiles[$k].BorderBrush = $(if ($k -eq $Game) { $live } else { $border })
        $sync.simpleTiles[$k].BorderThickness = $(if ($k -eq $Game) { '2' } else { '1' })
    }
    Update-UTSimplePlan
}

function Update-UTSimplePlan {
    <#
    .SYNOPSIS
        Renders the plan for the selected game: what will run, and what will not and why.
    #>
    $panel = $sync.SimplePlanPanel
    if (-not $panel) { return }
    $panel.Children.Clear()
    $game = [string]$sync.simpleGame
    if (-not $game) { return }
    $steps = @()
    try { $steps = @(Get-UTSimplePlan -Game $game) } catch {
        [void]$panel.Children.Add((New-UTTextBlock -Text ('plan unavailable: ' + $_.Exception.Message) -StyleKey 'Dim'))
        return
    }
    $live = $sync.form.FindResource('Live')
    $dim = $sync.form.FindResource('FgDim')
    foreach ($s in $steps) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = '0,0,0,2'
        $mark = New-Object System.Windows.Controls.TextBlock
        $mark.Text = $(if ($s.Applies) { '+' } else { '-' })
        $mark.Width = 18
        $mark.Foreground = $(if ($s.Applies) { $live } else { $dim })
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = $s.Text
        $text.Foreground = $(if ($s.Applies) { $sync.form.FindResource('Fg') } else { $dim })
        [void]$row.Children.Add($mark); [void]$row.Children.Add($text)
        [void]$panel.Children.Add($row)
        $detail = New-Object System.Windows.Controls.TextBlock
        $detail.Text = $(if ($s.Applies) { $s.Detail } else { 'skipped: ' + $s.Why })
        $detail.FontSize = 11; $detail.Foreground = $dim; $detail.TextWrapping = 'Wrap'; $detail.Margin = '18,0,0,8'
        [void]$panel.Children.Add($detail)
    }
    $applies = @($steps | Where-Object { $_.Applies }).Count
    $sync.BtnSimpleOptimize.Content = 'OPTIMIZE ' + [string]$sync.configs.simple.Games.$game.Content
    $sync.SimpleNoteText.Text = ("{0} step(s) will run. Nothing happens until you press the button, and every tweak it applies is recorded first so Undo everything puts it all back." -f $applies)
}
