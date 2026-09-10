function Get-UTNeverKill {
    <#
    .SYNOPSIS
        Processes Game Ready mode never offers, whatever config/gameready.json says.
    .DESCRIPTION
        Everything Windows needs to stay on its feet, the security stack, audio, the GPU vendors'
        display containers, every anti-cheat service and helper, and this tool's own host. The list
        is code, not data, for the same reason the debloat blocklist is: a careless config edit must
        not be able to take the desktop down.
    #>
    return @(
        'System', 'Idle', 'Registry', 'Secure System', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso',
        'svchost', 'dwm', 'fontdrvhost', 'sihost', 'taskhostw', 'RuntimeBroker', 'ctfmon', 'explorer', 'ShellExperienceHost',
        'StartMenuExperienceHost', 'SearchHost', 'SearchApp', 'SearchUI', 'TextInputHost', 'ApplicationFrameHost', 'LogonUI',
        'LockApp', 'SystemSettings', 'Taskmgr', 'conhost', 'OpenConsole', 'cmd', 'powershell', 'powershell_ise', 'pwsh',
        'WindowsTerminal', 'WmiPrvSE', 'dllhost', 'unsecapp', 'dasHost', 'MemCompression', 'audiodg', 'spoolsv', 'WUDFHost',
        'SecurityHealthService', 'SecurityHealthSystray', 'MsMpEng', 'NisSrv', 'SgrmBroker', 'smartscreen',
        'NVDisplay.Container', 'nvcontainer', 'atieclxx', 'atiesrxx', 'AMDRSServ', 'AMDRSSrcExt', 'igfxEM', 'igfxHK', 'igfxTray',
        'igfxCUIService', 'IntelGraphicsSoftware', 'RtkAudUService64', 'RAVBg64', 'NahimicSvc', 'NahimicNotifSys',
        'vgc', 'vgtray', 'vgm', 'EasyAntiCheat', 'EasyAntiCheat_EOS', 'EasyAntiCheat_Setup', 'BEService', 'BEDaisy',
        'EAAntiCheatService', 'FACEITService', 'faceit', 'PnkBstrA', 'PnkBstrB', 'xigncode', 'GameGuard', 'nProtect',
        'GameBar', 'GameBarFTServer', 'gamingservices', 'gamingservicesnet', 'XboxPcAppFT'
    )
}

function Get-UTGameReadyCandidates {
    <#
    .SYNOPSIS
        Processes in this user's session that could be closed before a game, with what each one is.
    .DESCRIPTION
        Only the interactive session is considered, so services and anything owned by SYSTEM never
        appear. The never-kill list, the chosen game, its launcher family and this tool's own tree are
        removed. What remains is labelled from config/gameready.json where a name is known, or by its
        window title, and tagged Keep when gamers usually want it running (voice chat, recording,
        peripheral software), so it is listed but not ticked.
    #>
    param([string]$GameProcess = '')
    $cfg = $sync.configs.gameready
    $never = @{}
    foreach ($n in (Get-UTNeverKill)) { $never[$n] = $true }
    $keep = @{}
    foreach ($p in $cfg.Keep.PSObject.Properties) { $keep[$p.Name] = [string]$p.Value }
    $background = @{}
    foreach ($p in $cfg.Background.PSObject.Properties) { $background[$p.Name] = [string]$p.Value }
    $gameLaunchers = @{}
    if ($GameProcess) {
        $fnCfg = $sync.configs.fortnite; $vCfg = $sync.configs.valorant
        if ($GameProcess -eq $fnCfg.GameProcess) { foreach ($n in @($fnCfg.LauncherProcesses) + @($fnCfg.BlockingProcesses)) { $gameLaunchers[$n] = $true } }
        if ($GameProcess -eq $vCfg.GameProcess) { foreach ($n in @($vCfg.ClientProcesses) + @($vCfg.BlockingProcesses)) { $gameLaunchers[$n] = $true } }
    }
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $session = $me.SessionId
    $mine = @{ $me.Id = $true }
    try { $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($me.Id)" -ErrorAction Stop).ParentProcessId; if ($parent) { $mine[[int]$parent] = $true } } catch { }
    $byName = @{}
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            if ($p.SessionId -ne $session) { continue }
            $name = $p.ProcessName
            if ($never.ContainsKey($name) -or $mine.ContainsKey($p.Id) -or $gameLaunchers.ContainsKey($name)) { continue }
            if ($GameProcess -and $name -eq $GameProcess) { continue }
            if (-not $byName.ContainsKey($name)) {
                $label = $name
                if ($background.ContainsKey($name)) { $label = $background[$name] }
                elseif ($keep.ContainsKey($name)) { $label = $keep[$name] }
                $byName[$name] = [pscustomobject]@{
                    Name = $name; Pids = @(); Count = 0; Label = $label; Title = ''; HasWindow = $false; MemoryMB = 0
                    Keep = $keep.ContainsKey($name); Reason = $(if ($keep.ContainsKey($name)) { $keep[$name] } else { '' })
                }
            }
            $row = $byName[$name]
            $row.Pids += $p.Id; $row.Count++; $row.MemoryMB += [math]::Round($p.WorkingSet64 / 1MB)
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $row.HasWindow = $true; if (-not $row.Title) { try { $row.Title = $p.MainWindowTitle } catch { } } }
        } catch { }
        finally { $p.Dispose() }
    }
    foreach ($row in $byName.Values) { if ($row.Label -eq $row.Name -and $row.Title) { $row.Label = $row.Title } }
    return @($byName.Values | Sort-Object @{ Expression = 'Keep' }, @{ Expression = 'HasWindow'; Descending = $true }, @{ Expression = 'MemoryMB'; Descending = $true })
}

function Stop-UTGameReadyProcesses {
    <#
    .SYNOPSIS
        Closes every process with one of the given names: a polite window close first, then a kill for
        anything still alive after the grace period.
    .DESCRIPTION
        Names are re-checked against the never-kill list and this tool's own session before anything is
        signalled, so a stale list from the UI cannot reach a protected process. Nothing here is
        reversible; the log says exactly what was closed so it can be started again.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Names, [int]$GraceSeconds = 3)
    $never = @{}
    foreach ($n in (Get-UTNeverKill)) { $never[$n] = $true }
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $targets = @()
    foreach ($name in $Names) {
        if ($never.ContainsKey($name)) { Write-UTLog ("{0} is protected and was not touched" -f $name) -Level Warn; continue }
        $targets += @(Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $me.SessionId -and $_.Id -ne $me.Id })
    }
    if ($targets.Count -eq 0) { Write-UTLog 'Nothing to close'; return 0 }
    $freed = 0
    foreach ($p in $targets) {
        $freed += $p.WorkingSet64
        try { if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch { }
    }
    $deadline = (Get-Date).AddSeconds($GraceSeconds)
    while ((Get-Date) -lt $deadline -and @($targets | Where-Object { -not $_.HasExited }).Count -gt 0) { Start-Sleep -Milliseconds 200 }
    $closed = 0
    foreach ($p in $targets) {
        try {
            if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit(2000) }
            Write-UTLog ("closed {0} (pid {1})" -f $p.ProcessName, $p.Id)
            $closed++
        } catch { Write-UTLog ("{0} (pid {1}) could not be closed: {2}" -f $p.ProcessName, $p.Id, $_.Exception.Message) -Level Warn }
    }
    Write-UTLog ("Game Ready: {0} process(es) closed, about {1:N0} MB of working set released" -f $closed, ($freed / 1MB)) -Level Ok
    return $closed
}
