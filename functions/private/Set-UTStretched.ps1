function Get-UTStretchedStatePath { return (Join-Path $sync.backupDir 'stretched-state.json') }

function Test-UTStretchedState { return (Test-Path -LiteralPath (Get-UTStretchedStatePath)) }

function Get-UTDisplayState {
    <#
    .SYNOPSIS
        Current desktop mode, the modes Windows lists, the scaling the active path uses, NVIDIA availability
        and the monitor devices, so the STRETCHED tab can say what will happen before it happens.
    #>
    $s = [pscustomobject]@{ Width = 0; Height = 0; Hz = 0; Scaling = 0; ScalingName = 'unknown'; Modes = @(); Nvidia = $false; Monitors = @(); Active = (Test-UTStretchedState) }
    if (-not ('UT.NativeV1.Display' -as [type])) { return $s }
    try {
        $cur = [UT.NativeV1.Display]::GetCurrent()
        $s.Width = $cur.Width; $s.Height = $cur.Height; $s.Hz = $cur.Hz
        $s.Modes = @([UT.NativeV1.Display]::EnumModes() | ForEach-Object { [pscustomobject]@{ Width = $_.Width; Height = $_.Height; Hz = $_.Hz } })
        $s.Scaling = [int][UT.NativeV1.Display]::GetScaling()
        $s.ScalingName = switch ($s.Scaling) { 1 { 'identity' } 2 { 'centered' } 3 { 'stretched' } 4 { 'aspect ratio' } 5 { 'custom' } 128 { 'preferred' } default { 'unknown' } }
        $s.Nvidia = [UT.NativeV1.NvApi]::IsAvailable()
    } catch { }
    $s.Monitors = @(Get-UTMonitorDevices)
    return $s
}

function Get-UTMonitorDevices {
    @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Where-Object { $_.Present } |
      ForEach-Object { [pscustomobject]@{ InstanceId = [string]$_.InstanceId; Name = [string]$_.FriendlyName; Status = [string]$_.Status } })
}

function Set-UTMonitorDevice {
    param([Parameter(Mandatory = $true)][string]$InstanceId, [Parameter(Mandatory = $true)][bool]$Enable)
    $verb = '/disable-device'
    if ($Enable) { $verb = '/enable-device' }
    $r = Invoke-UTNative -FilePath 'pnputil.exe' -Arguments @($verb, $InstanceId)
    if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 259) { throw ("pnputil {0} failed (exit {1}): {2}" -f $verb, $r.ExitCode, $r.Output.Trim()) }
    Write-UTLog ("monitor device {0}: {1}" -f $InstanceId, $(if ($Enable) { 'enabled' } else { 'disabled' }))
}

function Test-UTDisplayMode {
    param([int]$Width, [int]$Height)
    foreach ($m in [UT.NativeV1.Display]::EnumModes()) { if ($m.Width -eq $Width -and $m.Height -eq $Height) { return $true } }
    return $false
}

function Get-UTBestRefresh {
    param([int]$Width, [int]$Height, [int]$Prefer)
    $rates = @([UT.NativeV1.Display]::EnumModes() | Where-Object { $_.Width -eq $Width -and $_.Height -eq $Height } | ForEach-Object { [int]$_.Hz })
    if ($rates -contains $Prefer) { return $Prefer }
    if ($rates.Count -gt 0) { return ($rates | Sort-Object -Descending)[0] }
    return $Prefer
}

function Add-UTCustomMode {
    <#
    .SYNOPSIS
        Makes sure Windows offers WidthxHeight. Standard 4:3 modes already exist; the wide stretched ones
        (1440x1080, 1600x1080, 1728x1080) need a custom mode, created through the NVIDIA driver's own API.
    #>
    param([Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][int]$Height, [int]$Hz = 0)
    if (Test-UTDisplayMode -Width $Width -Height $Height) { Write-UTLog ("{0}x{1} is already offered by Windows" -f $Width, $Height); return $true }
    if (-not [UT.NativeV1.NvApi]::IsAvailable()) {
        throw ("{0}x{1} is not offered by Windows and this PC has no NVIDIA driver to create it with. Add it in your GPU's control panel (AMD: Display > Custom Resolutions; Intel: Display > Custom) and try again." -f $Width, $Height)
    }
    if ($Hz -le 0) { $Hz = [UT.NativeV1.Display]::GetCurrent().Hz }
    $r = [UT.NativeV1.NvApi]::AddMode($Width, $Height, $Hz)
    if ($r -ne 'ok') {
        throw ("The NVIDIA driver refused to create {0}x{1}@{2}: {3}. Create it once by hand in NVIDIA Control Panel > Change resolution > Customize > Create Custom Resolution, then this tool can use it." -f $Width, $Height, $Hz, $r)
    }
    Write-UTLog ("custom mode {0}x{1}@{2} created through NVIDIA's driver API" -f $Width, $Height, $Hz) -Level Ok
    return $true
}

function Set-UTDisplayScaling {
    param([Parameter(Mandatory = $true)][int]$Scaling)
    $rc = [UT.NativeV1.Display]::SetScaling([uint32]$Scaling)
    if ($rc -ne 0) { throw ("SetDisplayConfig refused scaling {0} (error {1})" -f $Scaling, $rc) }
}

function Set-UTDisplayMode {
    param([Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][int]$Height, [int]$Hz = 0)
    $rc = [UT.NativeV1.Display]::SetMode($Width, $Height, $Hz, $true)
    if ($rc -ne 0) { throw ("Windows refused the mode {0}x{1}@{2} (DISP_CHANGE {3})" -f $Width, $Height, $Hz, $rc) }
    Write-UTLog ("desktop switched to {0}x{1}@{2}" -f $Width, $Height, $Hz)
}

function Write-UTStretchedGameConfig {
    param([string]$Game, [int]$Width, [int]$Height)
    $w = [string]$Width; $h = [string]$Height
    switch ($Game) {
        'Fortnite' {
            $fn = Get-UTFortnite
            if ($fn.GameRunning) { throw 'Fortnite is running; close it first' }
            if (-not $fn.GameIniExists) { throw 'Fortnite GameUserSettings.ini not found; start the game once' }
            Backup-UTFile -Path $fn.GameIni
            $keys = @{ ResolutionSizeX = $w; ResolutionSizeY = $h; LastUserConfirmedResolutionSizeX = $w; LastUserConfirmedResolutionSizeY = $h
                       DesiredScreenWidth = $w; DesiredScreenHeight = $h; LastUserConfirmedDesiredScreenWidth = $w; LastUserConfirmedDesiredScreenHeight = $h
                       FullscreenMode = '0'; LastConfirmedFullscreenMode = '0'; PreferredFullscreenMode = '0' }
            [void](Set-UTIniValues -Path $fn.GameIni -Settings @{ $sync.configs.fortnite.MainSection = $keys })
        }
        'Valorant' {
            $v = Get-UTValorant
            if ($v.GameRunning) { throw 'VALORANT is running; close it first' }
            if (-not $v.GameIniExists) { throw 'VALORANT GameUserSettings.ini not found; start the game once' }
            Backup-UTFile -Path $v.GameIni
            $keys = @{ ResolutionSizeX = $w; ResolutionSizeY = $h; LastUserConfirmedResolutionSizeX = $w; LastUserConfirmedResolutionSizeY = $h
                       DesiredScreenWidth = $w; DesiredScreenHeight = $h; LastUserConfirmedDesiredScreenWidth = $w; LastUserConfirmedDesiredScreenHeight = $h
                       bShouldLetterbox = 'False'; bLastConfirmedShouldLetterbox = 'False'; LastConfirmedFullscreenMode = '0'; PreferredFullscreenMode = '0' }
            [void](Set-UTIniValues -Path $v.GameIni -Settings @{ $sync.configs.valorant.GameSection = $keys })
        }
    }
}

function Start-UTStretched {
    <#
    .SYNOPSIS
        The whole stretched session: record what to put back, make sure the mode exists, set GPU scaling to
        stretched, write the game's resolution, disable the monitor device for VALORANT, switch the desktop,
        launch, wait for the game to close, put everything back.
    .DESCRIPTION
        The state file is written before the first change and deleted after the last restore, so a crash
        anywhere in between is repaired at the tool's next start. VALORANT reads the monitor's native aspect
        ratio from its EDID and locks fullscreen to it, which is why its monitor device is disabled for the
        duration; Windows keeps driving the display through the generic monitor driver meanwhile.
    #>
    param([Parameter(Mandatory = $true)][int]$Width, [Parameter(Mandatory = $true)][int]$Height, [string]$Game = 'None')
    if (Test-UTStretchedState) { throw 'A stretched session is already active. Press Restore desktop first.' }
    if (-not ('UT.NativeV1.Display' -as [type])) { throw 'The native display helper is not available on this PC' }
    $cur = [UT.NativeV1.Display]::GetCurrent()
    $state = [ordered]@{ Width = $cur.Width; Height = $cur.Height; Hz = $cur.Hz; Scaling = [int][UT.NativeV1.Display]::GetScaling(); Monitors = @(); Game = $Game; Started = (Get-Date).ToString('s') }
    $statePath = Get-UTStretchedStatePath
    ([pscustomobject]$state) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding ASCII
    try {
        [void](Add-UTCustomMode -Width $Width -Height $Height -Hz $cur.Hz)
        $hz = Get-UTBestRefresh -Width $Width -Height $Height -Prefer $cur.Hz
        Write-UTStretchedGameConfig -Game $Game -Width $Width -Height $Height
        if ($Game -eq 'Valorant') {
            foreach ($m in (Get-UTMonitorDevices | Where-Object { $_.Status -eq 'OK' })) {
                Set-UTMonitorDevice -InstanceId $m.InstanceId -Enable $false
                $state.Monitors += $m.InstanceId
                ([pscustomobject]$state) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding ASCII
            }
        }
        Set-UTDisplayMode -Width $Width -Height $Height -Hz $hz
        # Best-effort: SDC_SAVE_TO_DATABASE persists stretched for this mode. Whether the panel then
        # fills or letterboxes is the GPU's call; on some drivers it is a one-time control-panel setting
        # (NVIDIA: "Adjust desktop size and position" > Full-screen, Scaling performed on GPU). We do not
        # read the scaling straight back to verify: right after SDC_APPLY that read is unreliable.
        try { Set-UTDisplayScaling -Scaling 3 } catch { Write-UTLog ('GPU scaling could not be set to stretched (' + $_.Exception.Message + '); if you see black bars, set Full-screen scaling once in your GPU control panel') -Level Warn }
        $proc = ''
        switch ($Game) {
            'Fortnite' { Start-Process $sync.configs.fortnite.LaunchUri | Out-Null; $proc = $sync.configs.fortnite.GameProcess; Write-UTLog 'Fortnite launch requested through Epic' }
            'Valorant' { Start-UTValorant; $proc = $sync.configs.valorant.GameProcess }
            default    { Write-UTLog ("desktop is {0}x{1} stretched; press Restore desktop when you are done" -f $Width, $Height) -Level Ok; return }
        }
        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline -and -not (Get-Process -Name $proc -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2 }
        if (-not (Get-Process -Name $proc -ErrorAction SilentlyContinue)) { throw ("{0} did not start within three minutes" -f $proc) }
        Write-UTLog ("{0} is running at {1}x{2} stretched; the desktop goes back when it closes" -f $proc, $Width, $Height) -Level Ok
        while (Get-Process -Name $proc -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 3 }
        Write-UTLog ("{0} closed" -f $proc)
    } catch {
        Write-UTLog ('stretched: ' + $_.Exception.Message) -Level Error
    }
    Restore-UTStretched
}

function Restore-UTStretched {
    $statePath = Get-UTStretchedStatePath
    if (-not (Test-Path -LiteralPath $statePath)) { Write-UTLog 'No stretched session to restore'; return }
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $failed = @()
    foreach ($id in @($st.Monitors)) { try { Set-UTMonitorDevice -InstanceId $id -Enable $true } catch { $failed += $_.Exception.Message } }
    try { if ('UT.NativeV1.Display' -as [type]) { Set-UTDisplayMode -Width $st.Width -Height $st.Height -Hz $st.Hz } } catch { $failed += $_.Exception.Message }
    try { if (('UT.NativeV1.Display' -as [type]) -and $st.Scaling -gt 1) { Set-UTDisplayScaling -Scaling ([int]$st.Scaling) } } catch { $failed += $_.Exception.Message }
    if ($failed.Count -gt 0) { throw ("desktop partly restored; the state file is kept so you can retry: " + ($failed -join '; ')) }
    Remove-Item -LiteralPath $statePath -Force
    Write-UTLog ("desktop restored to {0}x{1}@{2}, scaling {3}" -f $st.Width, $st.Height, $st.Hz, $st.Scaling) -Level Ok
}
