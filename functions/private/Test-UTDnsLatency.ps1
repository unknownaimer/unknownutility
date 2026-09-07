function Test-UTDnsLatency {
    <#
    .SYNOPSIS
        Raw UDP DNS A-query with a hard timeout (Resolve-DnsName has none). Random label prefix bypasses caches so the
        number is the resolver's real recursion time. Returns one object per sample.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [string]$Name = 'www.epicgames.com',
        [int]$TimeoutMs = 1500,
        [int]$Samples = 5
    )
    $addr = $null
    if (-not [System.Net.IPAddress]::TryParse($Server, [ref]$addr)) { return @() }
    $out = @()
    for ($i = 0; $i -lt $Samples; $i++) {
        $qname = 'p{0}.{1}' -f (Get-Random -Minimum 1000 -Maximum 999999), $Name
        $id = Get-Random -Minimum 1 -Maximum 65535
        $buf = New-Object System.Collections.Generic.List[byte]
        $buf.AddRange([byte[]]@((($id -shr 8) -band 0xFF), ($id -band 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
        foreach ($label in $qname.TrimEnd('.').Split('.')) {
            $lb = [System.Text.Encoding]::ASCII.GetBytes($label)
            $buf.Add([byte]$lb.Length); $buf.AddRange($lb)
        }
        $buf.AddRange([byte[]]@(0x00, 0x00, 0x01, 0x00, 0x01))
        $pkt = $buf.ToArray()
        $udp = New-Object System.Net.Sockets.UdpClient($addr.AddressFamily)
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $ep = New-Object System.Net.IPEndPoint($addr, 53)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            [void]$udp.Send($pkt, $pkt.Length, $ep)
            $from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { $from = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::IPv6Any, 0) }
            $resp = $udp.Receive([ref]$from)
            $sw.Stop()
            $idOk = ($resp.Length -ge 2) -and ($resp[0] -eq $pkt[0]) -and ($resp[1] -eq $pkt[1])
            $out += [pscustomobject]@{ Server = $Server; Sample = ($i + 1); Ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 1); Ok = $idOk }
        } catch {
            $sw.Stop()
            $out += [pscustomobject]@{ Server = $Server; Sample = ($i + 1); Ms = $null; Ok = $false }
        } finally { $udp.Close() }
    }
    return $out
}

function Invoke-UTDnsBenchmark {
    <#
    .SYNOPSIS
        Benchmarks every provider in config/dns.json plus the resolver you use now; stores rows in $sync.dnsResults.
    #>
    $rows = @()
    $current = @()
    try {
        $link = Get-UTNetworkLink
        if ($link.InterfaceIndex) {
            $current = @((Get-DnsClientServerAddress -InterfaceIndex $link.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
        }
    } catch { }
    $targets = @()
    if ($current.Count -gt 0) { $targets += [pscustomobject]@{ Name = 'Current (' + $current[0] + ')'; Server = $current[0] } }
    foreach ($p in $sync.configs.dns.PSObject.Properties) { $targets += [pscustomobject]@{ Name = $p.Name; Server = $p.Value.Primary } }
    foreach ($t in $targets) {
        $sync.status = 'DNS benchmark: ' + $t.Name
        $s = @(Test-UTDnsLatency -Server $t.Server -Samples 5 -TimeoutMs 1500 | Where-Object { $_.Ok })
        $median = $null; $best = $null
        if ($s.Count -gt 0) {
            $vals = @($s | ForEach-Object { $_.Ms } | Sort-Object)
            $median = $vals[[int][math]::Floor($vals.Count / 2)]
            $best = $vals[0]
        }
        $rows += [pscustomobject]@{ Name = $t.Name; Server = $t.Server; MedianMs = $median; BestMs = $best; Ok = $s.Count; Sent = 5 }
    }
    $sync.dnsResults = @($rows | Sort-Object @{ Expression = { if ($null -eq $_.MedianMs) { 99999 } else { $_.MedianMs } } })
    return $sync.dnsResults
}

function Format-UTDnsTable {
    param($Rows)
    $rows = @($Rows | Where-Object { $null -ne $_ })
    # Sized from the data for the same reason as the region table: a provider name or an IPv6
    # literal wider than the pad would shift the rest of that row out of the columns.
    $wName = 'RESOLVER'.Length; $wAddr = 'ADDRESS'.Length
    foreach ($r in $rows) {
        if (([string]$r.Name).Length -gt $wName) { $wName = ([string]$r.Name).Length }
        if (([string]$r.Server).Length -gt $wAddr) { $wAddr = ([string]$r.Server).Length }
    }
    $fmt = '{0,-' + $wName + '}  {1,-' + $wAddr + '} {2,8} {3,8} {4,6}'
    $lines = @()
    $lines += $fmt -f 'RESOLVER', 'ADDRESS', 'MEDIAN', 'BEST', 'OK'
    foreach ($r in $rows) {
        $med = 'timeout'; $best = '-'
        if ($null -ne $r.MedianMs) { $med = ('{0} ms' -f $r.MedianMs); $best = ('{0} ms' -f $r.BestMs) }
        # One pre-joined string, so the OK column right-aligns under its own header instead of the
        # replies count hanging off the end of a 3-wide field.
        $lines += $fmt -f $r.Name, $r.Server, $med, $best, ('{0}/{1}' -f $r.Ok, $r.Sent)
    }
    $lines += ''
    $lines += 'DNS only affects name lookups (launcher, login, matchmaking API, patch CDN). It cannot change in-match ping.'
    return ($lines -join "`r`n")
}

function Set-UTDns {
    <#
    .SYNOPSIS
        Sets (or resets to DHCP) the resolvers on the adapter that carries the default route. Remembers a static
        configuration so Undo can put it back.
    #>
    param([string]$Provider, [switch]$Reset)
    $link = Get-UTNetworkLink
    if (-not $link.InterfaceIndex) { throw 'No adapter with a default route was found' }
    $idx = $link.InterfaceIndex
    if ($Reset) {
        if (-not (Test-UTBackupExists -Id UTDns)) {
            # Resetting a configuration this tool never changed would silently throw away someone's own
            # static DNS, so it only resets what it set.
            Write-UTLog "unknowntweaks has not changed DNS on this PC, so nothing was reset. To clear DNS yourself: Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses" -Level Warn
            return
        }
        $prev = Get-UTScriptState -Id UTDns -Key Static
        if ($prev) {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses (@($prev -split '\|')) -ErrorAction Stop
            Write-UTLog "DNS on $($link.Adapter) restored to the static servers you had before: $prev"
        } else {
            Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses -ErrorAction Stop
            Write-UTLog "DNS on $($link.Adapter) reset to automatic (DHCP)"
        }
        Remove-UTBackup -Id UTDns
    } else {
        $p = $sync.configs.dns.$Provider
        if (-not $p) { throw "Unknown DNS provider $Provider" }
        if (-not (Test-UTBackupExists -Id UTDns)) {
            # Read the live configuration rather than the IPv4-only NameServer registry value, which is
            # comma OR space separated depending on how it was written and omits IPv6 entirely.
            $static = ''
            try {
                $current = @(Get-DnsClientServerAddress -InterfaceIndex $idx -ErrorAction Stop |
                             Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses })
                # A DHCP-supplied list must not be recorded as "static", or Reset would pin it forever.
                $guid = (Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue).InterfaceGuid
                $isStatic = $false
                if ($guid) {
                    $ns = [string](Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -Name NameServer -ErrorAction SilentlyContinue).NameServer
                    $isStatic = -not [string]::IsNullOrWhiteSpace($ns)
                }
                if ($isStatic -and $current.Count -gt 0) { $static = ($current -join '|') }
            } catch { }
            Save-UTScriptState -Id UTDns -Key Static -Value $static
            @{ Id = 'UTDns'; Date = (Get-Date -Format 's') } | ConvertTo-Json | Set-Content -LiteralPath (Get-UTBackupPath -Id UTDns) -Encoding UTF8
        }
        $servers = @($p.Primary, $p.Secondary)
        if ($p.Primary6) { $servers += $p.Primary6 }
        if ($p.Secondary6) { $servers += $p.Secondary6 }
        Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $servers -ErrorAction Stop
        Write-UTLog "DNS on $($link.Adapter) set to $Provider ($($servers -join ', '))" -Level Ok
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}
