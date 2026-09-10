function Get-UTValorant {
    <#
    .SYNOPSIS
        Install path, Riot client, the active player's two settings files, Vanguard and running state.
    .DESCRIPTION
        The Riot client records every product it manages in %ProgramData%\Riot Games\RiotClientInstalls.json;
        the VALORANT entry is the key of associated_client that contains "VALORANT". Per-player settings
        live under %LOCALAPPDATA%\VALORANT\Saved\Config\<player>\ and the most recently written player
        folder is the one that last played on this machine.
    #>
    $cfg = $sync.configs.valorant
    $v = [pscustomobject]@{
        Installed = $false; InstallLocation = ''; GameExe = ''; ClientExe = ''
        PlayerId = ''; GameIni = ''; RiotIni = ''; GameIniExists = $false; RiotIniExists = $false
        VanguardInstalled = $false; VanguardRunning = $false
        GameRunning = $false; ClientRunning = $false
    }
    try {
        $installs = Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json'
        if (Test-Path -LiteralPath $installs) {
            $j = Get-Content -LiteralPath $installs -Raw | ConvertFrom-Json
            foreach ($p in $j.associated_client.PSObject.Properties) {
                if ($p.Name -notmatch 'VALORANT') { continue }
                $v.InstallLocation = ($p.Name -replace '/', '\').TrimEnd('\')
                $v.ClientExe = ([string]$p.Value) -replace '/', '\'
                break
            }
            if (-not $v.ClientExe -and $j.rc_live) { $v.ClientExe = ([string]$j.rc_live) -replace '/', '\' }
        }
        if ($v.InstallLocation) {
            $v.GameExe = Join-Path $v.InstallLocation 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe'
            $v.Installed = Test-Path -LiteralPath $v.GameExe
        }
    } catch { }
    try {
        $root = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
        $player = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop |
                  Where-Object { $_.Name -match '^[0-9a-f-]{36,}' } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($player) {
            $v.PlayerId = $player.Name
            $v.GameIni = Join-Path $player.FullName 'WindowsClient\GameUserSettings.ini'
            $v.RiotIni = Join-Path $player.FullName 'Windows\RiotUserSettings.ini'
            $v.GameIniExists = Test-Path -LiteralPath $v.GameIni
            $v.RiotIniExists = Test-Path -LiteralPath $v.RiotIni
        }
    } catch { }
    $vg = Get-Service -Name vgc -ErrorAction SilentlyContinue
    if ($vg) { $v.VanguardInstalled = $true; $v.VanguardRunning = ($vg.Status -eq 'Running') }
    $v.GameRunning = [bool](Get-Process -Name @($cfg.BlockingProcesses) -ErrorAction SilentlyContinue)
    $v.ClientRunning = [bool](Get-Process -Name @($cfg.ClientProcesses) -ErrorAction SilentlyContinue)
    return $v
}

function Start-UTValorant {
    $v = Get-UTValorant
    if (-not $v.ClientExe -or -not (Test-Path -LiteralPath $v.ClientExe)) { throw 'The Riot client was not found on this PC' }
    Start-Process -FilePath $v.ClientExe -ArgumentList $sync.configs.valorant.LaunchArguments | Out-Null
    Write-UTLog 'VALORANT launch requested through the Riot client'
}
