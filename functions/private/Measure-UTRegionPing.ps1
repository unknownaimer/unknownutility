function Measure-UTRegionPing {
    <#
    .SYNOPSIS
        Pings every Fortnite region host (plus the internet baseline) several rounds in parallel and returns
        avg / min / max / jitter / loss per region, sorted by average. Runs in a worker job.
    #>
    param([int]$Rounds = 6, [int]$TimeoutMs = 1200)
    $targets = @()
    foreach ($r in @($sync.configs.gameservers.Fortnite.Regions)) { $targets += [pscustomobject]@{ Region = $r.Region; Host = $r.Host; Location = $r.Location } }
    foreach ($r in @($sync.configs.gameservers.Baseline)) { $targets += [pscustomobject]@{ Region = $r.Region; Host = $r.Host; Location = $r.Location } }

    # Resolve every name once up front. SendPingAsync would otherwise do a blocking DNS lookup inside the
    # shared WaitAll budget, and a cold cache would show up as 100 percent loss on the first round.
    foreach ($t in $targets) {
        $t | Add-Member -NotePropertyName Address -NotePropertyValue $t.Host -Force
        try {
            $ip = @([System.Net.Dns]::GetHostAddresses($t.Host) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            if ($ip.Count -gt 0) { $t.Address = $ip[0].IPAddressToString }
        } catch {
            Write-UTLog ("{0}: {1} could not be resolved" -f $t.Region, $t.Host) -Level Warn
        }
    }

    $samples = @{}
    foreach ($t in $targets) { $samples[$t.Host] = New-Object System.Collections.Generic.List[double] }
    $sent = @{}
    foreach ($t in $targets) { $sent[$t.Host] = 0 }

    for ($round = 1; $round -le $Rounds; $round++) {
        $tasks = @{}
        $pingers = @()
        foreach ($t in $targets) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $pingers += $p
            try { $tasks[$t.Host] = $p.SendPingAsync($t.Address, $TimeoutMs); $sent[$t.Host]++ } catch { }
        }
        if ($tasks.Count -gt 0) {
            try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($tasks.Values), ($TimeoutMs + 800)) } catch { }
        }
        foreach ($h in @($tasks.Keys)) {
            $task = $tasks[$h]
            try {
                if ($task.IsCompleted -and -not $task.IsFaulted) {
                    $reply = $task.Result
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $samples[$h].Add([double]$reply.RoundtripTime) }
                }
            } catch { }
        }
        foreach ($p in $pingers) { try { $p.Dispose() } catch { } }
        if ($round -lt $Rounds) { Start-Sleep -Milliseconds 250 }
    }

    $results = @()
    foreach ($t in $targets) {
        $list = $samples[$t.Host]
        $n = $sent[$t.Host]
        $avg = $null; $min = $null; $max = $null; $jitter = $null
        if ($list.Count -gt 0) {
            $m = $list | Measure-Object -Average -Minimum -Maximum
            $avg = [math]::Round($m.Average, 0); $min = [int]$m.Minimum; $max = [int]$m.Maximum
            if ($list.Count -gt 1) {
                $d = 0.0
                for ($i = 1; $i -lt $list.Count; $i++) { $d += [math]::Abs($list[$i] - $list[$i - 1]) }
                $jitter = [math]::Round($d / ($list.Count - 1), 1)
            } else { $jitter = 0 }
        }
        $loss = 100
        if ($n -gt 0) { $loss = [math]::Round(100.0 * ($n - $list.Count) / $n, 0) }
        $results += [pscustomobject]@{ Region = $t.Region; Host = $t.Host; Location = $t.Location; AvgMs = $avg; MinMs = $min; MaxMs = $max; JitterMs = $jitter; LossPct = $loss; Replies = $list.Count; Sent = $n }
    }
    $sorted = @($results | Sort-Object @{ Expression = { if ($null -eq $_.AvgMs) { 99999 } else { $_.AvgMs } } })
    $sync.regions = $sorted
    $best = $sorted | Where-Object { $_.Host -like '*epicgames.com' -and $null -ne $_.AvgMs } | Select-Object -First 1
    if ($best) { $sync.bestRegion = '{0} {1} ms' -f $best.Region, $best.AvgMs } else { $sync.bestRegion = 'no reply' }
    return $sorted
}

function Format-UTRegionTable {
    param($Rows)
    $rows = @($Rows | Where-Object { $null -ne $_ })
    # The REGION column is sized from the data, not fixed: the baseline row is labelled
    # "Internet (Cloudflare)" (21 characters), and a -14 pad pushed every later column of that one
    # row seven places to the right, in a monospaced box where the whole point is that they line up.
    $w = 'REGION'.Length
    foreach ($r in $rows) { if (([string]$r.Region).Length -gt $w) { $w = ([string]$r.Region).Length } }
    $fmt = '{0,-' + $w + '} {1,6} {2,6} {3,6} {4,7} {5,5}  {6}'
    $row = '{0,-' + $w + '} {1,6} {2,6} {3,6} {4,7} {5,4}%  {6}'
    $lines = @()
    $lines += $fmt -f 'REGION', 'AVG', 'MIN', 'MAX', 'JITTER', 'LOSS', 'LOCATION'
    foreach ($r in $rows) {
        if ($null -eq $r.AvgMs) {
            $lines += $row -f $r.Region, 'n/a', '-', '-', '-', $r.LossPct, ($r.Location + '   (no ICMP reply; not proof the region is down)')
        } else {
            # Kept out of the location text itself: "Dallas jitter!" read as though the place were
            # called that. An arrow makes it obvious the note is about the numbers on this row.
            $flags = @()
            if ($r.JitterMs -gt 5) { $flags += 'high jitter' }
            if ($r.LossPct -gt 0) { $flags += 'packet loss' }
            $note = [string]$r.Location
            if ($flags.Count) { $note += '   <- ' + ($flags -join ', ') }
            $lines += $row -f $r.Region, $r.AvgMs, $r.MinMs, $r.MaxMs, $r.JitterMs, $r.LossPct, $note
        }
    }
    return ($lines -join "`r`n")
}
