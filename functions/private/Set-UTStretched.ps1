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

function Get-UTMaxRefresh {
    <#
    .SYNOPSIS
        The highest refresh rate this panel offers at any resolution.
    .DESCRIPTION
        A stretched mode is worth nothing at 60 Hz on a 240 Hz monitor, and a custom mode is timed by
        the driver from whatever rate is asked for, so the panel's maximum is what to ask for.
    #>
    $rates = @([UT.NativeV1.Display]::EnumModes() | ForEach-Object { [int]$_.Hz })
    if ($rates.Count -eq 0) { return 60 }
    return ($rates | Sort-Object -Descending)[0]
}

function Get-UTBestRefresh {
    <#
    .SYNOPSIS
        The highest refresh Windows lists for this exact mode, falling back to the panel's maximum.
    #>
    param([int]$Width, [int]$Height)
    $rates = @([UT.NativeV1.Display]::EnumModes() | Where-Object { $_.Width -eq $Width -and $_.Height -eq $Height } | ForEach-Object { [int]$_.Hz })
    if ($rates.Count -gt 0) { return ($rates | Sort-Object -Descending)[0] }
    return (Get-UTMaxRefresh)
}

function Get-UTStretchedPresets {
    <#
    .SYNOPSIS
        The stretched modes worth offering on this monitor: every ratio from config/stretched.json at
        every sensible vertical resolution, with whether Windows already lists it and whether VALORANT
        will take it.
    .DESCRIPTION
        Heights are 1080 (fewer pixels, the reason most people do this) plus the panel's own height
        when it is taller, so a 1440p or 4K owner can stretch without dropping to 1080p. Widths are
        rounded to an even number because odd widths upset some timings.

        The VALORANT column is three-state, because black bars have two different causes. Riot
        documents support for 4:3, 5:4, 16:9, 16:10 and 21:9; those ratios fill. A ratio outside that
        set is not refused, and plenty of players use 1680x1080, but whether it fills rests entirely
        on the driver scaler, so it is labelled rather than promised. Anything at or wider than 16:9
        is pillarboxed by the game itself on purpose and is never generated here. Below the game's
        1280x720 minimum nothing works at all.
    #>
    $cur = [UT.NativeV1.Display]::GetCurrent()
    $heights = New-Object System.Collections.Generic.List[int]
    foreach ($h in @(1080, [int]$cur.Height)) { if ($h -ge 720 -and -not $heights.Contains($h)) { [void]$heights.Add($h) } }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($h in ($heights | Sort-Object)) {
        foreach ($r in @($sync.configs.stretched.Ratios)) {
            $w = [int]([math]::Round(($h * [double]$r.Ratio) / 2.0) * 2)
            if ($w -ge [int]$cur.Width) { continue }
            $fill = 'fills'
            if ($w -lt 1280 -or $h -lt 720) { $fill = 'too small' }
            elseif (-not [bool]$r.ValorantRatio) { $fill = 'non-standard' }
            $out.Add([pscustomobject]@{
                Width = $w; Height = $h; Tag = ('{0}x{1}' -f $w, $h)
                RatioName = [string]$r.Name; Label = [string]$r.Label; Common = [string]$r.Common
                ValorantFill = $fill
                Valorant = ($fill -ne 'too small')
                Offered = (Test-UTDisplayMode -Width $w -Height $h)
            })
        }
    }
    return $out.ToArray()
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
    # Always ask for the panel's top refresh rate: a stretched mode at 60 Hz on a high-refresh monitor
    # is worse than not doing it at all, and the driver times a custom mode from whatever we ask for.
    if ($Hz -le 0) { $Hz = Get-UTMaxRefresh }
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

function Test-UTStretchedFill {
    <#
    .SYNOPSIS
        After the mode is live, says whether the picture will fill the panel or show black bars.
    .DESCRIPTION
        Reading the scaling immediately after SetDisplayConfig is unreliable (it answers identity even
        while the panel stretches), so this waits for the mode to settle and only speaks up for the two
        values that unambiguously mean bars: centred (2) and aspect-ratio-centred (4). Those come from
        the machine default for a mode nothing has saved a preference for, which is exactly the case for
        a resolution created seconds ago. The rest of the chain - the driver's own scaling mode and the
        monitor's OSD - is outside any API's reach, so the message names both.
    #>
    Start-Sleep -Milliseconds 700
    $s = 0
    try { $s = [int][UT.NativeV1.Display]::GetScaling() } catch { return }
    if ($s -ne 2 -and $s -ne 4) { return }
    Write-UTLog 'This mode is set to keep its aspect ratio, so you will see black bars.' -Level Warn
    Write-UTLog '  Fix it once in NVIDIA Control Panel > Display > Adjust desktop size and position: Scaling mode = Full-screen, Perform scaling on = GPU, and tick "Override the scaling mode set by games and programs". Some monitors also have their own aspect setting in the OSD that overrides the GPU.' -Level Warn
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
    if ($Game -eq 'Valorant' -and -not [UT.NativeV1.NvApi]::IsAvailable()) {
        throw 'The VALORANT route is NVIDIA only: it needs the driver API to create the mode, and hiding the monitor from the game is only safe when the NVIDIA driver is the one still driving the panel.'
    }
    $cur = [UT.NativeV1.Display]::GetCurrent()
    $state = [ordered]@{ Width = $cur.Width; Height = $cur.Height; Hz = $cur.Hz; Scaling = [int][UT.NativeV1.Display]::GetScaling(); Monitors = @(); Game = $Game; Started = (Get-Date).ToString('s') }
    $statePath = Get-UTStretchedStatePath
    ([pscustomobject]$state) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding ASCII
    try {
        [void](Add-UTCustomMode -Width $Width -Height $Height -Hz (Get-UTMaxRefresh))
        $hz = Get-UTBestRefresh -Width $Width -Height $Height
        Write-UTStretchedGameConfig -Game $Game -Width $Width -Height $Height
        if ($Game -eq 'Valorant') {
            foreach ($m in (Get-UTMonitorDevices | Where-Object { $_.Status -eq 'OK' })) {
                Set-UTMonitorDevice -InstanceId $m.InstanceId -Enable $false
                $state.Monitors += $m.InstanceId
                ([pscustomobject]$state) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding ASCII
            }
        }
        Set-UTDisplayMode -Width $Width -Height $Height -Hz $hz
        # Scaling is stored per mode, so a mode that has just been created carries the machine default,
        # which on most desktops is aspect-ratio-centred: that is where the black bars come from.
        try { Set-UTDisplayScaling -Scaling 3 } catch { Write-UTLog ('GPU scaling could not be set to stretched: ' + $_.Exception.Message) -Level Warn }
        Test-UTStretchedFill
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
