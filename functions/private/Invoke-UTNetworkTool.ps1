function Invoke-UTNetworkTool {
    <#
    .SYNOPSIS
        Network repair and diagnosis commands. Runs in a worker job; output is streamed to the console.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('flush', 'reset', 'tracert', 'linkinfo')][string]$Tool,
        [string]$Target
    )
    switch ($Tool) {
        'flush' {
            $null = Invoke-UTNative -FilePath 'ipconfig.exe' -Arguments @('/flushdns')
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Write-UTLog 'DNS resolver cache flushed' -Level Ok
        }
        'reset' {
            Write-UTLog 'Resetting Winsock and the TCP/IP stack. This is a repair, not a tune: it also removes any static IP/DNS and per-interface registry tweaks. Reboot afterwards.' -Level Warn
            $bad = 0
            $r1 = Invoke-UTNative -FilePath 'netsh.exe' -Arguments @('winsock', 'reset')
            Write-UTLog ("winsock reset (exit {0}): {1}" -f $r1.ExitCode, $r1.Output.Trim())
            if ($r1.ExitCode -ne 0) { $bad++ }
            $r2 = Invoke-UTNative -FilePath 'netsh.exe' -Arguments @('int', 'ip', 'reset')
            Write-UTLog ("int ip reset (exit {0}): {1}" -f $r2.ExitCode, $r2.Output.Trim())
            if ($r2.ExitCode -ne 0) { $bad++ }
            $null = Invoke-UTNative -FilePath 'ipconfig.exe' -Arguments @('/flushdns')
            if ($bad -gt 0) { throw "$bad of the 2 reset commands failed; the network stack was not fully reset" }
            Write-UTLog 'Network stack reset done. Reboot to complete it.' -Level Ok
            $sync.needReboot = $true
        }
        'tracert' {
            if (-not $Target) { throw 'No target' }
            Write-UTLog "tracert -d -w 1000 -h 24 $Target (intermediate hops that drop ICMP are normal; only the last hop matters)"
            $r = Invoke-UTNative -FilePath 'tracert.exe' -Arguments @('-d', '-w', '1000', '-h', '24', $Target)
            foreach ($t in $r.Lines) { $t = $t.Trim(); if ($t) { Write-UTLog "  $t" } }
            Write-UTLog 'tracert finished' -Level Ok
        }
        'linkinfo' {
            $l = Get-UTNetworkLink
            Write-UTLog ("Active link: {0} via {1} ({2}) {3} gateway {4}" -f $l.LinkType, $l.Adapter, $l.Description, $l.LinkSpeed, $l.Gateway)
            if ($l.IsWiFi) {
                Write-UTLog ("Wi-Fi network {0}, signal {1}. For competitive play a cable beats any tweak in this tool: Wi-Fi adds jitter and retransmits, not just ping." -f $l.SSID, $l.Signal) -Level Warn
            }
            try {
                $tcp = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
                Write-UTLog ("TCP: autotuning {0}, ECN {1}, congestion {2}" -f $tcp.AutoTuningLevelLocal, $tcp.EcnCapability, $tcp.CongestionProvider)
                if ([string]$tcp.AutoTuningLevelLocal -ne 'Normal') { Write-UTLog 'TCP receive window autotuning is not Normal. That caps download speed and helps nothing; a tweak pack probably changed it. Reset with: netsh int tcp set global autotuninglevel=normal' -Level Warn }
            } catch { }
            try {
                $teredo = Invoke-UTNative -FilePath 'netsh.exe' -Arguments @('interface', 'teredo', 'show', 'state')
                Write-UTLog ("Teredo: " + ((@($teredo.Lines) | Where-Object { $_ -match 'State|Type' } | ForEach-Object { $_.Trim() }) -join '; '))
            } catch { }
        }
    }
}
