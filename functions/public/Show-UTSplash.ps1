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
        A TextBlock holding one clickable link: grey until the pointer is on it, then the accent, so
        the boot screen keeps to one colour like the rest of the interface.
    #>
    param([string]$Label, [string]$Url)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.FontSize = 11
    $tb.Margin = '0,0,20,0'
    $hl = New-Object System.Windows.Documents.Hyperlink
    [void]$hl.Inlines.Add($Label)
    $hl.Foreground = New-UTSplashBrush '#858585'
    $hl.TextDecorations = $null
    $hl.Add_MouseEnter({ $this.Foreground = New-UTSplashBrush '#E8A33D' })
    $hl.Add_MouseLeave({ $this.Foreground = New-UTSplashBrush '#858585' })
    Set-UTHyperlink -Link $hl -Url $Url
    [void]$tb.Inlines.Add($hl)
    return $tb
}

function New-UTSplashGridBrush {
    <#
    .SYNOPSIS
        The same 16 px graph-paper tile the live graph cards use, so the boot screen looks like the
        instrument it is opening.
    #>
    $geo = New-Object System.Windows.Media.GeometryGroup
    [void]$geo.Children.Add((New-Object System.Windows.Media.LineGeometry -ArgumentList (New-Object System.Windows.Point -ArgumentList 0, 15.5), (New-Object System.Windows.Point -ArgumentList 16, 15.5)))
    [void]$geo.Children.Add((New-Object System.Windows.Media.LineGeometry -ArgumentList (New-Object System.Windows.Point -ArgumentList 15.5, 0), (New-Object System.Windows.Point -ArgumentList 15.5, 16)))
    $drawing = New-Object System.Windows.Media.GeometryDrawing
    $drawing.Geometry = $geo
    $drawing.Pen = New-Object System.Windows.Media.Pen -ArgumentList (New-UTSplashBrush '#2A2A2E'), 1
    $brush = New-Object System.Windows.Media.DrawingBrush
    $brush.Drawing = $drawing
    $brush.TileMode = 'Tile'
    $brush.Viewport = New-Object System.Windows.Rect -ArgumentList 0, 0, 16, 16
    $brush.ViewportUnits = 'Absolute'
    $brush.Freeze()
    return $brush
}

function Update-UTSplash {
    <#
    .SYNOPSIS
        Adds a line to the boot log and advances the bar. Every stage named here is a real step the
        caller is about to take, not a decorative countdown.
    #>
    param($Window, [string]$Stage, [double]$Fraction = -1)
    if (-not $Window) { return }
    try {
        $ui = $Window.Resources['ut']
        if (-not $ui) { return }
        foreach ($old in $ui.Log.Children) { $old.Foreground = New-UTSplashBrush '#6A6A6A' }
        $line = New-Object System.Windows.Controls.TextBlock
        $line.Text = '> ' + $Stage
        $line.FontSize = 11.5
        $line.Foreground = New-UTSplashBrush '#E8A33D'
        [void]$ui.Log.Children.Add($line)
        while ($ui.Log.Children.Count -gt 4) { $ui.Log.Children.RemoveAt(0) }
        if ($Fraction -ge 0) { $ui.Bar.Width = [math]::Max(2, [math]::Min(1, $Fraction) * $ui.TrackWidth) }
        Wait-UTSplash -Window $Window -Milliseconds 40
    } catch { }
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
        $win.Width = 640
        $win.Height = 330
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
        $frame.Background = New-UTSplashGridBrush
        $win.Content = $frame

        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = New-Object System.Windows.Thickness 34, 28, 34, 18
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

        # Wordmark: the name in two weights of the same idea, the accent carrying the second half.
        $mark = New-Object System.Windows.Controls.TextBlock
        $mark.FontSize = 34
        $mark.FontWeight = 'Bold'
        $runOne = New-Object System.Windows.Documents.Run -ArgumentList 'UNKNOWN'
        $runOne.Foreground = New-UTSplashBrush '#D4D4D4'
        $runTwo = New-Object System.Windows.Documents.Run -ArgumentList ' UTILITY'
        $runTwo.Foreground = New-UTSplashBrush '#E8A33D'
        [void]$mark.Inlines.Add($runOne)
        [void]$mark.Inlines.Add($runTwo)

        $head = New-Object System.Windows.Controls.DockPanel
        $head.LastChildFill = $false
        [void]$head.Children.Add($mark)
        if ($Beta) {
            $chip = New-Object System.Windows.Controls.Border
            $chip.BorderBrush = New-UTSplashBrush '#E8A33D'
            $chip.BorderThickness = New-Object System.Windows.Thickness 1
            $chip.CornerRadius = New-Object System.Windows.CornerRadius 3
            $chip.Padding = New-Object System.Windows.Thickness 7, 2, 7, 2
            $chip.VerticalAlignment = 'Center'
            $chipText = New-Object System.Windows.Controls.TextBlock
            $chipText.Text = 'PRIVATE BETA'
            $chipText.FontSize = 10
            $chipText.Foreground = New-UTSplashBrush '#E8A33D'
            $chip.Child = $chipText
            [System.Windows.Controls.DockPanel]::SetDock($chip, 'Right')
            [void]$head.Children.Add($chip)
        }
        [void]$top.Children.Add($head)

        # The line the wordmark cannot carry: who is sitting there. The name takes the emphasis
        # because the rest of the sentence is already spelled out above it in 34 point.
        $welcome = New-Object System.Windows.Controls.TextBlock
        $welcome.Name = 'SplashWelcome'
        $welcome.FontSize = 13
        $welcome.TextWrapping = 'Wrap'
        $welcome.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
        $greetLead = New-Object System.Windows.Documents.Run -ArgumentList 'Welcome to Unknown Utility, '
        $greetLead.Foreground = New-UTSplashBrush '#858585'
        $greetName = New-Object System.Windows.Documents.Run -ArgumentList $UserName
        $greetName.Foreground = New-UTSplashBrush '#D4D4D4'
        $greetName.FontWeight = 'Bold'
        [void]$welcome.Inlines.Add($greetLead)
        [void]$welcome.Inlines.Add($greetName)
        [void]$top.Children.Add($welcome)

        # The boot log: one line per real stage, the newest in the accent, the rest receding.
        $log = New-Object System.Windows.Controls.StackPanel
        $log.Margin = New-Object System.Windows.Thickness 0, 20, 0, 0
        $log.MinHeight = 72
        [void]$top.Children.Add($log)

        $trackWidth = $win.Width - 70
        $track = New-Object System.Windows.Controls.Border
        $track.Height = 3
        $track.Background = New-UTSplashBrush '#2D2D30'
        $track.Margin = New-Object System.Windows.Thickness 0, 16, 0, 0
        $track.HorizontalAlignment = 'Left'
        $track.Width = $trackWidth
        $bar = New-Object System.Windows.Controls.Border
        $bar.Height = 3
        $bar.Background = New-UTSplashBrush '#E8A33D'
        $bar.HorizontalAlignment = 'Left'
        $bar.Width = 2
        $track.Child = $bar
        [void]$top.Children.Add($track)

        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Name = 'SplashStatus'
        $sub.Text = 'click anywhere to skip'
        $sub.FontSize = 10.5
        $sub.Foreground = New-UTSplashBrush '#6A6A6A'
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
        $by.Foreground = New-UTSplashBrush '#858585'
        $by.HorizontalAlignment = 'Right'
        $by.Margin = New-Object System.Windows.Thickness 0, 6, 0, 0
        [void]$foot.Children.Add($by)

        # Tag stays the shown-at time and the click flag, so the log and bar are handed over here.
        $win.Resources['ut'] = @{ Log = $log; Bar = $bar; TrackWidth = $trackWidth; Status = $sub }
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
