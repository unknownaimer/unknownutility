function New-UTGraphCard {
    <#
    .SYNOPSIS
        Builds one Task-Manager-style card (title, value, 60-sample area graph) and adds it to a panel.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Color = '#4EC9B0',
        [double]$Max = 100,
        [switch]$AutoScale,
        [double]$MinScale = 64,
        [int]$Capacity = 60,
        [System.Windows.Controls.Panel]$Parent
    )
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $sync.form.FindResource('GraphCard')
    $grid = New-Object System.Windows.Controls.Grid
    $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = [System.Windows.GridLength]::Auto
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
    [void]$grid.RowDefinitions.Add($r0); [void]$grid.RowDefinitions.Add($r1)

    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
    $brush = New-Object System.Windows.Media.SolidColorBrush -ArgumentList $c
    $brush.Freeze()
    # $title would be the same variable as the [string]$Title parameter (PowerShell names are
    # case-insensitive), so the TextBlock would be coerced straight back into a string.
    $titleBlock = New-Object System.Windows.Controls.TextBlock
    $titleBlock.Text = $Title; $titleBlock.FontSize = 12; $titleBlock.Foreground = $sync.form.FindResource('FgDim')
    $valueBlock = New-Object System.Windows.Controls.TextBlock
    $valueBlock.Text = '--'; $valueBlock.FontSize = 12; $valueBlock.HorizontalAlignment = 'Right'; $valueBlock.Foreground = $brush
    [void]$grid.Children.Add($titleBlock); [void]$grid.Children.Add($valueBlock)

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Height = 58; $canvas.Margin = '0,6,0,0'; $canvas.ClipToBounds = $true
    $canvas.Background = $sync.form.FindResource('GridBrush')
    [System.Windows.Controls.Grid]::SetRow($canvas, 1)
    [void]$grid.Children.Add($canvas)

    $grad = New-Object System.Windows.Media.LinearGradientBrush
    $grad.StartPoint = New-Object System.Windows.Point -ArgumentList 0, 0
    $grad.EndPoint = New-Object System.Windows.Point -ArgumentList 0, 1
    [void]$grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop -ArgumentList ([System.Windows.Media.Color]::FromArgb(0x70, $c.R, $c.G, $c.B)), 0))
    [void]$grad.GradientStops.Add((New-Object System.Windows.Media.GradientStop -ArgumentList ([System.Windows.Media.Color]::FromArgb(0x00, $c.R, $c.G, $c.B)), 1))
    $grad.Freeze()
    $fill = New-Object System.Windows.Shapes.Polygon
    $fill.Fill = $grad; $fill.IsHitTestVisible = $false
    $line = New-Object System.Windows.Shapes.Polyline
    $line.Stroke = $brush; $line.StrokeThickness = 1.5; $line.StrokeLineJoin = 'Round'; $line.IsHitTestVisible = $false
    [void]$canvas.Children.Add($fill); [void]$canvas.Children.Add($line)

    $card.Child = $grid
    if ($Parent) { [void]$Parent.Children.Add($card) }

    $g = @{ Key = $Key; Canvas = $canvas; Line = $line; Fill = $fill; ValueText = $valueBlock
            Max = $Max; AutoScale = [bool]$AutoScale; MinScale = $MinScale; Capacity = $Capacity
            Data = New-Object 'System.Collections.Generic.Queue[double]' }
    $canvas.Tag = $g
    $canvas.Add_SizeChanged({ Update-UTGraph -Graph $this.Tag })
    $sync.graphs[$Key] = $g
    return $g
}

function Add-UTGraphSample {
    param([Parameter(Mandatory = $true)]$Graph, [Parameter(Mandatory = $true)][double]$Value, [string]$Text)
    $Graph.Data.Enqueue($Value)
    while ($Graph.Data.Count -gt $Graph.Capacity) { [void]$Graph.Data.Dequeue() }
    if ($Text) { $Graph.ValueText.Text = $Text } else { $Graph.ValueText.Text = ('{0:N0}' -f $Value) }
    Update-UTGraph -Graph $Graph
}

function Update-UTGraph {
    param([Parameter(Mandatory = $true)]$Graph)
    $canvas = $Graph.Canvas
    $w = $canvas.ActualWidth; $h = $canvas.ActualHeight
    if ($w -le 0 -or $h -le 0 -or $Graph.Data.Count -eq 0) { return }
    $vals = @($Graph.Data.ToArray())
    $max = $Graph.Max
    if ($Graph.AutoScale) { $max = [math]::Max($Graph.MinScale, (($vals | Measure-Object -Maximum).Maximum) * 1.15) }
    if ($max -le 0) { $max = 1 }
    $n = $Graph.Capacity
    $step = $w / [math]::Max(1, ($n - 1))
    $offset = $n - $vals.Count
    $pts = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = ($offset + $i) * $step
        $y = $h - [math]::Min($h, ($vals[$i] / $max) * ($h - 2)) - 1
        $pts.Add((New-Object System.Windows.Point -ArgumentList $x, $y))
    }
    $Graph.Line.Points = $pts
    $area = New-Object System.Windows.Media.PointCollection
    foreach ($p in $pts) { $area.Add($p) }
    $area.Add((New-Object System.Windows.Point -ArgumentList $pts[$pts.Count - 1].X, $h))
    $area.Add((New-Object System.Windows.Point -ArgumentList $pts[0].X, $h))
    $Graph.Fill.Points = $area
}
