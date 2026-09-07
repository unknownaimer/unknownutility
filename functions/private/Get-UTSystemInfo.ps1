function Get-UTGpuMemoryBytes {
    <#
    .SYNOPSIS
        64-bit VRAM size from the display class registry (Win32_VideoController.AdapterRAM overflows at 4 GB).
    #>
    param([string]$DriverDesc)
    try {
        $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($sub in (Get-ChildItem -LiteralPath $class -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
            if ($p.DriverDesc -eq $DriverDesc -and $p.'HardwareInformation.qwMemorySize') {
                return [int64]$p.'HardwareInformation.qwMemorySize'
            }
        }
    } catch { }
    return $null
}

function Get-UTSystemInfo {
    <#
    .SYNOPSIS
        One-shot hardware / OS facts used by the UI and by tweak guards (laptop, build, GPU vendor, VBS, BitLocker).
    #>
    $info = @{}
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ver = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $info.OSName = [string]$os.Caption
        $info.Build = [int]$os.BuildNumber
        $info.UBR = [int]$ver.UBR
        $info.DisplayVersion = [string]$ver.DisplayVersion
        if (-not $info.DisplayVersion) { $info.DisplayVersion = [string]$ver.ReleaseId }
        $info.Edition = [string]$ver.EditionID
        $info.Is11 = ($info.Build -ge 22000)
        $info.RamGB = [math]::Round(([double]$cs.TotalPhysicalMemory) / 1GB, 1)
        $info.ComputerName = [string]$cs.Name
        $info.ConsoleUser = [string]$cs.UserName
        $info.RunningAs = "$env:USERDOMAIN\$env:USERNAME"
        # Win32_ComputerSystem.UserName is DOMAIN\user, but for a Microsoft account the local profile name
        # is a truncated form, so only the account part is comparable and only when both are known.
        $consoleAccount = ($info.ConsoleUser -split '\\')[-1]
        $info.DifferentUser = ($consoleAccount -and $env:USERNAME -and ($consoleAccount -ne $env:USERNAME))
        $laptop = ([int]$cs.PCSystemType -eq 2)
        try {
            $chassis = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
            foreach ($c in $chassis) { if ([int]$c -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32) { $laptop = $true } }
        } catch { }
        try { if (Get-CimInstance Win32_Battery -ErrorAction Stop) { $laptop = $true } } catch { }
        $info.IsLaptop = $laptop
    } catch {
        $info.OSName = 'Windows'; $info.Build = 0; $info.IsLaptop = $false
    }
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $info.CPU = ([string]$cpu.Name).Trim()
        $info.Cores = [int]$cpu.NumberOfCores
        $info.Threads = [int]$cpu.NumberOfLogicalProcessors
    } catch { $info.CPU = 'unknown CPU' }
    $gpus = @()
    try {
        foreach ($g in (Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if (-not $g.Name) { continue }
            $vendor = 'Other'
            if ($g.Name -match 'NVIDIA|GeForce|RTX|GTX') { $vendor = 'NVIDIA' }
            elseif ($g.Name -match 'AMD|Radeon') { $vendor = 'AMD' }
            elseif ($g.Name -match 'Intel') { $vendor = 'Intel' }
            $vram = Get-UTGpuMemoryBytes -DriverDesc $g.Name
            if (-not $vram) { $vram = [int64]$g.AdapterRAM }
            $gpus += [pscustomobject]@{ Name = $g.Name; Vendor = $vendor; VramGB = [math]::Round($vram / 1GB, 1); Driver = [string]$g.DriverVersion }
        }
    } catch { }
    $info.GPUs = $gpus
    $primary = $gpus | Sort-Object VramGB -Descending | Select-Object -First 1
    if ($primary) { $info.GPU = $primary.Name; $info.GPUVendor = $primary.Vendor; $info.VramGB = $primary.VramGB } else { $info.GPU = 'unknown GPU'; $info.GPUVendor = 'Other'; $info.VramGB = 0 }
    try {
        $sysDisk = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $phys = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $sysDisk.Number } | Select-Object -First 1
        $info.DiskType = [string]$phys.MediaType
        $info.DiskBus = [string]$phys.BusType
    } catch { $info.DiskType = 'unknown'; $info.DiskBus = '' }
    try {
        $vol = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
        $info.DiskFreeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
        $info.DiskSizeGB = [math]::Round($vol.Size / 1GB, 1)
    } catch { }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $info.VBSStatus = [int]$dg.VirtualizationBasedSecurityStatus
        $info.HVCIRunning = (@($dg.SecurityServicesRunning) -contains 2)
        $info.CredentialGuardRunning = (@($dg.SecurityServicesRunning) -contains 1)
    } catch { $info.VBSStatus = -1; $info.HVCIRunning = $false; $info.CredentialGuardRunning = $false }
    try { $info.SecureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { $info.SecureBoot = $false }
    $info.BitLocker = Get-UTBitLockerStatus
    try {
        $plan = (Invoke-UTNative -FilePath 'powercfg.exe' -Arguments @('/getactivescheme')).Output
        if ($plan -match '\(([^)]+)\)') { $info.PowerPlan = $Matches[1] } else { $info.PowerPlan = $plan.Trim() }
    } catch { $info.PowerPlan = '' }
    try {
        $hags = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
        $info.HAGS = ($hags -eq 2)
    } catch { $info.HAGS = $false }
    return [pscustomobject]$info
}
