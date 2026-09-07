function Start-UTMonitor {
    <#
    .SYNOPSIS
        Starts the 1 Hz sampler in a background runspace. It publishes an immutable snapshot to $sync.metrics.Snapshot
        and never touches the UI. PDH (English counter paths) is used for disk and GPU, Win32 APIs for CPU and RAM,
        .NET for network and ping; WMI is the fallback when the native helpers are unavailable.
    #>
    $script = @'
$ErrorActionPreference = 'Continue'
function Log([string]$m) { Write-UTLog "monitor: $m" }

$osBuild = [System.Environment]::OSVersion.Version.Build
$preferUtility = ($osBuild -lt 26100)     # Task Manager on 24H2+ (2025) shows time-based CPU; older shows Processor Utility
$haveNative = [bool]('UT.NativeV1.PdhQuery' -as [type])
$q = $null; $backend = 'wmi'
if ($haveNative) {
    try {
        $q = New-Object UT.NativeV1.PdhQuery
        $ok = $true
        foreach ($c in @(
            @('cpuUtil', '\Processor Information(_Total)\% Processor Utility'),
            @('cpuTime', '\Processor Information(_Total)\% Processor Time'),
            @('dskIdle', '\PhysicalDisk(_Total)\% Idle Time'),
            @('dskRead', '\PhysicalDisk(_Total)\Disk Read Bytes/sec'),
            @('dskWrite', '\PhysicalDisk(_Total)\Disk Write Bytes/sec'))) {
            if (-not $q.AddEnglish($c[0], $c[1])) { $ok = $false; Log ('PDH cannot add ' + $c[1]) }
        }
        $null = $q.AddEnglish('gpuEng', '\GPU Engine(*)\Utilization Percentage')
        $null = $q.AddEnglish('gpuMem', '\GPU Adapter Memory(*)\Dedicated Usage')
        if ($ok) { $backend = 'pdh'; $null = $q.Collect() } else { $q.Dispose(); $q = $null }
    } catch { Log "PDH init failed: $($_.Exception.Message)"; if ($q) { $q.Dispose() }; $q = $null }
}
Log "backend=$backend build=$osBuild"

$prevCpu = $null
$prevNet = @{}; $prevNetTime = [DateTime]::UtcNow
$pingInet = $null; $pingGw = $null
try {
    if ($haveNative) { $prevCpu = [UT.NativeV1.Sys]::GetCpuTimes() }
    foreach ($n in (Get-UTNetInterfaceBytes)) { $prevNet[$n.Id] = $n }
    $pingInet = New-Object System.Net.NetworkInformation.Ping
    $pingGw = New-Object System.Net.NetworkInformation.Ping
} catch {
    Log "startup failed: $($_.Exception.Message)"
}
$inetTask = $null; $gwTask = $null
$inetMs = $null; $inetStatus = 'n/a'; $gwMs = $null; $gwStatus = 'n/a'
$link = $null; $linkAt = -100000
$lastGpuSamples = @(); $lastGpuMemSamples = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tick = 0; $nextDue = 0

try {
  while (-not $sync.closing) {
    $tick++; $tickStart = $sw.ElapsedMilliseconds
    try {
      $now = [DateTime]::UtcNow

      # ---- CPU
      $cpuTimePct = $null; $cpuUtilPct = $null
      if ($haveNative) {
        $cpuTimes = [UT.NativeV1.Sys]::GetCpuTimes()
        if ($cpuTimes.Ok -and $prevCpu -and $prevCpu.Ok) {
          $dIdle = [double]($cpuTimes.Idle - $prevCpu.Idle)
          $dTotal = [double](($cpuTimes.Kernel + $cpuTimes.User) - ($prevCpu.Kernel + $prevCpu.User))
          if ($dTotal -gt 0) { $cpuTimePct = [math]::Round(100.0 * (1.0 - $dIdle / $dTotal), 1) }
        }
        $prevCpu = $cpuTimes
      }

      $diskActive = $null; $diskRead = $null; $diskWrite = $null; $gpuSamples = @(); $gpuMemSamples = @()
      if ($backend -eq 'pdh') {
        $null = $q.Collect()
        $v = $q.GetValue('cpuUtil', $true);  if (-not [double]::IsNaN($v)) { $cpuUtilPct = [math]::Round($v, 1) }
        $v = $q.GetValue('cpuTime', $false); if ($null -eq $cpuTimePct -and -not [double]::IsNaN($v)) { $cpuTimePct = [math]::Round($v, 1) }
        $v = $q.GetValue('dskIdle', $false); if (-not [double]::IsNaN($v)) { $diskActive = [math]::Round([math]::Max(0.0, [math]::Min(100.0, 100.0 - $v)), 1) }
        $v = $q.GetValue('dskRead', $false); if (-not [double]::IsNaN($v)) { $diskRead = $v }
        $v = $q.GetValue('dskWrite', $false); if (-not [double]::IsNaN($v)) { $diskWrite = $v }
        $gpuSamples = $q.GetArray('gpuEng', $false)
        $gpuMemSamples = $q.GetArray('gpuMem', $false)
      } else {
        try {
          $ci = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
          $cpuUtilPct = [double]$ci.PercentProcessorUtility
          if ($null -eq $cpuTimePct) { $cpuTimePct = [double]$ci.PercentProcessorTime }
        } catch { }
        try {
          $di = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
          $diskActive = [math]::Max(0.0, [math]::Min(100.0, 100.0 - [double]$di.PercentIdleTime)); $diskRead = [double]$di.DiskReadBytesPersec; $diskWrite = [double]$di.DiskWriteBytesPersec
        } catch { }
        # The GPU classes are the expensive ones, so they are read every other tick; the previous
        # samples are reused in between so the GPU graph still advances once per second like the others.
        if (($tick % 2) -eq 0) {
          try { $gpuSamples = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Instance = $_.Name; Value = [double]$_.UtilizationPercentage } }) } catch { }
          try { $gpuMemSamples = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Instance = $_.Name; Value = [double]$_.DedicatedUsage } }) } catch { }
          $lastGpuSamples = $gpuSamples; $lastGpuMemSamples = $gpuMemSamples
        } else {
          $gpuSamples = $lastGpuSamples; $gpuMemSamples = $lastGpuMemSamples
        }
      }

      # ---- foreground (needed for per-game GPU share)
      $fg = Get-UTForegroundState

      # ---- GPU: Task Manager headline = busiest engine of the adapter (sum over processes per engine, max over engines)
      $engines = @{}; $gamePid3D = 0.0
      foreach ($s in $gpuSamples) {
        if ($null -eq $s -or [double]::IsNaN($s.Value) -or $s.Value -le 0) { continue }
        if ($s.Instance -match '^pid_(\d+)_luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_phys_(\d+)_eng_(\d+)_engtype_(.+)$') {
          $k = '{0}|{1}|{2}' -f $Matches[2], $Matches[4], $Matches[5]
          $engines[$k] = [double]$engines[$k] + $s.Value
          if ($fg.Pid -gt 0 -and [int]$Matches[1] -eq $fg.Pid -and $Matches[5] -match '^3D') { $gamePid3D += $s.Value }
        }
      }
      $adapters = @{}
      foreach ($k in @($engines.Keys)) {
        $parts = $k.Split('|'); $luid = $parts[0]; $val = [math]::Min(100.0, $engines[$k])
        if (-not $adapters.ContainsKey($luid)) { $adapters[$luid] = @{ Max = 0.0; Engine = ''; ThreeD = 0.0 } }
        if ($val -gt $adapters[$luid].Max) { $adapters[$luid].Max = $val; $adapters[$luid].Engine = $parts[2] }
        if ($parts[2] -match '^3D') { $adapters[$luid].ThreeD = [math]::Min(100.0, $adapters[$luid].ThreeD + $val) }
      }
      $gpuLuid = $null
      if ($adapters.Count -gt 0) { $gpuLuid = (@($adapters.GetEnumerator() | Sort-Object { $_.Value.Max } -Descending)[0]).Key }
      $gpuPct = $null; $gpu3D = $null; $gpuEngine = ''
      if ($gpuLuid) { $gpuPct = [math]::Round($adapters[$gpuLuid].Max, 1); $gpu3D = [math]::Round($adapters[$gpuLuid].ThreeD, 1); $gpuEngine = $adapters[$gpuLuid].Engine }
      $gpuDedicated = $null
      foreach ($m in $gpuMemSamples) {
        if ($null -eq $m -or [double]::IsNaN($m.Value)) { continue }
        if ($m.Instance -match '^luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)_phys_\d+$' -and $Matches[1] -eq $gpuLuid) { $gpuDedicated = [int64]$m.Value }
      }

      # ---- RAM
      $memUsedPct = $null; $memTotal = 0; $memAvail = 0
      if ($haveNative) {
        $mem = [UT.NativeV1.Sys]::GetMem()
        if ($mem.Ok -and $mem.TotalPhys -gt 0) { $memTotal = [int64]$mem.TotalPhys; $memAvail = [int64]$mem.AvailPhys; $memUsedPct = [math]::Round(100.0 * ($memTotal - $memAvail) / $memTotal, 1) }
      } else {
        try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $memTotal = [int64]$os.TotalVisibleMemorySize * 1KB; $memAvail = [int64]$os.FreePhysicalMemory * 1KB; if ($memTotal -gt 0) { $memUsedPct = [math]::Round(100.0 * ($memTotal - $memAvail) / $memTotal, 1) } } catch { }
      }

      # ---- Network (delta of NDIS byte counters)
      $dt = ($now - $prevNetTime).TotalSeconds
      $netRx = 0.0; $netTx = 0.0; $linkBps = 0
      foreach ($n in (Get-UTNetInterfaceBytes)) {
        if ($prevNet.ContainsKey($n.Id) -and $dt -gt 0) {
          $netRx += [math]::Max(0.0, ($n.Rx - $prevNet[$n.Id].Rx) / $dt)
          $netTx += [math]::Max(0.0, ($n.Tx - $prevNet[$n.Id].Tx) / $dt)
        }
        if ($n.SpeedBps -gt $linkBps) { $linkBps = $n.SpeedBps }
        $prevNet[$n.Id] = $n
      }
      $prevNetTime = $now

      # ---- link info every 10 s (Get-NetAdapter is slow)
      if (($sw.ElapsedMilliseconds - $linkAt) -ge 10000) { try { $link = Get-UTNetworkLink } catch { }; $linkAt = $sw.ElapsedMilliseconds }

      # ---- pings (async so a timeout never stalls the tick)
      if ($inetTask -and $inetTask.IsCompleted) {
        try { if ($inetTask.IsFaulted) { $inetStatus = 'error'; $inetMs = $null } else { $r = $inetTask.Result; $inetStatus = [string]$r.Status; if ($r.Status -eq 'Success') { $inetMs = [int]$r.RoundtripTime } else { $inetMs = $null } } } catch { $inetStatus = 'error'; $inetMs = $null }
        $inetTask = $null
      }
      if (-not $inetTask -and $pingInet) { try { $inetTask = $pingInet.SendPingAsync('1.1.1.1', 1000) } catch { $inetTask = $null } }
      if ($gwTask -and $gwTask.IsCompleted) {
        try { if ($gwTask.IsFaulted) { $gwStatus = 'error'; $gwMs = $null } else { $r = $gwTask.Result; $gwStatus = [string]$r.Status; if ($r.Status -eq 'Success') { $gwMs = [int]$r.RoundtripTime } else { $gwMs = $null } } } catch { $gwStatus = 'error'; $gwMs = $null }
        $gwTask = $null
      }
      if (-not $gwTask -and $pingGw -and $link -and $link.Gateway -and $link.Gateway -ne '0.0.0.0') { try { $gwTask = $pingGw.SendPingAsync($link.Gateway, 1000) } catch { $gwTask = $null } }

      $cpuPct = $cpuTimePct
      if ($preferUtility -and $null -ne $cpuUtilPct) { $cpuPct = [math]::Min(100.0, $cpuUtilPct) }

      $snap = [pscustomobject]@{
        Tick = $tick; Time = [DateTime]::Now; Backend = $backend
        CpuPercent = $cpuPct; CpuUtilityPercent = $cpuUtilPct; CpuTimePercent = $cpuTimePct
        MemUsedPercent = $memUsedPct; MemTotalBytes = $memTotal; MemAvailBytes = $memAvail
        DiskActivePercent = $diskActive; DiskReadBps = $diskRead; DiskWriteBps = $diskWrite
        GpuPercent = $gpuPct; Gpu3DPercent = $gpu3D; GpuBusiestEngine = $gpuEngine; GpuDedicatedBytes = $gpuDedicated; GameGpu3D = [math]::Round([math]::Min(100.0, $gamePid3D), 1)
        NetRxBps = $netRx; NetTxBps = $netTx; LinkBps = $linkBps; Link = $link
        InetMs = $inetMs; InetStatus = $inetStatus; GatewayMs = $gwMs; GatewayStatus = $gwStatus
        Foreground = $fg
        SampleMs = ($sw.ElapsedMilliseconds - $tickStart)
      }
      if ($tick -gt 1) { $sync.metrics.Snapshot = $snap }
    } catch { Log "tick $tick error: $($_.Exception.Message)" }

    $nextDue += 1000
    $sleep = $nextDue - $sw.ElapsedMilliseconds
    if ($sleep -gt 0) { Start-Sleep -Milliseconds $sleep } else { $nextDue = $sw.ElapsedMilliseconds }
  }
} finally {
  if ($q) { $q.Dispose() }
  if ($pingInet) { $pingInet.Dispose() }
  if ($pingGw) { $pingGw.Dispose() }
  Log 'stopped'
}
'@
    $rs = [runspacefactory]::CreateRunspace((New-UTSessionState))
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script)
    $handle = $ps.BeginInvoke()
    $sync.monitor = @{ PowerShell = $ps; Runspace = $rs; Handle = $handle }
}

function Stop-UTMonitor {
    $sync.closing = $true
    if (-not $sync.monitor) { return }
    try {
        # A slow tick (WMI fallback enumerating GPU counters) can take several seconds, so give it room
        # to notice $sync.closing and exit on its own before forcing it.
        if (-not $sync.monitor.Handle.AsyncWaitHandle.WaitOne(6000)) { $sync.monitor.PowerShell.Stop() }
        try { $null = $sync.monitor.PowerShell.EndInvoke($sync.monitor.Handle) } catch { }
        $sync.monitor.PowerShell.Dispose(); $sync.monitor.Runspace.Close(); $sync.monitor.Runspace.Dispose()
    } catch { }
}
