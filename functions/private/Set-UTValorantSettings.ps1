function Set-UTValorantSettings {
    <#
    .SYNOPSIS
        Applies a profile from config/valorant.json to the active player's GameUserSettings.ini and
        RiotUserSettings.ini as a key-level merge, with a backup of each file first.
    .DESCRIPTION
        Resolution, VSync, frame limit and letterboxing are Unreal settings and live in
        GameUserSettings.ini; the quality groups the Video menu shows are Riot's own keys in
        RiotUserSettings.ini. Both are per-player user settings written by the game itself on exit,
        so this refuses while the game runs; the Riot client in the tray does not touch them.
    #>
    param([Parameter(Mandatory = $true)][string]$ProfileName)
    $v = Get-UTValorant
    $cfg = $sync.configs.valorant
    $p = $cfg.Profiles.$ProfileName
    if (-not $p) { throw "Unknown profile $ProfileName" }
    if (-not $v.PlayerId) { throw 'No VALORANT player settings were found on this PC. Start the game once so it creates them.' }
    if ($v.GameRunning) { throw 'VALORANT is running. Close it first; the game rewrites these files on exit.' }
    $changed = 0
    if ($v.GameIniExists -and $p.Game) {
        $settings = @{ $cfg.GameSection = @{} }
        foreach ($kv in $p.Game.PSObject.Properties) { $settings[$cfg.GameSection][$kv.Name] = [string]$kv.Value }
        Backup-UTFile -Path $v.GameIni
        $changed += Set-UTIniValues -Path $v.GameIni -Settings $settings
    }
    if ($v.RiotIniExists -and $p.Riot) {
        $settings = @{ $cfg.RiotSection = @{} }
        foreach ($kv in $p.Riot.PSObject.Properties) { $settings[$cfg.RiotSection][$kv.Name] = [string]$kv.Value }
        Backup-UTFile -Path $v.RiotIni
        $changed += Set-UTIniValues -Path $v.RiotIni -Settings $settings
    }
    Write-UTLog ("VALORANT settings written for player {0}: {1} ({2} key(s) changed)" -f $v.PlayerId.Substring(0, 8), $p.Content, $changed) -Level Ok
}

function Restore-UTValorantSettings {
    $v = Get-UTValorant
    if ($v.GameRunning) { throw 'Close VALORANT first' }
    $n = 0
    foreach ($f in @($v.GameIni, $v.RiotIni)) {
        $orig = $f + '.unknowntweaks.original'
        if (-not (Test-Path -LiteralPath $orig)) { continue }
        Copy-Item -LiteralPath $orig -Destination $f -Force
        $n++
    }
    if ($n -eq 0) { throw 'No backup found: nothing was written by this tool yet' }
    Write-UTLog ("{0} VALORANT settings file(s) restored from the first backup" -f $n) -Level Ok
}
