function Get-UTFortnite {
    <#
    .SYNOPSIS
        Everything the Fortnite tab needs: install path, config file, the launcher's settings file, account id,
        the launcher's catalog triple for this game, running state.
    #>
    $fn = [pscustomobject]@{
        Installed = $false; InstallLocation = ''; Version = ''
        GameIni = (Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini')
        GameIniExists = $false
        LauncherIni = ''; LauncherIniExists = $false; LauncherExe = ''
        NamespaceId = ''; ItemId = ''; ArtifactId = ''; LauncherKeyPrefix = ''
        AccountId = ''; GameRunning = $false; LauncherRunning = $false
    }
    try {
        $dat = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
        if (Test-Path -LiteralPath $dat) {
            $list = (Get-Content -LiteralPath $dat -Raw | ConvertFrom-Json).InstallationList
            $entry = @($list | Where-Object { $_.AppName -eq 'Fortnite' -or $_.ArtifactId -eq 'Fortnite' }) | Select-Object -First 1
            if ($entry) {
                $fn.Installed = $true; $fn.InstallLocation = [string]$entry.InstallLocation; $fn.Version = [string]$entry.AppVersion
                $fn.NamespaceId = [string]$entry.NamespaceId; $fn.ItemId = [string]$entry.ItemId; $fn.ArtifactId = [string]$entry.ArtifactId
            }
        }
        # The manifest carries the same catalog triple under different names. It is the fallback both
        # when LauncherInstalled.dat is missing and when it is an older build without those fields.
        if (-not $fn.Installed -or -not $fn.ItemId) {
            $appData = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Epic Games\EpicGamesLauncher' -ErrorAction SilentlyContinue).AppDataPath
            if (-not $appData) { $appData = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\' }
            $manifests = Join-Path $appData 'Manifests'
            if (Test-Path -LiteralPath $manifests) {
                foreach ($f in (Get-ChildItem -LiteralPath $manifests -Filter *.item -ErrorAction SilentlyContinue)) {
                    try { $m = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
                    if ($m.AppName -ne 'Fortnite') { continue }
                    if (-not $fn.Installed) { $fn.Installed = $true; $fn.InstallLocation = [string]$m.InstallLocation; $fn.Version = [string]$m.AppVersionString }
                    if (-not $fn.NamespaceId) { $fn.NamespaceId = [string]$m.CatalogNamespace }
                    if (-not $fn.ItemId)      { $fn.ItemId      = [string]$m.CatalogItemId }
                    if (-not $fn.ArtifactId)  { $fn.ArtifactId  = [string]$m.AppName }
                    break
                }
            }
        }
    } catch { }
    # The launcher keys every per-game setting by "namespace:catalogItemId:artifact", the same triple
    # its own com.epicgames.launcher:// URLs use. See Find-UTLaunchArgsKey.
    if ($fn.NamespaceId -and $fn.ItemId -and $fn.ArtifactId) {
        $fn.LauncherKeyPrefix = '{0}:{1}:{2}' -f $fn.NamespaceId, $fn.ItemId, $fn.ArtifactId
    }
    $fn.GameIniExists = (Test-Path -LiteralPath $fn.GameIni)
    $cfg = Join-Path $env:LOCALAPPDATA 'EpicGamesLauncher\Saved\Config'
    $candidates = @((Join-Path $cfg 'WindowsEditor\GameUserSettings.ini'), (Join-Path $cfg 'Windows\GameUserSettings.ini')) | Where-Object { Test-Path -LiteralPath $_ }
    if ($candidates) {
        $fn.LauncherIni = [string](@($candidates | Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending)[0])
        $fn.LauncherIniExists = $true
    } else {
        $fn.LauncherIni = Join-Path $cfg 'Windows\GameUserSettings.ini'
    }
    foreach ($exe in @("${env:ProgramFiles(x86)}\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe", "${env:ProgramFiles(x86)}\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe")) {
        if (Test-Path -LiteralPath $exe) { $fn.LauncherExe = $exe; break }
    }
    try { $fn.AccountId = [string](Get-ItemProperty -LiteralPath 'HKCU:\Software\Epic Games\Unreal Engine\Identifiers' -Name AccountId -ErrorAction SilentlyContinue).AccountId } catch { }
    if (-not $fn.AccountId -and $fn.LauncherIniExists) {
        try {
            $ini = Read-UTIniFile -Path $fn.LauncherIni
            # _Settings holds the launch arguments, _General is the other account-scoped section; both carry the id.
            foreach ($s in $ini.Sections.Keys) { if ($s -match '^([0-9a-fA-F]{32})_(Settings|General)$') { $fn.AccountId = $Matches[1]; break } }
        } catch { }
    }
    $fn.GameRunning = [bool](Get-Process -Name @($sync.configs.fortnite.BlockingProcesses) -ErrorAction SilentlyContinue)
    $fn.LauncherRunning = [bool](Get-Process -Name @($sync.configs.fortnite.LauncherProcesses) -ErrorAction SilentlyContinue)
    return $fn
}

function Stop-UTEpicLauncher {
    <#
    .SYNOPSIS
        Closes the launcher so it cannot overwrite its settings file. Returns $true only when the main
        launcher window was actually running, so the caller knows whether to start it again afterwards.
    #>
    $names = @($sync.configs.fortnite.LauncherProcesses)
    # Only the main process means "the user had the launcher open"; the EOS helper can linger by itself.
    $wasOpen = [bool](Get-Process -Name 'EpicGamesLauncher' -ErrorAction SilentlyContinue)
    $running = Get-Process -Name $names -ErrorAction SilentlyContinue
    if (-not $running) { return $false }
    Write-UTLog 'Closing the Epic Games Launcher (it rewrites its settings file on exit)'
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Get-Process -Name $names -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
    if (Get-Process -Name $names -ErrorAction SilentlyContinue) {
        throw 'The Epic Games Launcher is still running after 15 seconds. Close it yourself (tray icon, Exit) and try again, otherwise it would overwrite the change on exit.'
    }
    Start-Sleep -Milliseconds 800
    return $wasOpen
}

function Start-UTEpicLauncher {
    <#
    .SYNOPSIS
        Asks the shell to start the launcher so it runs as the signed-in user.
    .NOTES
        Starting it directly would hand it this tool's administrator token, and every game launched from
        it afterwards would inherit that too. explorer.exe runs unelevated, so it starts the launcher
        with normal rights.
    #>
    $fn = Get-UTFortnite
    if (-not $fn.LauncherExe) { Write-UTLog 'Epic Games Launcher executable not found; start it yourself' -Level Warn; return }
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $fn.LauncherExe + '"') -ErrorAction Stop
        Write-UTLog 'Epic Games Launcher restarted (with normal user rights, not as administrator)'
    } catch {
        Write-UTLog ('Could not restart the Epic Games Launcher: {0}. Start it yourself.' -f $_.Exception.Message) -Level Warn
    }
}

function Backup-UTFile {
    <#
    .SYNOPSIS
        Copies a file next to itself with a timestamp; the very first backup is also kept as *.unknowntweaks.original.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $orig = $Path + '.unknowntweaks.original'
    if (-not (Test-Path -LiteralPath $orig)) { Copy-Item -LiteralPath $Path -Destination $orig -Force }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $Path -Destination ($Path + '.bak-' + $stamp) -Force
    Write-UTLog "Backup written: $Path.bak-$stamp"
    # Keep the newest few; this writes into the game's own config folder, not ours.
    $leaf = Split-Path -Path $Path -Leaf
    $dir = Split-Path -Path $Path -Parent
    $old = @(Get-ChildItem -LiteralPath $dir -Filter ($leaf + '.bak-*') -File -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -Skip 5)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
}
