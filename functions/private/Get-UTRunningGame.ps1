function Get-UTRunningGame {
    <#
    .SYNOPSIS
        The game process running right now, whether or not it owns the foreground window.
    .DESCRIPTION
        Two passes over the process list: a name match against config/games.json first, then any
        windowed process whose executable lives under a game library folder (Steam, Epic, Riot, ...),
        titled by the folder it sits in. Launchers and helpers are excluded by name. A known name wins
        over a path match, and the largest working set wins among several candidates.
    #>
    $cfg = $sync.configs.games
    $known = @{}
    foreach ($p in $cfg.KnownGames.PSObject.Properties) { $known[$p.Name] = [string]$p.Value }
    $launchers = @{}
    foreach ($n in @($cfg.LauncherProcesses)) { $launchers[$n] = $true }
    $libraries = @($cfg.LibraryFolders)
    $best = $null
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $name = $p.ProcessName
            if ($launchers.ContainsKey($name)) { continue }
            $hit = $null
            if ($known.ContainsKey($name)) {
                $hit = [pscustomobject]@{ Name = $name; Pid = $p.Id; Title = $known[$name]; Source = 'known'; WorkingSet = [int64]$p.WorkingSet64; Rank = 2 }
            } elseif ($p.WorkingSet64 -gt 200MB -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
                $path = $p.MainModule.FileName.Replace('\', '/')
                foreach ($lib in $libraries) {
                    $i = $path.IndexOf($lib, [StringComparison]::OrdinalIgnoreCase)
                    if ($i -lt 0) { continue }
                    $rest = $path.Substring($i + $lib.Length)
                    $title = ($rest -split '/')[0]
                    if (-not $title) { $title = $name }
                    $hit = [pscustomobject]@{ Name = $name; Pid = $p.Id; Title = $title; Source = 'library'; WorkingSet = [int64]$p.WorkingSet64; Rank = 1 }
                    break
                }
            }
            if ($hit -and (-not $best -or $hit.Rank -gt $best.Rank -or ($hit.Rank -eq $best.Rank -and $hit.WorkingSet -gt $best.WorkingSet))) { $best = $hit }
        } catch { }
        finally { $p.Dispose() }
    }
    return $best
}
