function Find-UTLaunchArgsKey {
    <#
    .SYNOPSIS
        Locates the Epic launcher's per-game "Additional Command Line Arguments" entry for Fortnite in its settings file.
    .DESCRIPTION
        Read off a live Epic Games Launcher 20.2.6 install (see docs/DECISIONS.md), the layout in
        %LOCALAPPDATA%\EpicGamesLauncher\Saved\Config\WindowsEditor\GameUserSettings.ini is:

            [<AccountId>_Settings]
            fn:<CatalogItemId>:Fortnite_AdditionalCommandsEnabled=True
            fn:<CatalogItemId>:Fortnite_AdditionalCommands=-NOSPLASH

        The section is the signed-in Epic account id; the key is the catalog triple the launcher uses
        everywhere else (NamespaceId:ItemId:ArtifactId, i.e. Get-UTFortnite's LauncherKeyPrefix)
        suffixed with _AdditionalCommands, and the tick box next to the text field is the same key
        plus "Enabled".

        Order of preference: (1) a location learned earlier by the probe (saved state), (2) this
        game's *_AdditionalCommands key already present in the file, (3) the layout above.
        Source is 'unknown' when neither the account id nor the catalog triple could be determined;
        callers must refuse to write in that case rather than invent a section.
    #>
    param([Parameter(Mandatory = $true)]$Fortnite)
    $res = [pscustomobject]@{ Section = ''; Key = ''; Source = 'known'; Current = $null; Enabled = $null; File = $Fortnite.LauncherIni; EnableKey = '' }
    # If the probe learned the real location on this machine, that file wins over the newest-timestamp guess.
    $learnedFile = Get-UTScriptState -Id UTLaunchArgs -Key File
    if ($learnedFile -and (Test-Path -LiteralPath $learnedFile)) { $res.File = $learnedFile }
    $ini = $null
    if (Test-Path -LiteralPath $res.File) { $ini = Read-UTIniFile -Path $res.File }
    $learnedSection = Get-UTScriptState -Id UTLaunchArgs -Key Section
    $learnedKey = Get-UTScriptState -Id UTLaunchArgs -Key Key
    $wanted = ''
    if ($Fortnite.LauncherKeyPrefix) { $wanted = $Fortnite.LauncherKeyPrefix + '_AdditionalCommands' }
    if ($learnedSection -and $learnedKey) {
        $res.Section = $learnedSection; $res.Key = $learnedKey; $res.Source = 'probe'
    } elseif ($ini) {
        # What the launcher has already written on this machine beats any name we construct.
        foreach ($s in $ini.Sections.Keys) {
            foreach ($k in $ini.Sections[$s].Keys) {
                if ($k -notlike '*_AdditionalCommands') { continue }
                # Every other Epic game has its own key in the same section, so match this game only.
                if ($wanted) { if ($k -ne $wanted) { continue } } elseif ($k -notmatch 'Fortnite') { continue }
                $res.Section = $s; $res.Key = $k; $res.Source = 'existing'; break
            }
            if ($res.Source -eq 'existing') { break }
        }
    }
    if (-not $res.Key) { $res.Key = $wanted }
    if (-not $res.Section -and $Fortnite.AccountId) { $res.Section = $Fortnite.AccountId + '_Settings' }
    if (-not $res.Key -or -not $res.Section) { $res.Source = 'unknown'; return $res }

    if ($res.Source -eq 'probe') {
        $learnedEnable = Get-UTScriptState -Id UTLaunchArgs -Key EnableKey
        if ($learnedEnable) { $res.EnableKey = $learnedEnable }
    }
    if (-not $res.EnableKey) { $res.EnableKey = $res.Key + 'Enabled' }
    if ($ini -and $ini.Sections.ContainsKey($res.Section)) {
        foreach ($k in $ini.Sections[$res.Section].Keys) {
            if ($k -eq $res.Key) { $res.Current = $ini.Sections[$res.Section][$k] }
            if ($k -eq $res.EnableKey) { $res.Enabled = $ini.Sections[$res.Section][$k] }
        }
    }
    return $res
}

function Set-UTLaunchArgs {
    <#
    .SYNOPSIS
        Writes Fortnite's launch arguments into the Epic Games Launcher settings file, closing the launcher first
        (it overwrites the file on exit) and restarting it afterwards if it was running.
    #>
    param([string]$Arguments = '')
    $fn = Get-UTFortnite
    if ($fn.GameRunning) { throw 'Fortnite is running. Close it first.' }
    $loc = Find-UTLaunchArgsKey -Fortnite $fn
    if ($loc.Source -eq 'unknown') {
        throw 'The launcher entry for Fortnite could not be identified: neither your Epic account id nor the game''s catalog id could be read. Sign in to the Epic Games Launcher once and open it, then try again, or use "Probe launcher key".'
    }
    $wasRunning = Stop-UTEpicLauncher
    try {
        if (Test-Path -LiteralPath $loc.File) { Backup-UTFile -Path $loc.File }
        else {
            $dir = Split-Path -Path $loc.File -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        }
        # The text box and its tick box are separate keys: writing arguments without enabling them means
        # the launcher ignores them entirely.
        $pairs = @{ $loc.Key = $Arguments; $loc.EnableKey = $(if ($Arguments) { 'True' } else { 'False' }) }
        $settings = @{ $loc.Section = $pairs }
        $n = Set-UTIniValues -Path $loc.File -Settings $settings
        Save-UTScriptState -Id UTLaunchArgs -Key LastWritten -Value $Arguments -Force
        Write-UTLog ("Launch arguments written to [{0}] {1} = '{2}' ({3}, {4} change(s)) in {5}" -f $loc.Section, $loc.Key, $Arguments, $loc.Source, $n, $loc.File) -Level Ok
        Write-UTLog 'Check it in the launcher: profile icon > Settings > Manage Games > Fortnite. If Additional Command Line Arguments is empty or unticked, your launcher build stores this somewhere else: run "Probe launcher key" once and this tool will learn the real location.'
    } finally {
        if ($wasRunning) { Start-UTEpicLauncher }
    }
}
function Start-UTLaunchArgsProbe {
    <#
    .SYNOPSIS
        Step 1 of the probe: snapshot the launcher settings file so step 2 can diff it after the user types a marker.
    #>
    $fn = Get-UTFortnite
    if (-not $fn.LauncherIniExists) { throw "Launcher settings file not found at $($fn.LauncherIni). Open the launcher once, then retry." }
    $snap = Join-Path $sync.backupDir 'launcher-probe-before.ini'
    Copy-Item -LiteralPath $fn.LauncherIni -Destination $snap -Force
    Save-UTScriptState -Id UTLaunchArgs -Key ProbeFile -Value $fn.LauncherIni
    Write-UTLog 'Probe armed. Now in the Epic Games Launcher: profile icon > Settings > Manage Games > Fortnite > tick Additional Command Line Arguments and type exactly  -UTPROBE12345  then fully EXIT the launcher (tray icon > Exit). Then click Finish probe.' -Level Warn
}

function Complete-UTLaunchArgsProbe {
    <#
    .SYNOPSIS
        Step 2: find which section/key now contains the marker and remember it for future writes.
    #>
    $fn = Get-UTFortnite
    $candidates = @()
    $cfg = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved\Config'
    foreach ($f in (Get-ChildItem -LiteralPath $cfg -Recurse -Filter *.ini -ErrorAction SilentlyContinue)) { $candidates += $f.FullName }
    $hit = $null
    foreach ($file in $candidates) {
        $ini = Read-UTIniFile -Path $file
        foreach ($s in $ini.Sections.Keys) {
            foreach ($k in $ini.Sections[$s].Keys) {
                if ($ini.Sections[$s][$k] -match 'UTPROBE12345') { $hit = [pscustomobject]@{ File = $file; Section = $s; Key = $k; Others = @($ini.Sections[$s].Keys) } }
            }
        }
    }
    if (-not $hit) {
        Write-UTLog 'Marker not found in any launcher INI. Either the launcher is still running (exit it completely), the checkbox was not ticked, or the launcher stores this setting elsewhere (a web-cache store). Check the log folder of this tool for details.' -Level Warn
        return
    }
    Save-UTScriptState -Id UTLaunchArgs -Key Section -Value $hit.Section -Force
    Save-UTScriptState -Id UTLaunchArgs -Key Key -Value $hit.Key -Force
    Save-UTScriptState -Id UTLaunchArgs -Key File -Value $hit.File -Force
    # The boolean the launcher writes for the tick box lives in the same section.
    $enableKey = @($hit.Others | Where-Object { $_ -ne $hit.Key -and $_ -match 'CommandLine|Additional' -and $_ -match 'Enable|Use|Custom|^b' }) | Select-Object -First 1
    if ($enableKey) { Save-UTScriptState -Id UTLaunchArgs -Key EnableKey -Value $enableKey -Force; Write-UTLog "Its tick box key is $enableKey" -Level Ok }
    Write-UTLog ("Learned: launcher stores Fortnite launch arguments in {0} under [{1}] {2}. Other keys in that section: {3}" -f $hit.File, $hit.Section, $hit.Key, ($hit.Others -join ', ')) -Level Ok
    Write-UTLog 'Please report this section/key on the project page so it can be hard-coded for everyone.' -Level Ok
}
