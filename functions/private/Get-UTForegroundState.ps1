function Get-UTForegroundState {
    <#
    .SYNOPSIS
        The running game, found by process so windowed and alt-tabbed games count, plus how its window is shown.
    #>
    $blacklist = @()
    try { $blacklist = @($sync.configs.games.ShellBlacklist) } catch { }
    $result = [pscustomobject]@{ Process = ''; Pid = 0; Mode = 'Desktop'; IsGame = $false; Title = ''; Quns = 0; Foreground = $false; Source = '' }
    $game = $null
    try { $game = Get-UTRunningGame } catch { }
    if ($game) {
        $result.Process = $game.Name; $result.Pid = [int]$game.Pid; $result.Title = $game.Title
        $result.IsGame = $true; $result.Source = $game.Source; $result.Mode = 'background'
    }
    if (-not ('UT.NativeV1.Win' -as [type])) { return $result }
    try {
        $f = [UT.NativeV1.Win]::GetForeground()
        $name = [string]$f.ProcessName
        $result.Quns = [int]$f.Quns
        $isShell = $f.IsShell -or [string]::IsNullOrEmpty($name) -or ($blacklist -contains $name)
        $mode = 'Desktop'
        if (-not $isShell) {
            if ($f.Quns -eq 3) { $mode = 'Fullscreen' }
            elseif ($f.CoversMonitor -and $f.Borderless) { $mode = 'Borderless' }
            elseif ($f.CoversMonitor) { $mode = 'Maximized' }
            else { $mode = 'Windowed' }
        }
        if ($game) {
            if ([int]$f.Pid -eq $result.Pid) { $result.Foreground = $true; $result.Mode = $mode }
        } else {
            $result.Process = $name; $result.Pid = [int]$f.Pid; $result.Mode = $mode
            if (-not $isShell -and $mode -in 'Fullscreen', 'Borderless') { $result.IsGame = $true; $result.Title = $name; $result.Foreground = $true; $result.Source = 'window' }
        }
    } catch { }
    return $result
}

function Get-UTNetInterfaceBytes {
    <#
    .SYNOPSIS
        Byte counters of every physical, connected adapter (no counters, no localisation, no instance-name mangling).
    #>
    $virtualRx = 'Virtual|VMware|VirtualBox|Hyper-V|vEthernet|WAN Miniport|Bluetooth|Npcap|WinPcap|TAP-|Wintun|WireGuard|Loopback|ISATAP|Teredo|Pseudo|Kernel Debug|Wi-Fi Direct|Miniport|Tunnel|Tailscale|ZeroTier|Radmin|Hamachi'
    $rows = @()
    foreach ($i in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($i.OperationalStatus -ne 'Up') { continue }
        if ([string]$i.NetworkInterfaceType -in 'Loopback', 'Tunnel', 'Ppp') { continue }
        if ($i.Description -match $virtualRx) { continue }
        try {
            $st = $i.GetIPStatistics()
            $rows += [pscustomobject]@{ Id = $i.Id; Name = $i.Name; Desc = $i.Description; Type = [string]$i.NetworkInterfaceType; SpeedBps = [int64]$i.Speed; Rx = [int64]$st.BytesReceived; Tx = [int64]$st.BytesSent }
        } catch { }
    }
    return $rows
}

function Get-UTNetworkLink {
    <#
    .SYNOPSIS
        The adapter carrying the default route, and whether it is Wi-Fi.
    #>
    $out = [pscustomobject]@{ Adapter = ''; Description = ''; LinkType = 'Unknown'; LinkSpeed = ''; IsWiFi = $false; Gateway = ''; InterfaceIndex = 0; SSID = ''; Signal = '' }
    try {
        # Windows picks the route with the lowest total metric (interface + route), not the lowest route
        # metric, so sorting on RouteMetric alone can pick a VPN or virtual adapter that is not really in use.
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                 Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
                 Sort-Object @{ Expression = { [int]$_.InterfaceMetric + [int]$_.RouteMetric } } |
                 Select-Object -First 1
        if (-not $route) { return $out }
        $out.Gateway = [string]$route.NextHop
        $out.InterfaceIndex = [int]$route.ifIndex
        $nic = Get-NetAdapter -InterfaceIndex $route.ifIndex -ErrorAction SilentlyContinue
        if ($nic) {
            $out.Adapter = [string]$nic.Name
            $out.Description = [string]$nic.InterfaceDescription
            $out.LinkSpeed = [string]$nic.LinkSpeed
            if ($nic.PhysicalMediaType -eq 'Native 802.11' -or [int]$nic.NdisPhysicalMedium -eq 9) { $out.IsWiFi = $true; $out.LinkType = 'Wi-Fi' }
            elseif ($nic.PhysicalMediaType -eq 'Wireless WAN') { $out.LinkType = 'Cellular' }
            elseif ($nic.PhysicalMediaType -eq '802.3') { $out.LinkType = 'Ethernet' }
            elseif ($nic.Virtual) { $out.LinkType = 'Virtual (VPN?)' }
        }
        if ($out.IsWiFi) {
            $raw = (Invoke-UTNative -FilePath 'netsh.exe' -Arguments @('wlan', 'show', 'interfaces')).Lines
            $ssid = @($raw | Select-String '^\s*SSID\s*:\s*(.+)$' | Select-Object -First 1)
            $sig = @($raw | Select-String '^\s*Signal\s*:\s*(\d+)%' | Select-Object -First 1)
            if ($ssid.Count) { $out.SSID = $ssid[0].Matches[0].Groups[1].Value.Trim() }
            if ($sig.Count) { $out.Signal = $sig[0].Matches[0].Groups[1].Value + '%' }
        }
    } catch { }
    return $out
}
