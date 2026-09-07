function Set-UTFortniteSettings {
    <#
    .SYNOPSIS
        Applies a profile from config/fortnite.json (plus optional hidden keys) to Fortnite's GameUserSettings.ini
        with a key-level merge. Refuses while the game runs, backs up first, clears and restores the read-only flag.
    #>
    param([string]$ProfileName, [string[]]$HiddenKeys = @())
    $fn = Get-UTFortnite
    if (-not $fn.GameIniExists) { throw "Fortnite's GameUserSettings.ini was not found at $($fn.GameIni). Start Fortnite once so it creates the file." }
    if ($fn.GameRunning) { throw 'Fortnite is running. Close it first, the game rewrites this file on exit.' }
    $settings = @{}
    if ($ProfileName) {
        $p = $sync.configs.fortnite.Profiles.$ProfileName
        if (-not $p) { throw "Unknown profile $ProfileName" }
        foreach ($sec in $p.Settings.PSObject.Properties) {
            $settings[$sec.Name] = @{}
            foreach ($kv in $sec.Value.PSObject.Properties) { $settings[$sec.Name][$kv.Name] = [string]$kv.Value }
        }
    }
    foreach ($hid in $HiddenKeys) {
        $h = $sync.configs.fortnite.HiddenKeys.$hid
        if (-not $h) { continue }
        if (-not $settings.ContainsKey($h.Section)) { $settings[$h.Section] = @{} }
        $settings[$h.Section][$h.Key] = [string]$h.Value
    }
    if ($settings.Count -eq 0) { Write-UTLog 'Nothing selected for Fortnite'; return }
    # Clear read-only first: a copy inherits the attribute, and a read-only backup would restore a file
    # the game can no longer write, which silently stops it saving video settings.
    $item = Get-Item -LiteralPath $fn.GameIni
    $wasReadOnly = $item.IsReadOnly
    if ($wasReadOnly) { $item.IsReadOnly = $false }
    Backup-UTFile -Path $fn.GameIni
    try {
        $n = Set-UTIniValues -Path $fn.GameIni -Settings $settings
        $label = 'hidden keys only'
        if ($ProfileName) { $label = $sync.configs.fortnite.Profiles.$ProfileName.Content }
        Write-UTLog ("Fortnite settings written: {0} ({1} key(s) changed). Start the game to see them." -f $label, $n) -Level Ok
    } finally {
        if ($wasReadOnly) { (Get-Item -LiteralPath $fn.GameIni).IsReadOnly = $true; Write-UTLog 'The file was read-only before; the flag was restored' }
    }
}

function Restore-UTFortniteSettings {
    $fn = Get-UTFortnite
    $orig = $fn.GameIni + '.unknowntweaks.original'
    if (-not (Test-Path -LiteralPath $orig)) { throw 'No original backup exists (nothing was changed by unknowntweaks yet)' }
    if ($fn.GameRunning) { throw 'Fortnite is running. Close it first.' }
    $item = Get-Item -LiteralPath $fn.GameIni -ErrorAction SilentlyContinue
    if ($item -and $item.IsReadOnly) { $item.IsReadOnly = $false }
    Copy-Item -LiteralPath $orig -Destination $fn.GameIni -Force
    (Get-Item -LiteralPath $fn.GameIni).IsReadOnly = $false
    Write-UTLog 'Fortnite GameUserSettings.ini restored from the original backup, and left writable so the game can save settings' -Level Ok
}

function Set-UTFortniteReadOnly {
    param([bool]$ReadOnly)
    $fn = Get-UTFortnite
    if (-not $fn.GameIniExists) { throw 'GameUserSettings.ini not found' }
    (Get-Item -LiteralPath $fn.GameIni).IsReadOnly = $ReadOnly
    if ($ReadOnly) { Write-UTLog 'GameUserSettings.ini is now read-only: in-game Video changes will NOT persist until you unlock it' -Level Warn }
    else { Write-UTLog 'GameUserSettings.ini is writable again' -Level Ok }
}

function Clear-UTShaderCache {
    <#
    .SYNOPSIS
        Deletes the NVIDIA / AMD DirectX shader caches. Epic's own DX12 stutter fix. Only with game and launcher closed.
    #>
    $fn = Get-UTFortnite
    if ($fn.GameRunning) { throw 'Close Fortnite first' }
    if ($fn.LauncherRunning) { throw 'Close the Epic Games Launcher too: it holds shader cache files open' }
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'NVIDIA\DXCache'), (Join-Path $env:LOCALAPPDATA 'NVIDIA\GLCache'), (Join-Path $env:ProgramData 'NVIDIA Corporation\NV_Cache'),
        (Join-Path $env:LOCALAPPDATA 'AMD\DxCache'), (Join-Path $env:LOCALAPPDATA 'AMD\DxcCache'), (Join-Path $env:LOCALAPPDATA 'AMD\GLCache'), (Join-Path $env:LOCALAPPDATA 'AMD\VkCache')
    )
    $freed = 0
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $size = (Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $freed += [int64]$size
        Write-UTLog ("Cleared {0} ({1:N0} MB)" -f $d, ($size / 1MB))
    }
    Write-UTLog ("Shader caches cleared, {0:N0} MB freed. The first match will stutter while shaders rebuild, then it settles." -f ($freed / 1MB)) -Level Ok
}
