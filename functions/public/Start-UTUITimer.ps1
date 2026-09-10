function Write-UTConsole {
    param([string]$Text)
    $box = $sync.ConsoleBox
    $box.AppendText($Text + [Environment]::NewLine)
    # Reading .Text copies the whole buffer, so only check the length every so often instead of per line.
    $sync.consoleLines = [int]$sync.consoleLines + 1
    if ($sync.consoleLines -ge 200) {
        $sync.consoleLines = 0
        if ($box.Text.Length -gt 300000) { $box.Text = $box.Text.Substring($box.Text.Length - 200000) }
    }
    $box.ScrollToEnd()
}

function Format-UTRate {
    param([double]$Bps)
    if ($Bps -ge 1MB) { return ('{0:N1} MB/s' -f ($Bps / 1MB)) }
    return ('{0:N0} KB/s' -f ($Bps / 1KB))
}

function Complete-UTJob {
    param([string]$Kind)
    switch ($Kind) {
        'regions' {
            if ($sync.regions) { $sync.RegionBox.Text = Format-UTRegionTable -Rows $sync.regions } else { $sync.RegionBox.Text = 'no results' }
            $sync.RegionText.Text = 'best Fortnite region: ' + $sync.bestRegion
        }
        'dns' {
            if ($sync.dnsResults) { $sync.DnsBox.Text = Format-UTDnsTable -Rows $sync.dnsResults } else { $sync.DnsBox.Text = 'no results' }
        }
        'apply'     { Update-UTTweakLabels }
        'undo'      { Update-UTTweakLabels }
        'refresh'   { Update-UTInfoBox; Update-UTFortniteStatus; Update-UTValorantStatus; Update-UTStretchedStatus; Initialize-UTSystemTab; Update-UTTweakLabels }
        'fortnite'  { Update-UTFortniteStatus }
        'fnstatus'  { if ($sync.fnLiveStatus) { $sync.FnLiveStatusBox.Text = $sync.fnLiveStatus } }
        'nvprofile' { Update-UTNvProfileStatus }
        'valorant'  { Update-UTValorantStatus }
        'stretched' { Update-UTStretchedStatus }
        'gameready' { Initialize-UTGameReadyList }
        'benchmark' { Update-UTBenchBox; Update-UTRecommendPanel }
        'install'   { }
        'net'       { }
    }
}

function Update-UTMetrics {
    param($Snap)
    $fg = $Snap.Foreground
    if ($null -ne $Snap.CpuPercent) { Add-UTGraphSample -Graph $sync.graphs.cpu -Value ([double]$Snap.CpuPercent) -Text ('{0:N0}%' -f $Snap.CpuPercent) }
    if ($null -ne $Snap.MemUsedPercent) {
        $used = ($Snap.MemTotalBytes - $Snap.MemAvailBytes) / 1GB
        Add-UTGraphSample -Graph $sync.graphs.ram -Value ([double]$Snap.MemUsedPercent) -Text ('{0:N0}%  {1:N1} / {2:N0} GB' -f $Snap.MemUsedPercent, $used, ($Snap.MemTotalBytes / 1GB))
    }
    if ($null -ne $Snap.GpuPercent) {
        $vram = ''
        if ($Snap.GpuDedicatedBytes) { $vram = ('  {0:N1} GB VRAM' -f ($Snap.GpuDedicatedBytes / 1GB)) }
        Add-UTGraphSample -Graph $sync.graphs.gpu -Value ([double]$Snap.GpuPercent) -Text ('{0:N0}%{1}' -f $Snap.GpuPercent, $vram)
    } elseif ($Snap.Tick -eq 2) { $sync.graphs.gpu.ValueText.Text = 'n/a (no WDDM 2.0 counters)' }
    if ($null -ne $Snap.DiskActivePercent) {
        Add-UTGraphSample -Graph $sync.graphs.disk -Value ([double]$Snap.DiskActivePercent) -Text ('{0:N0}%  R {1}  W {2}' -f $Snap.DiskActivePercent, (Format-UTRate ([double]$Snap.DiskReadBps)), (Format-UTRate ([double]$Snap.DiskWriteBps)))
    }
    $rx = [double]$Snap.NetRxBps; $tx = [double]$Snap.NetTxBps
    Add-UTGraphSample -Graph $sync.graphs.net -Value (($rx + $tx) / 1KB) -Text ('down {0}  up {1}' -f (Format-UTRate $rx), (Format-UTRate $tx))

    if ($fg -and $fg.IsGame) {
        $sync.GameText.Text = ('{0}   [{1}]' -f $fg.Title, $fg.Mode)
        $sync.GameDetailText.Text = ('{0}  pid {1}   GPU 3D share {2}%' -f $fg.Process, $fg.Pid, $Snap.GameGpu3D)
    } else {
        $sync.GameText.Text = 'no game running'
        $sync.GameDetailText.Text = ''
        if ($fg -and $fg.Process) { $sync.GameDetailText.Text = 'foreground: ' + $fg.Process }
    }
    $gw = '--'; if ($null -ne $Snap.GatewayMs) { $gw = ('{0} ms' -f $Snap.GatewayMs) } elseif ($Snap.GatewayStatus -ne 'n/a') { $gw = 'no reply' }
    $inet = '--'; if ($null -ne $Snap.InetMs) { $inet = ('{0} ms' -f $Snap.InetMs) } elseif ($Snap.InetStatus -ne 'n/a') { $inet = 'no reply' }
    $sync.PingText.Text = ('router {0}   internet {1}' -f $gw, $inet)
    if ($Snap.Link) {
        $l = $Snap.Link
        $t = ('{0} via {1} {2}' -f $l.LinkType, $l.Adapter, $l.LinkSpeed)
        if ($l.IsWiFi) { $t += ('   Wi-Fi {0} signal {1}   (a cable removes jitter no tweak can)' -f $l.SSID, $l.Signal) }
        $sync.LinkText.Text = $t
    }
}

function Invoke-UTUITick {
    try {
        $line = $null; $n = 0
        while ($n -lt 300 -and $sync.log.TryDequeue([ref]$line)) { Write-UTConsole $line; $n++ }
        $kind = $null
        while ($sync.jobDone.TryDequeue([ref]$kind)) { Complete-UTJob -Kind $kind }
        Remove-UTFinishedJobs
        $status = [string]$sync.status
        if ($sync.needReboot) { $status += '   |   reboot needed for at least one change' }
        if ($sync.StatusText.Text -ne $status) { $sync.StatusText.Text = $status }
        $busy = [bool]$sync.busy
        foreach ($name in @($sync.actionButtons)) {
            $b = $sync[$name]
            if ($b -and $b.IsEnabled -eq $busy) { $b.IsEnabled = -not $busy }
        }
        $snap = $sync.metrics.Snapshot
        if ($snap -and $snap.Tick -ne $sync.lastTick) {
            $sync.lastTick = $snap.Tick
            Update-UTMetrics -Snap $snap
        }
        if ($sync.monitor -and $sync.monitor.Handle.IsCompleted -and -not $sync.closing -and -not $sync.monitorReported) {
            $sync.monitorReported = $true
            foreach ($e in $sync.monitor.PowerShell.Streams.Error) { Write-UTConsole ('monitor error: ' + $e.ToString()) }
            Write-UTConsole 'monitor stopped unexpectedly (see errors above)'
        }
    } catch {
        try { Write-UTConsole ('ui tick error: ' + $_.Exception.Message) } catch { }
    }
}

function Start-UTUITimer {
    $sync.timer = New-Object System.Windows.Threading.DispatcherTimer
    $sync.timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $sync.timer.Add_Tick({ Invoke-UTUITick })
    $sync.timer.Start()
}
