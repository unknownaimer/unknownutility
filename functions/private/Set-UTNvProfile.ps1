function Get-UTNvProfileIds {
    <#
    .SYNOPSIS
        The setting ids and values of one preset from config/nvprofile.json, parsed from hex.
    #>
    param([Parameter(Mandatory = $true)][string]$PresetName)
    $p = $sync.configs.nvprofile.Presets.$PresetName
    if (-not $p) { throw "Unknown NVIDIA profile preset $PresetName" }
    $ids = New-Object System.Collections.Generic.List[uint32]
    $values = New-Object System.Collections.Generic.List[uint32]
    foreach ($s in @($p.Settings)) {
        $ids.Add([Convert]::ToUInt32([string]$s.Id, 16))
        $values.Add([Convert]::ToUInt32([string]$s.Value, 16))
    }
    return [pscustomobject]@{ Ids = $ids.ToArray(); Values = $values.ToArray(); Settings = @($p.Settings); Content = [string]$p.Content }
}

function Get-UTNvProfileState {
    <#
    .SYNOPSIS
        What the driver currently holds for the settings this tool writes, and how many of them already
        match the given preset. Read-only.
    .DESCRIPTION
        NVIDIA ships its own Fortnite profile with most of these already set, so "is this the driver
        default" tells the user nothing useful. What does is whether the values on disk are the ones a
        preset would write, which is how the tab reports whether a preset is live.
    #>
    param([string]$PresetName = 'Potato')
    $out = [pscustomobject]@{ Available = $false; Application = ''; Preset = $PresetName; Matching = 0; Total = 0; Lines = @() }
    if (-not ('UT.NativeV1.NvApi' -as [type])) { return $out }
    if (-not [UT.NativeV1.NvApi]::IsAvailable()) { return $out }
    $cfg = $sync.configs.nvprofile
    $out.Available = $true
    $out.Application = [string]$cfg.Application
    $names = @{}; $wanted = @{}
    foreach ($preset in $cfg.Presets.PSObject.Properties) {
        foreach ($s in @($preset.Value.Settings)) { $names[[string]$s.Id] = [string]$s.Name }
    }
    if ($cfg.Presets.$PresetName) {
        foreach ($s in @($cfg.Presets.$PresetName.Settings)) { $wanted[[string]$s.Id] = [Convert]::ToUInt32([string]$s.Value, 16) }
    }
    $ids = @($names.Keys | ForEach-Object { [Convert]::ToUInt32($_, 16) })
    $raw = [UT.NativeV1.NvApi]::DrsRead($cfg.Application, $ids)
    if (-not $raw) { return $out }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in ($raw -split ';')) {
        $parts = $entry -split ':'
        if ($parts.Count -lt 3) { continue }
        $id = [string]$parts[0]
        $value = [uint32]$parts[1]
        $name = [string]$names[$id]
        if (-not $name) { $name = $id }
        $mark = ''
        if ($wanted.ContainsKey($id)) {
            $out.Total++
            if ($wanted[$id] -eq $value) { $out.Matching++; $mark = "matches $PresetName" } else { $mark = "preset wants 0x{0:X8}" -f $wanted[$id] }
        }
        $lines.Add(('{0,-52} {1,-12} {2}' -f $name, ('0x' + $value.ToString('X8')), $mark))
    }
    $out.Lines = $lines.ToArray()
    return $out
}

function Set-UTNvProfile {
    <#
    .SYNOPSIS
        Writes a preset into the NVIDIA driver profile for Fortnite's executable.
    .DESCRIPTION
        Uses the driver's own settings repository through NVAPI - the same database NVIDIA Control
        Panel writes - so no third-party tool is downloaded or run. Only the settings named in
        config/nvprofile.json are touched, and Restore-UTNvProfile puts each of them back to the
        driver default. Nothing is injected into the game and no game file is changed.
    #>
    param([Parameter(Mandatory = $true)][string]$PresetName)
    if (-not ('UT.NativeV1.NvApi' -as [type]) -or -not [UT.NativeV1.NvApi]::IsAvailable()) {
        throw 'This PC has no NVIDIA driver, so there is no NVIDIA profile to write. AMD and Intel expose their own equivalents in their control panels.'
    }
    $cfg = $sync.configs.nvprofile
    $p = Get-UTNvProfileIds -PresetName $PresetName
    $r = [UT.NativeV1.NvApi]::DrsApply($cfg.Application, $cfg.ProfileName, $p.Ids, $p.Values)
    if ($r -ne 'ok') { throw ("the NVIDIA driver refused the profile write: {0}" -f $r) }
    foreach ($s in $p.Settings) { Write-UTLog ('  {0} -> {1}' -f $s.Name, $s.Means) }
    Write-UTLog ("NVIDIA profile for {0}: {1} ({2} setting(s)). Restart Fortnite for it to take effect." -f $cfg.Application, $p.Content, $p.Ids.Count) -Level Ok
}

function Restore-UTNvProfile {
    <#
    .SYNOPSIS
        Puts every setting this tool can write back to the driver default for Fortnite's executable.
    #>
    if (-not ('UT.NativeV1.NvApi' -as [type]) -or -not [UT.NativeV1.NvApi]::IsAvailable()) { throw 'No NVIDIA driver on this PC' }
    $cfg = $sync.configs.nvprofile
    $all = @{}
    foreach ($preset in $cfg.Presets.PSObject.Properties) {
        foreach ($s in @($preset.Value.Settings)) { $all[[string]$s.Id] = $true }
    }
    $ids = @($all.Keys | ForEach-Object { [Convert]::ToUInt32($_, 16) })
    $r = [UT.NativeV1.NvApi]::DrsRestore($cfg.Application, $ids)
    if ($r -ne 'ok') { throw ("the NVIDIA driver refused the restore: {0}" -f $r) }
    Write-UTLog ("NVIDIA profile for {0} restored to driver defaults ({1} setting(s))" -f $cfg.Application, $ids.Count) -Level Ok
}
