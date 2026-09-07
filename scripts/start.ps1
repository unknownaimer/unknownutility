# ---------------------------------------------------------------------------------------------
# unknowntweaks entry point. Everything above this block (functions, configs, XAML) is compiled in.
# Runs on Windows PowerShell 5.1 as administrator, single-threaded apartment, FullLanguage mode.
# ---------------------------------------------------------------------------------------------

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'unknowntweaks cannot run here: PowerShell is in a restricted language mode (AppLocker / WDAC).' -ForegroundColor Red
    return
}

$UTPowerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$UTFromFile = -not [string]::IsNullOrEmpty($PSCommandPath)
if ($UTFromFile) {
    $UTRelaunchCommand = "& '" + ($PSCommandPath -replace "'", "''") + "'"
} elseif ($sync.url -match 'YOUR-ANON-ACCOUNT') {
    # This build was never given a real download URL. Re-downloading from a placeholder address and
    # running the result as administrator is exactly how a supply-chain attack would work, so don't.
    Write-Host 'This build of unknowntweaks was compiled without a real download URL, so it cannot relaunch itself.' -ForegroundColor Red
    Write-Host 'Either run it from an elevated Windows PowerShell window, or rebuild it with: .\Compile.ps1 -Owner <your-github-account>' -ForegroundColor Yellow
    return
} else {
    $UTRelaunchCommand = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm '" + $sync.url + "' | iex"
}
$UTEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($UTRelaunchCommand))

$UTIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$UTIsDesktop51 = ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5)
$UTIsSta = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')

if (-not $UTIsAdmin -or -not $UTIsDesktop51 -or -not $UTIsSta) {
    if (-not $UTIsAdmin) { Write-Host 'unknowntweaks needs administrator rights. Asking for elevation...' -ForegroundColor Yellow }
    elseif (-not $UTIsDesktop51) { Write-Host 'Relaunching in Windows PowerShell 5.1 (needed for the interface and restore points)...' -ForegroundColor Yellow }
    else { Write-Host 'Relaunching in a single-threaded apartment (needed for the interface)...' -ForegroundColor Yellow }
    try {
        $UTArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-EncodedCommand', $UTEncoded)
        if ($UTIsAdmin) { Start-Process -FilePath $UTPowerShell51 -ArgumentList $UTArgs -ErrorAction Stop }
        else { Start-Process -FilePath $UTPowerShell51 -ArgumentList $UTArgs -Verb RunAs -ErrorAction Stop }
    } catch {
        Write-Host ('Could not relaunch: ' + $_.Exception.Message) -ForegroundColor Red
    }
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Continue'

# ---- private beta gate ---------------------------------------------------------------------
# A beta build asks the gate once, here, in the final elevated process, and stops if the key was
# revoked or the beta was closed. Public builds carry no status URL and skip this entirely.
if ($sync.statusUrl) {
    $UTGate = Test-UTBetaGate -StatusUrl $sync.statusUrl -Version $sync.version
    if (-not $UTGate.Ok) {
        Write-Host ('This private beta build is not active ({0}). Ask in the Discord for a current one-liner.' -f $UTGate.Reason) -ForegroundColor Red
        Start-Sleep -Seconds 8
        return
    }
}

# ---- shared state --------------------------------------------------------------------------
$sync.dir       = Join-Path $env:ProgramData 'unknowntweaks'
$sync.backupDir = Join-Path $sync.dir 'backup'
$sync.logDir    = Join-Path $env:LOCALAPPDATA 'unknowntweaks\logs'
foreach ($d in @($sync.dir, $sync.backupDir, $sync.logDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$sync.logPath   = Join-Path $sync.logDir ('unknowntweaks_{0:yyyy-MM-dd_HH-mm-ss}.log' -f (Get-Date))
$sync.log       = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.jobDone   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.jobs      = New-Object System.Collections.ArrayList
$sync.metrics   = [hashtable]::Synchronized(@{ Snapshot = $null })
$sync.busy      = $false
$sync.closing   = $false
$sync.needReboot = $false
$sync.status    = 'ready'
$sync.graphs    = @{}
$sync.tweakBoxes = @{}
$sync.appBoxes  = @{}
$sync.startupBoxes = @{}
$sync.debloatBoxes = @{}
$sync.fnHiddenBoxes = @{}
$sync.fnArgBoxes = @{}
$sync.fnArgExcludes = @{}
$sync.fnArgOrder = @()
$sync.lastTick  = 0
$sync.consoleLines = 0
$sync.tweakStates = @{}
$sync.regions   = $null
$sync.bestRegion = 'not measured yet'
$sync.dnsResults = $null
$sync.form      = $null

Write-UTLog ('unknowntweaks {0} starting (PowerShell {1}, {2})' -f $sync.version, $PSVersionTable.PSVersion, $(if ($UTFromFile) { 'from file' } else { 'from the one-liner' }))
Write-UTLog ('log file: ' + $sync.logPath)

# ---- native helpers, DPI, WPF ---------------------------------------------------------------
$UTNative = Initialize-UTNative
# powershell.exe already declares DPI awareness in its manifest, so this normally returns
# E_ACCESSDENIED and is a no-op; ask only for what WPF on .NET Framework can honour anyway.
if ($UTNative) { try { [void][UT.NativeV1.Dwm]::SetProcessDpiAwareness(1) } catch { } }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# The boot screen covers the seconds it takes to collect system info and build the window. It is
# cosmetic only: if it cannot be shown, $UTSplash is $null and everything below runs the same.
$UTSplash = Show-UTSplash -Beta:([bool]$sync.beta)

Write-UTLog 'collecting system information...'
$sync.sysinfo = Get-UTSystemInfo

# ---- window ---------------------------------------------------------------------------------
[xml]$UTXaml = $inputXML
$UTReader = New-Object System.Xml.XmlNodeReader $UTXaml
try {
    $sync.form = [Windows.Markup.XamlReader]::Load($UTReader)
} catch {
    $ex = $_.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    Write-Host ('The interface could not be built: ' + $ex.Message) -ForegroundColor Red
    Close-UTSplash -Window $UTSplash -MinimumMs 0
    return
}
# $sync is case-insensitive and already holds shared state, so a control named e.g. "status" would
# silently overwrite it. Fail loudly instead of corrupting state at runtime.
$UTXaml.SelectNodes('//*[@Name]') | ForEach-Object {
    $n = $_.Name
    if ($sync.ContainsKey($n)) { throw "The XAML element Name='$n' collides with an internal state key; rename it." }
    $sync[$n] = $sync.form.FindName($n)
}

if ($UTNative) {
    $sync.form.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $this).Handle
            $on = 1
            if ([UT.NativeV1.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4) -ne 0) { [void][UT.NativeV1.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4) }
            if ([Environment]::OSVersion.Version.Build -ge 22000) {
                # COLORREF is 0x00BBGGRR, so the bytes are the reverse of an HTML colour.
                $cap = 0x001E1E1E   # #1E1E1E is neutral grey, identical either way
                [void][UT.NativeV1.Dwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$cap, 4)
                $bdr = 0x00423E3E   # #3E3E42
                [void][UT.NativeV1.Dwm]::DwmSetWindowAttribute($hwnd, 34, [ref]$bdr, 4)
            }
        } catch { }
    })
}

Initialize-UTUI
Start-UTMonitor
Start-UTUITimer

$sync.form.Add_Loaded({
    try {
        foreach ($g in $sync.graphs.Values) { Update-UTGraph -Graph $g }
        Write-UTLog ('ready. {0} | {1} | {2} GB RAM | {3}' -f $sync.sysinfo.CPU, $sync.sysinfo.GPU, $sync.sysinfo.RamGB, $sync.sysinfo.OSName) -Level Ok
        Write-UTLog 'Everything applied here is recorded first and can be undone from the same list. No warranty: hover a tweak before ticking it.' -Level Warn
        # -Background: this runs unasked at startup, so it must not grey out every button for 15 seconds.
        [void](Start-UTUIJob -Kind 'regions' -Background -Script 'Start-Sleep -Milliseconds 1500; Measure-UTRegionPing | Out-Null')
    } catch { Write-UTLog ('startup: ' + $_.Exception.Message) -Level Error }
})
$sync.form.Add_Closing({
    param($closingSender, $closingArgs)
    try {
        if ($sync.busy) {
            $r = [System.Windows.MessageBox]::Show('A task is still running. Close anyway?', 'unknowntweaks', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($r -ne [System.Windows.MessageBoxResult]::Yes) { $closingArgs.Cancel = $true; return }
        }
        $sync.closing = $true
        if ($sync.timer) { $sync.timer.Stop() }
    } catch { }
})

Close-UTSplash -Window $UTSplash
[void]$sync.form.ShowDialog()

# ---- shutdown -------------------------------------------------------------------------------
$sync.closing = $true
try { if ($sync.timer) { $sync.timer.Stop() } } catch { }
Stop-UTMonitor
Stop-UTJobs
Write-UTLog 'closed'
