function Get-UTCredits {
    <#
    .SYNOPSIS
        The one place the author credit and support links live. The splash, the INFO tab and the
        bottom bar all read from here so they can never disagree.
    #>
    return @{
        Author  = 'UNKNOWN AIMER'
        Support = 'https://discord.gg/PF44W3rxJ3'
        TikTok  = 'https://www.tiktok.com/@aimerunknown'
    }
}

function New-UTSplashBrush {
    param([string]$Hex)
    return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex)))
}

function Set-UTHyperlink {
    <#
    .SYNOPSIS
        Points a Hyperlink at a URL and makes a click open it in the default browser through the
        shell, the same way the log-folder button opens Explorer. Nothing is embedded or downloaded.
    #>
    param([Parameter(Mandatory = $true)]$Link, [Parameter(Mandatory = $true)][string]$Url)
    $Link.NavigateUri = New-Object System.Uri $Url
    $Link.ToolTip = $Url
    $Link.Add_RequestNavigate({
        param($linkSender, $linkArgs)
        try { Start-Process -FilePath $linkArgs.Uri.AbsoluteUri } catch { }
        $linkArgs.Handled = $true
    })
}

function New-UTSplashLink {
    <#
    .SYNOPSIS
        A TextBlock holding one clickable link for the boot screen.
    #>
    param([string]$Label, [string]$Url)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontSize = 11.5
    $tb.Margin = '0,0,18,0'
    $hl = New-Object System.Windows.Documents.Hyperlink
    [void]$hl.Inlines.Add($Label)
    $hl.Foreground = New-UTSplashBrush '#1C97EA'
    $hl.TextDecorations = $null
    Set-UTHyperlink -Link $hl -Url $Url
    [void]$tb.Inlines.Add($hl)
    return $tb
}

function Show-UTSplash {
    <#
    .SYNOPSIS
        A short boot screen shown while the real window is being built. Purely cosmetic: it changes
        nothing, needs no input, and closes itself. Click anywhere to dismiss it early.
    .DESCRIPTION
        Built in code rather than XAML so it needs no extra file in the compile order and no XAML
        test wiring. Returns the Window so Close-UTSplash can take it down once the main window is
        ready; returns $null if anything at all goes wrong, and the caller carries on without it.
    #>
    param([string]$UserName = $env:USERNAME, [switch]$Beta)
    try {
        $credits = Get-UTCredits
        if ([string]::IsNullOrWhiteSpace($UserName)) { $UserName = 'there' }

        $win = New-Object System.Windows.Window
        $win.Title = 'unknowntweaks'
        $win.WindowStyle = 'None'
        $win.ResizeMode = 'NoResize'
        $win.WindowStartupLocation = 'CenterScreen'
        $win.Width = 520
        $win.Height = 230
        $win.ShowInTaskbar = $false
        $win.Topmost = $true
        $win.Background = New-UTSplashBrush '#1E1E1E'
        $win.Foreground = New-UTSplashBrush '#D4D4D4'
        $win.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Cascadia Code, Consolas, Courier New'
        $win.UseLayoutRounding = $true
        $win.SnapsToDevicePixels = $true
        $win.Cursor = [System.Windows.Input.Cursors]::Hand
        $win.Add_MouseLeftButtonDown({ try { $this.Tag = 'dismissed' } catch { } })

        $frame = New-Object System.Windows.Controls.Border
        $frame.BorderBrush = New-UTSplashBrush '#3E3E42'
        $frame.BorderThickness = New-Object System.Windows.Thickness 1
        $win.Content = $frame

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = New-Object System.Windows.Thickness 26, 22, 26, 16
        $rowTop = New-Object System.Windows.Controls.RowDefinition; $rowTop.Height = New-Object System.Windows.GridLength 1, 'Star'
        $rowFoot = New-Object System.Windows.Controls.RowDefinition; $rowFoot.Height = [System.Windows.GridLength]::Auto
        [void]$grid.RowDefinitions.Add($rowTop)
        [void]$grid.RowDefinitions.Add($rowFoot)
        $frame.Child = $grid

        # ---- top: the greeting -------------------------------------------------------------------
        $top = New-Object System.Windows.Controls.StackPanel
        $top.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetRow($top, 0)
        [void]$grid.Children.Add($top)

        $prompt = New-Object System.Windows.Controls.TextBlock
        $prompt.Text = '> booting unknowntweaks'
        if ($Beta) { $prompt.Text += '   [private beta]' }
        $prompt.FontSize = 11.5
        $prompt.Foreground = New-UTSplashBrush '#858585'
        $prompt.Margin = New-Object System.Windows.Thickness 0, 0, 0, 10
        [void]$top.Children.Add($prompt)

        $welcome = New-Object System.Windows.Controls.TextBlock
        $welcome.Name = 'SplashWelcome'
        $welcome.Text = ('Welcome to Unknown Utility, {0}' -f $UserName)
        $welcome.FontSize = 20
        $welcome.FontWeight = 'Bold'
        $welcome.TextWrapping = 'Wrap'
        $welcome.Foreground = New-UTSplashBrush '#4EC9B0'
        [void]$top.Children.Add($welcome)

        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Name = 'SplashStatus'
        $sub.Text = 'loading the interface...   (click to skip)'
        $sub.FontSize = 11.5
        $sub.Foreground = New-UTSplashBrush '#858585'
        $sub.Margin = New-Object System.Windows.Thickness 0, 8, 0, 0
        [void]$top.Children.Add($sub)

        # ---- bottom: credit where it is due ------------------------------------------------------
        $foot = New-Object System.Windows.Controls.StackPanel
        [System.Windows.Controls.Grid]::SetRow($foot, 1)
        [void]$grid.Children.Add($foot)

        $rule = New-Object System.Windows.Controls.Border
        $rule.Height = 1
        $rule.Background = New-UTSplashBrush '#3E3E42'
        $rule.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
        [void]$foot.Children.Add($rule)

        $links = New-Object System.Windows.Controls.StackPanel
        $links.Orientation = 'Horizontal'
        [void]$links.Children.Add((New-UTSplashLink -Label 'support: discord' -Url $credits.Support))
        [void]$links.Children.Add((New-UTSplashLink -Label 'tiktok: @aimerunknown' -Url $credits.TikTok))
        [void]$foot.Children.Add($links)

        $by = New-Object System.Windows.Controls.TextBlock
        $by.Name = 'SplashCredit'
        $by.Text = ('MADE BY {0}' -f $credits.Author)
        $by.FontSize = 11
        $by.FontWeight = 'Bold'
        $by.Foreground = New-UTSplashBrush '#007ACC'
        $by.HorizontalAlignment = 'Right'
        $by.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        [void]$foot.Children.Add($by)

        $win.Tag = [DateTime]::UtcNow
        $win.Show()
        # One short pump so the window actually paints before the caller starts the heavy work.
        Wait-UTSplash -Window $win -Milliseconds 60
        return $win
    } catch {
        return $null
    }
}

function Wait-UTSplash {
    <#
    .SYNOPSIS
        Pumps the dispatcher for up to -Milliseconds without shutting it down (the main window still
        needs it), returning early if the user clicked the splash.
    #>
    param($Window, [int]$Milliseconds)
    if ($Milliseconds -le 0) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    $timer.Add_Tick({
        $done = ([DateTime]::UtcNow -ge $deadline)
        try { if ($Window -and ([string]$Window.Tag -eq 'dismissed')) { $done = $true } } catch { }
        if ($done) { $timer.Stop(); $frame.Continue = $false }
    }.GetNewClosure())
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Close-UTSplash {
    <#
    .SYNOPSIS
        Closes the splash, first holding it on screen until it has been visible for -MinimumMs so a
        fast machine does not just flash it. A click on the splash ends the hold early.
    #>
    param($Window, [int]$MinimumMs = 1500)
    if (-not $Window) { return }
    try {
        $shown = $null
        try { if ($Window.Tag -is [DateTime]) { $shown = [DateTime]$Window.Tag } } catch { }
        if ($shown) {
            $left = $MinimumMs - [int]([DateTime]::UtcNow - $shown).TotalMilliseconds
            if ($left -gt 0) { Wait-UTSplash -Window $Window -Milliseconds $left }
        }
        $Window.Close()
    } catch { }
}
