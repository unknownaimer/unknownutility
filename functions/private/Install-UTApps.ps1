function Get-UTWinget {
    <#
    .SYNOPSIS
        Full path to winget.exe, or $null. Elevated sessions often lack the App Execution Alias on PATH.
    #>
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $alias) { return $alias }
    try {
        $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
        if ($pkg) {
            $exe = Join-Path $pkg.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    } catch { }
    # An elevated session runs under a different profile, so the per-user App Execution Alias above can be
    # missing even though winget is installed machine-wide. The package directory always has the real exe.
    try {
        $dir = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
        if ($dir) {
            $exe = Join-Path $dir.FullName 'winget.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    } catch { }
    return $null
}

function Install-UTWinget {
    <#
    .SYNOPSIS
        Best-effort winget bootstrap: re-register App Installer if present, otherwise download the current bundle.
    #>
    Write-UTLog 'winget not found, trying to install App Installer...'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
        if (Get-UTWinget) { Write-UTLog 'winget registered' -Level Ok; return $true }
    } catch { }
    try {
        $tmp = Join-Path $env:TEMP 'unknowntweaks-winget.msixbundle'
        Invoke-WebRequest -Uri 'https://aka.ms/getwinget' -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        Add-AppxPackage -Path $tmp -ErrorAction Stop
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if (Get-UTWinget) { Write-UTLog 'winget installed' -Level Ok; return $true }
    } catch {
        Write-UTLog ("winget could not be installed automatically: {0}. Install 'App Installer' from the Microsoft Store, then retry." -f $_.Exception.Message) -Level Error
    }
    return $false
}

function Install-UTApps {
    <#
    .SYNOPSIS
        Installs the selected applications.json entries with winget, silently, logging progress. Runs in a worker job.
    #>
    param([Parameter(Mandatory = $true)][string[]]$Names)
    $winget = Get-UTWinget
    if (-not $winget) { if (-not (Install-UTWinget)) { return }; $winget = Get-UTWinget }
    $ok = 0; $failed = 0
    foreach ($name in $Names) {
        $app = $sync.configs.applications.$name
        if (-not $app) { Write-UTLog "Unknown app $name" -Level Warn; continue }
        $id = [string]$app.Winget
        $sync.status = "Installing $name"
        Write-UTLog "----- winget install $id"
        try {
            $r = Invoke-UTNative -FilePath $winget -Arguments @(
                'install', '--id', $id, '--exact', '--silent',
                '--accept-source-agreements', '--accept-package-agreements',
                '--disable-interactivity', '--source', 'winget')
            $output = $r.Lines
            $code = $r.ExitCode
            foreach ($line in @($output)) {
                $text = ([string]$line).Trim()
                if (-not $text) { continue }
                # progress bars, spinners and download counters are noise in a log file
                if ($text -match '^[\\|/\-]+$') { continue }
                if ($text -match '^[\u2500-\u25FF\s\-]+$') { continue }
                if ($text -match '(KB|MB|GB)\s*/\s*[0-9.]+\s*(KB|MB|GB)') { continue }
                Write-UTLog "  $text"
            }
            if ($code -eq 0) { $ok++; Write-UTLog "$name installed" -Level Ok }
            elseif ($code -in @(-1978335189, -1978335135, -1978334963, -1978334962)) { $ok++; Write-UTLog "$name is already installed or newer" -Level Ok }
            elseif ($code -in @(-1978334967, -1978334965)) { $ok++; Write-UTLog "$name installed, but it needs a reboot to finish" -Level Ok; $sync.needReboot = $true }
            elseif ($code -eq -1978335146) { $failed++; Write-UTLog "$name refuses to install from an elevated window. Open a normal PowerShell (not as administrator) and run: winget install --id $id --exact" -Level Warn }
            elseif ($code -eq -1978335212) { $failed++; Write-UTLog "$name was not found in the winget catalogue under the id $id; it may have been renamed or removed" -Level Warn }
            else { $failed++; Write-UTLog ("{0} failed with winget exit code {1} (0x{2:X8})" -f $name, $code, $code) -Level Warn }
        } catch {
            $failed++
            Write-UTLog ("{0} failed: {1}" -f $name, $_.Exception.Message) -Level Error
        }
    }
    Write-UTLog ("Install done: {0} succeeded, {1} failed" -f $ok, $failed) -Level Ok
}
