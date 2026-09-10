function Invoke-UTBenchmark {
    <#
    .SYNOPSIS
        A short synthetic run: CPU single and all-core throughput, memory copy bandwidth, system-disk
        sequential read and write with the cache bypassed. About ten seconds. Numbers are relative to
        the machine the tool was calibrated on (Ryzen 7 5800XT, DDR4-3200, NVMe = 100).
    #>
    if (-not ('UT.NativeV1.Bench' -as [type])) { throw 'The native benchmark helper is not available on this PC' }
    $r = [ordered]@{}
    Write-UTLog 'benchmark: CPU single core (3 s)'
    $r.CpuSingleMops = [math]::Round([UT.NativeV1.Bench]::CpuSingle(3000) / 1e6, 1)
    $threads = [Environment]::ProcessorCount
    Write-UTLog ("benchmark: CPU all cores, {0} threads (3 s)" -f $threads)
    $r.CpuMultiMops = [math]::Round([UT.NativeV1.Bench]::CpuMulti(3000, $threads) / 1e6, 1)
    Write-UTLog 'benchmark: memory copy (256 MB x 8)'
    $r.MemoryGBps = [math]::Round([UT.NativeV1.Bench]::MemCopy(256, 8), 1)
    Write-UTLog 'benchmark: system disk, 256 MB sequential, cache bypassed'
    $r.DiskWriteMBps = 0; $r.DiskReadMBps = 0
    try {
        $disk = Measure-UTDiskSequential -SizeMB 256
        $r.DiskWriteMBps = $disk.WriteMBps
        $r.DiskReadMBps = $disk.ReadMBps
    } catch { Write-UTLog ('benchmark: disk test skipped (' + $_.Exception.Message + ')') -Level Warn }
    $ref = @{ CpuSingleMops = 670.0; CpuMultiMops = 9100.0; MemoryGBps = 17.8; DiskReadMBps = 2500.0 }
    $r.CpuSingleScore = [math]::Round(100.0 * $r.CpuSingleMops / $ref.CpuSingleMops)
    $r.CpuMultiScore = [math]::Round(100.0 * $r.CpuMultiMops / $ref.CpuMultiMops)
    $r.MemoryScore = [math]::Round(100.0 * $r.MemoryGBps / $ref.MemoryGBps)
    $r.DiskScore = [math]::Round(100.0 * $r.DiskReadMBps / $ref.DiskReadMBps)
    $r.Tier = Get-UTPerformanceTier -CpuSingle $r.CpuSingleScore -CpuMulti $r.CpuMultiScore -Gpu $sync.sysinfo.GPU
    $r.When = (Get-Date).ToString('s')
    $sync.benchmark = [pscustomobject]$r
    Write-UTLog ("benchmark: CPU single {0} / multi {1} / memory {2} / disk {3}   (Ryzen 7 5800XT + NVMe = 100)   tier: {4}" -f $r.CpuSingleScore, $r.CpuMultiScore, $r.MemoryScore, $r.DiskScore, $r.Tier) -Level Ok
    return $sync.benchmark
}

function Measure-UTDiskSequential {
    param([int]$SizeMB = 256)
    $dir = Join-Path $env:LOCALAPPDATA 'unknowntweaks'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ('bench-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $block = New-Object byte[] (4MB)
    (New-Object System.Random).NextBytes($block)
    $noBuffer = [System.IO.FileOptions]0x20000000 -bor [System.IO.FileOptions]::WriteThrough
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4MB, $noBuffer)
        try { for ($i = 0; $i -lt $SizeMB / 4; $i++) { $fs.Write($block, 0, $block.Length) }; $fs.Flush($true) } finally { $fs.Dispose() }
        $write = $SizeMB / $sw.Elapsed.TotalSeconds
        $sw.Restart()
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None, 4MB, ([System.IO.FileOptions]0x20000000))
        try { while ($fs.Read($block, 0, $block.Length) -gt 0) { } } finally { $fs.Dispose() }
        $read = $SizeMB / $sw.Elapsed.TotalSeconds
        return [pscustomobject]@{ WriteMBps = [math]::Round($write); ReadMBps = [math]::Round($read) }
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-UTPerformanceTier {
    param([int]$CpuSingle, [int]$CpuMulti, [string]$Gpu)
    $gpuTier = 1
    if ($Gpu -match 'RTX (40|50)\d\d|RX (7[89]|9[0-9])\d\d') { $gpuTier = 3 }
    elseif ($Gpu -match 'RTX (20|30)\d\d|RX (6[6-9]|7[0-7])\d\d|GTX 16[68]0|RTX 4060') { $gpuTier = 2 }
    elseif ($Gpu -match 'Intel|Vega|Radeon\(TM\) Graphics|UHD|Iris') { $gpuTier = 0 }
    $cpuTier = 1
    if ($CpuSingle -ge 90 -and $CpuMulti -ge 80) { $cpuTier = 3 } elseif ($CpuSingle -ge 65) { $cpuTier = 2 } elseif ($CpuSingle -lt 45) { $cpuTier = 0 }
    switch ([math]::Min($gpuTier, $cpuTier)) {
        3 { return 'high-end' }
        2 { return 'mid-range' }
        1 { return 'entry' }
        default { return 'low' }
    }
}

function Get-UTRecommendations {
    <#
    .SYNOPSIS
        Tweaks worth ticking on this PC, each with the reason, from the hardware facts and the last
        benchmark. Safe and optional ones can be ticked automatically; risky ones are only ever named.
    #>
    $si = $sync.sysinfo
    $b = $sync.benchmark
    $tw = $sync.configs.tweaks
    $out = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Id, $Why, $Tick)
        if (-not $tw.$Id) { return }
        $out.Add([pscustomobject]@{ Id = $Id; Content = [string]$tw.$Id.Content; Tier = [string]$tw.$Id.Tier; Why = $Why; Tick = [bool]$Tick })
    }
    foreach ($p in $tw.PSObject.Properties) { if ($p.Value.Tier -eq 'safe' -and $p.Value.Recommended -and (Test-UTTweakEligible -Tweak $p.Value)) { & $add $p.Name 'in the safe preset: documented mechanism, no downside' $true } }
    if ($si.VBSStatus -eq 2 -or $si.HVCIRunning) {
        & $add 'UTHVCIOff' 'memory integrity is running on this PC: the largest measured FPS cost in the catalogue (4 to 8 percent, more when CPU-bound)' $false
        & $add 'UTVBSOff' 'virtualization-based security is running: turning the hypervisor off is the rest of that gain. Breaks WSL2, Hyper-V and Sandbox' $false
    }
    if ($si.IsLaptop) {
        & $add 'UTPowerThrottlingOff' 'laptop: Windows throttles background CPU frequency on battery-class hardware' $true
        & $add 'UTNicPowerSaving' 'laptop: NIC link power states add latency and are on by default here' $true
    } else {
        & $add 'UTHibernateOff' 'desktop: hibernation only costs disk space here' $true
        if ($b -and $b.CpuSingleScore -lt 70) { & $add 'UTUltimatePerf' 'older CPU without hardware P-states: the Ultimate Performance plan removes clock ramp-up delay' $true }
    }
    if ($si.DiskType -eq 'HDD') { & $add 'UTSearchIndexOff' 'the system drive is a hard disk: the indexer causes I/O stutter there' $true }
    if ($si.GPUVendor -eq 'NVIDIA' -or $si.GPUVendor -eq 'AMD') { & $add 'UTVendorGpuTasks' ($si.GPUVendor + ' driver: its telemetry and update-check tasks run in the background') $true }
    if ($si.GPU -match 'RTX|RX (5|6|7|9)\d\d\d|GTX 1[06]\d0') { & $add 'UTHAGS' 'this GPU supports hardware scheduling; required for DLSS Frame Generation, otherwise neutral' $false }
    if ($si.Is11 -and $si.Build -ge 22621) { & $add 'UTWindowedGamesOpt' 'Windows 11 22H2+: flip-model presentation for windowed games lowers latency' $true }
    if ($si.CPU -match 'X3D') { & $add 'UTCoreParkingOff' 'X3D CPU: this tweak is refused on purpose, Windows parks cores to keep games on the V-Cache die' $false }
    if ($b -and $b.Tier -in 'low', 'entry') {
        & $add 'UTGameModeOff' 'entry-level PC: try Game Mode off if you see stutter, it helps some low-end systems' $false
    }
    return $out.ToArray()
}
