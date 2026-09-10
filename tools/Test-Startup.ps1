<#
.SYNOPSIS
    Starts unknowntweaks for real - window, controls, monitor, UI timer, worker jobs - without
    showing it and without changing a single Windows setting, then asserts that it came up right.
.DESCRIPTION
    Test-Syntax.ps1 proves the sources parse and Test-Logic.ps1 proves the platform-independent
    logic is correct. Neither can tell you the window actually builds: a renamed control, a style
    key that no longer resolves, a XAML element the code reaches for but the parser dropped, or a
    monitor that dies on its first tick all still ship green today.

    This does the same work scripts/start.ps1 does, in the same order, except that it:
      - redirects the log and backup directories into a temp folder,
      - never calls ShowDialog (the dispatcher is pumped for -Seconds instead, or -Show opens the
        real window and closes it again),
      - only reads: no registry write, no service, no power, no network configuration.

    Windows and an STA host are required. Windows PowerShell 5.1 is the runtime the tool ships on,
    so prefer it; PowerShell 7 on Windows also works.
.PARAMETER Seconds
    How long to pump the dispatcher. Needs to be >= 4 for the monitor to publish a snapshot: its
    first sample is deliberately discarded, so the first usable one lands on tick 2.
.PARAMETER Show
    Show the window off-screen instead of laying it out headlessly, then close it. Slower, but it
    is the only way to exercise the real render path.
.PARAMETER SkipNetwork
    Skip the assertions that need a working internet connection.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Startup.ps1
#>
[CmdletBinding()]
param(
    [string]$Root,
    [int]$Seconds = 8,
    [switch]$Show,
    [switch]$SkipNetwork
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside a param() default on an advanced script.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

$script:pass = 0; $script:fail = 0; $script:skip = 0
function Assert([bool]$cond, [string]$what) {
    if ($cond) { $script:pass++; Write-Host "  ok    $what" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}
function Skip([string]$what) { $script:skip++; Write-Host "  skip  $what" -ForegroundColor DarkGray }

# ---- host requirements ------------------------------------------------------------------------
if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Host 'Test-Startup needs Windows. Skipping.' -ForegroundColor Yellow
    exit 0
}
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Test-Startup needs a single-threaded apartment. Run it with: powershell -STA -File .\tools\Test-Startup.ps1' -ForegroundColor Red
    exit 1
}

Write-Host ("host: PowerShell {0} ({1}), STA, elevated={2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition,
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

# ---- the same shared state scripts/start.ps1 builds, pointed at a temp folder -------------------
$sync = [Hashtable]::Synchronized(@{})
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('ut-startup-' + [guid]::NewGuid().ToString('N'))
$sync.version   = 'startup-test'
$sync.url       = 'https://example.invalid/unknowntweaks.ps1'
$sync.repo      = 'https://example.invalid/unknowntweaks'
$sync.beta      = $false
$sync.statusUrl = ''
$sync.betaTester = ''
$sync.configs   = @{}
$sync.dir       = $sandbox
$sync.backupDir = Join-Path $sandbox 'backup'
$sync.logDir    = Join-Path $sandbox 'logs'
foreach ($d in @($sync.dir, $sync.backupDir, $sync.logDir)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
$sync.logPath   = Join-Path $sync.logDir 'startup-test.log'
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

try {
    # ---- sources ------------------------------------------------------------------------------
    Write-Host 'loading sources'
    $functionFiles = @(Get-ChildItem -Path (Join-Path $Root 'functions') -Recurse -Filter *.ps1 -File |
        Sort-Object { $_.DirectoryName -notmatch 'private' }, FullName)
    foreach ($f in $functionFiles) { . $f.FullName }
    Assert ($functionFiles.Count -gt 0) "dot-sourced $($functionFiles.Count) function files"
    foreach ($j in (Get-ChildItem -Path (Join-Path $Root 'config') -Filter *.json -File)) {
        $sync.configs[$j.BaseName] = Get-Content -Raw -LiteralPath $j.FullName | ConvertFrom-Json
    }
    Assert ($sync.configs.Count -ge 6) "loaded $($sync.configs.Count) config files"

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $UTNative = Initialize-UTNative
    Assert ($null -ne $UTNative) 'native helpers compiled (PDH / GlobalMemoryStatusEx / DWM)'
    Assert ($null -ne ('UT.NativeV1.PdhQuery' -as [type])) 'UT.NativeV1.PdhQuery type is available'
    Assert ([UT.NativeV1.Display]::StructSizes() -eq '72,64') "CCD structs are 72 and 64 bytes (got $([UT.NativeV1.Display]::StructSizes()))"
    Assert ([UT.NativeV1.NvApi]::StructSizes() -eq '32,96,144') "NvAPI structs are 32, 96 and 144 bytes (got $([UT.NativeV1.NvApi]::StructSizes()))"
    Assert ([UT.NativeV1.NvApi]::DrsSizes() -eq '4116,12296,12328') "NvAPI DRS profile/application/setting sizes are 4116, 12296, 12328 (got $([UT.NativeV1.NvApi]::DrsSizes()))"
    $curMode = [UT.NativeV1.Display]::GetCurrent()
    Assert ($curMode.Width -gt 0 -and $curMode.Height -gt 0) "current display mode $($curMode.Width)x$($curMode.Height)@$($curMode.Hz)"
    Assert (@([UT.NativeV1.Display]::EnumModes()).Count -gt 3) "$(@([UT.NativeV1.Display]::EnumModes()).Count) display modes enumerated"
    Assert ([UT.NativeV1.Display]::GetScaling() -in 1, 2, 3, 4, 5, 128) "display scaling read through the CCD API ($([UT.NativeV1.Display]::GetScaling()))"

    $sync.sysinfo = Get-UTSystemInfo
    Assert ($sync.sysinfo -and $sync.sysinfo.CPU) "system info: $($sync.sysinfo.CPU)"
    Assert ($sync.sysinfo.Build -gt 0) "OS build $($sync.sysinfo.Build).$($sync.sysinfo.UBR)"

    # ---- the boot screen ----------------------------------------------------------------------
    Write-Host 'boot screen'
    function Get-UTSplashStrings($node) {
        $out = @()
        if ($node -is [System.Windows.Controls.TextBlock]) {
            $out += [string]$node.Text
            foreach ($i in $node.Inlines) { if ($i -is [System.Windows.Documents.Hyperlink] -and $i.NavigateUri) { $out += $i.NavigateUri.AbsoluteUri } }
        }
        foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
            if ($c -is [System.Windows.DependencyObject]) { $out += Get-UTSplashStrings $c }
        }
        return $out
    }
    $credits = Get-UTCredits
    $t0 = [DateTime]::UtcNow
    $splash = Show-UTSplash -UserName 'tester'
    Assert ($splash -is [System.Windows.Window]) 'Show-UTSplash returned a Window'
    if ($splash) {
        $strings = @(Get-UTSplashStrings $splash)
        Assert (($strings -join "`n") -match 'Welcome to Unknown Utility, tester') 'the greeting names the user'
        Assert (($strings -join "`n") -match ('MADE BY ' + [regex]::Escape($credits.Author))) 'the author credit is on the boot screen'
        Assert ($strings -contains $credits.Support) 'the support link is on the boot screen'
        Assert ($strings -contains $credits.TikTok) 'the TikTok link is on the boot screen'
        Assert ($splash.IsVisible) 'the boot screen is showing'
        # The minimum is counted from Show, not from Close: the splash covers the load time, so a
        # fast machine still sees it and a slow one is not made to wait on top of the build.
        Close-UTSplash -Window $splash -MinimumMs 300
        $held = ([DateTime]::UtcNow - $t0).TotalMilliseconds
        Assert (-not $splash.IsVisible) 'Close-UTSplash closed it'
        Assert ($held -ge 290) ("it stayed on screen for the minimum time ({0:N0} ms since Show)" -f $held)
        Assert ($null -ne [System.Windows.Threading.Dispatcher]::CurrentDispatcher -and -not [System.Windows.Threading.Dispatcher]::CurrentDispatcher.HasShutdownStarted) 'the dispatcher survived the boot screen'
    }

    # ---- the window ---------------------------------------------------------------------------
    Write-Host 'building the window'
    [xml]$UTXaml = Get-Content -Raw -LiteralPath (Join-Path $Root 'xaml/inputXML.xaml')
    $reader = New-Object System.Xml.XmlNodeReader $UTXaml
    $sync.form = [Windows.Markup.XamlReader]::Load($reader)
    Assert ($sync.form -is [System.Windows.Window]) 'XamlReader.Load returned a Window'

    $collisions = @(); $unresolved = @(); $named = 0
    foreach ($node in $UTXaml.SelectNodes('//*[@Name]')) {
        $n = $node.Name; $named++
        if ($sync.ContainsKey($n)) { $collisions += $n; continue }
        $sync[$n] = $sync.form.FindName($n)
        if ($null -eq $sync[$n]) { $unresolved += $n }
    }
    Assert ($collisions.Count -eq 0) ("no XAML Name collides with a state key" + $(if ($collisions) { ': ' + ($collisions -join ', ') } else { '' }))
    Assert ($unresolved.Count -eq 0) ("all $named named controls resolve via FindName" + $(if ($unresolved) { ': ' + ($unresolved -join ', ') } else { '' }))

    # Every style key the code asks FindResource for must exist, or Initialize-UTUI throws mid-build
    # and leaves a half-populated window.
    $styleKeys = @('Body', 'Dim', 'SectionHeader', 'Orange')
    $missingStyles = @($styleKeys | Where-Object { $null -eq $sync.form.TryFindResource($_) })
    Assert ($missingStyles.Count -eq 0) ("window resources resolve" + $(if ($missingStyles) { ': missing ' + ($missingStyles -join ', ') } else { '' }))

    Write-Host 'building the dynamic UI'
    Initialize-UTUI
    Assert ($sync.CreditText.Text -eq ('MADE BY ' + (Get-UTCredits).Author)) "the bottom bar carries the credit ($($sync.CreditText.Text))"
    Assert ($sync.SupportHyperlink -is [System.Windows.Documents.Hyperlink] -and $sync.SupportHyperlink.NavigateUri.AbsoluteUri -eq (Get-UTCredits).Support) 'the bottom bar Discord link points at the support server'
    Assert ($sync.TikTokHyperlink -is [System.Windows.Documents.Hyperlink] -and $sync.TikTokHyperlink.NavigateUri.AbsoluteUri -eq (Get-UTCredits).TikTok) 'the bottom bar TikTok link points at the channel'
    Assert (([string]$sync.InfoBox.Text) -match [regex]::Escape((Get-UTCredits).Support)) 'the INFO tab lists the support link'
    $tweakCount = @($sync.configs.tweaks.PSObject.Properties).Count
    Assert ($sync.tweakBoxes.Count -eq $tweakCount) "a checkbox for each of the $tweakCount tweaks (got $($sync.tweakBoxes.Count))"
    $appCount = @($sync.configs.applications.PSObject.Properties).Count
    Assert ($sync.appBoxes.Count -eq $appCount) "a checkbox for each of the $appCount applications (got $($sync.appBoxes.Count))"
    Assert ($sync.graphs.Count -eq 5) "5 graph cards (got $($sync.graphs.Count))"
    Assert ($sync.FnProfileList.Items.Count -eq @($sync.configs.fortnite.Profiles.PSObject.Properties).Count) 'a list item for each Fortnite profile'
    Assert ($sync.DnsList.Items.Count -eq @($sync.configs.dns.PSObject.Properties).Count) 'a list item for each DNS provider'
    Assert ($sync.fnArgBoxes.Count -eq @($sync.configs.fortnite.LaunchArgs.Options).Count) 'a checkbox for each launch argument'
    $badButtons = @($sync.actionButtons | Where-Object { -not ($sync[$_] -is [System.Windows.Controls.Button]) })
    Assert ($sync.actionButtons.Count -gt 0 -and $badButtons.Count -eq 0) "$($sync.actionButtons.Count) action buttons, all real Buttons"

    # Invoke-UTButton switches on the button's Name; a button with no case falls through silently.
    # Read the clauses out of the AST, not by regex: cases come in two shapes, 'BtnX' { } and
    # { $_ -in 'BtnX', 'BtnY' } { }, and a regex that only knows the first invents failures.
    $btnTokens = $null; $btnErrors = $null
    $buttonAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $Root 'functions/public/Invoke-UTButton.ps1'), [ref]$btnTokens, [ref]$btnErrors)
    $handled = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $switches = @($buttonAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.SwitchStatementAst] -and
        $n.Condition.Extent.Text -eq '$Name' }, $true))
    foreach ($sw in $switches) {
        foreach ($clause in $sw.Clauses) {
            foreach ($s in $clause.Item1.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                [void]$handled.Add($s.Value)
            }
        }
    }
    Assert ($switches.Count -eq 1) "found the switch (`$Name) in Invoke-UTButton (got $($switches.Count))"
    $allButtons = @($sync.Keys | Where-Object { $sync[$_] -is [System.Windows.Controls.Button] })
    $unhandled = @($allButtons | Where-Object { -not $handled.Contains($_) })
    Assert ($unhandled.Count -eq 0) ("every button has a case in Invoke-UTButton" + $(if ($unhandled) { ': ' + ($unhandled -join ', ') } else { '' }))

    Assert ($sync.VaProfileList.Items.Count -eq @($sync.configs.valorant.Profiles.PSObject.Properties).Count) 'a list item for each VALORANT profile'
    $stretchRows = @(Get-UTStretchedPresets)
    Assert ($sync.StretchPresetList.Items.Count -eq $stretchRows.Count) "a row for each of the $($stretchRows.Count) stretched modes this monitor can take"
    Assert (@($stretchRows | Where-Object { $_.Width -ge 1920 }).Count -eq 0) 'no row is as wide as the panel, so every one of them is a stretch'
    Assert (@($stretchRows | Where-Object { $_.Valorant -and ($_.Width -lt 1280 -or $_.Height -lt 720) }).Count -eq 0) 'no row claims VALORANT support below the game minimum'
    Assert ($sync.StretchGameList.Items.Count -eq 3) 'the three stretched targets are listed'
    Assert ($sync.StretchStatusText.Text -match '\d+x\d+') "the STRETCHED tab shows the current mode ($($sync.StretchStatusText.Text))"
    Assert ($sync.gameReadyBoxes.Count -gt 0) "the GAME READY tab lists $($sync.gameReadyBoxes.Count) closable processes"
    $grNever = @(Get-UTNeverKill)
    Assert (@($sync.gameReadyBoxes.Keys | Where-Object { $grNever -contains [string]$sync.gameReadyBoxes[$_].Tag }).Count -eq 0) 'no protected process has a GAME READY checkbox'
    Assert ($sync.RecommendPanel.Children.Count -gt 0) "the SYSTEM tab lists $($sync.RecommendPanel.Children.Count) recommendation lines for this PC"
    Assert ($sync.mode -eq 'Advanced') "the window opens in Advanced mode (got $($sync.mode))"
    Assert ($sync.AdvancedRoot.Visibility -eq 'Visible' -and $sync.SimpleRoot.Visibility -eq 'Collapsed') 'Advanced is the visible view at startup'
    Assert ($sync.simpleTiles.Count -eq @($sync.configs.simple.Games.PSObject.Properties).Count) "a tile for each of the $($sync.simpleTiles.Count) Simple-mode games"
    Assert ($sync.SimplePlanPanel.Children.Count -gt 0) "the Simple plan lists $($sync.SimplePlanPanel.Children.Count) lines for $($sync.simpleGame)"
    Assert ($sync.BtnSimpleOptimize.Content -match 'OPTIMIZE') "the optimize button names the game ($($sync.BtnSimpleOptimize.Content))"
    Set-UTMode -Mode 'Simple'
    Assert ($sync.SimpleRoot.Visibility -eq 'Visible' -and $sync.AdvancedRoot.Visibility -eq 'Collapsed') 'the toggle switches to Simple'
    Set-UTMode -Mode 'Advanced'
    Assert ($sync.AdvancedRoot.Visibility -eq 'Visible') 'and back to Advanced'
    $startupItems = @(Get-UTStartupItems)
    Assert ($sync.startupBoxes.Count -eq $startupItems.Count) "a checkbox for each of the $($startupItems.Count) startup entries (got $($sync.startupBoxes.Count))"
    Assert ($null -eq $sync.StartupNote) 'STARTUP tab carries no explanatory blurb'
    $bloat = @(Get-UTBloatApps)
    Assert ($sync.debloatBoxes.Count -eq $bloat.Count) "a checkbox for each of the $($bloat.Count) installed catalogue apps (got $($sync.debloatBoxes.Count))"
    Assert ($null -eq $sync.DebloatNote) 'DEBLOAT tab carries no explanatory blurb'
    $noTip = @($sync.tweakBoxes.Keys | Where-Object { $null -eq $sync.tweakBoxes[$_].ToolTip })
    Assert ($noTip.Count -eq 0) ("every tweak has a hover card" + $(if ($noTip) { ': missing ' + ($noTip -join ', ') } else { '' }))
    $noWhy = @($sync.tweakBoxes.Keys | Where-Object { $tip = $sync.tweakBoxes[$_].ToolTip; -not ($tip -is [System.Windows.Controls.StackPanel] -and @($tip.Children | Where-Object { $_.Text -eq 'WHY IT WORKS' }).Count -eq 1) })
    Assert ($noWhy.Count -eq 0) ("every hover card has a WHY IT WORKS section" + $(if ($noWhy) { ': missing ' + ($noWhy -join ', ') } else { '' }))
    $inline = @($sync.TweaksPanel.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and ([string]$_.Text).Length -gt 80 })
    Assert ($inline.Count -eq 0) "no inline paragraphs in the tweak list (found $($inline.Count))"
    # The list must only ever offer things that are really here, or it is a wall of dead entries.
    $installedNames = @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    $ghosts = @($sync.debloatBoxes.Keys | Where-Object { $installedNames -notcontains $_ })
    Assert ($ghosts.Count -eq 0) ("every app offered is actually installed" + $(if ($ghosts) { ': ' + ($ghosts -join ', ') } else { '' }))
    Assert ($sync.InfoBox.Text -match 'CPU') 'INFO tab rendered'
    Assert ($sync.FnStatusText.Text -and $sync.FnStatusText.Text -notmatch '^detection failed') ('FORTNITE status: ' + (($sync.FnStatusText.Text -split "`r?`n")[0]))

    # ---- layout, so the graph canvases have a real size ----------------------------------------
    if ($Show) {
        $sync.form.WindowStartupLocation = 'Manual'
        $sync.form.Left = -32000; $sync.form.Top = -32000
        $sync.form.ShowInTaskbar = $false
        $sync.form.Show()
    } else {
        $content = $sync.form.Content
        $content.Measure((New-Object System.Windows.Size(1280, 800)))
        $content.Arrange((New-Object System.Windows.Rect(0, 0, 1280, 800)))
        $content.UpdateLayout()
    }

    # ---- monitor, timer, and one real worker job -----------------------------------------------
    Write-Host "running for $Seconds seconds"
    Start-UTMonitor
    Start-UTUITimer
    Assert ($null -ne $sync.monitor -and $null -ne $sync.timer) 'monitor runspace and UI timer started'

    $sync.startupProbe = $false
    Assert (Start-UTUIJob -Kind 'refresh' -Script '$sync.startupProbe = $true') 'a worker job started'

    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $stop = New-Object System.Windows.Threading.DispatcherTimer
    $stop.Interval = [TimeSpan]::FromSeconds([math]::Max(4, $Seconds))
    $stop.Add_Tick({ $stop.Stop(); $dispatcher.InvokeShutdown() })
    $stop.Start()
    [System.Windows.Threading.Dispatcher]::Run()

    # ---- what the run produced ------------------------------------------------------------------
    Write-Host 'checking what came out'
    $snap = $sync.metrics.Snapshot
    Assert ($null -ne $snap) 'the monitor published a snapshot'
    if ($snap) {
        Assert ($snap.Backend -eq 'pdh') ("monitor backend=$($snap.Backend)" + $(if ($snap.Backend -ne 'pdh') { ' (wmi means the native helpers failed; works, but costs more CPU)' } else { '' }))
        Assert ($null -ne $snap.CpuPercent -and $snap.CpuPercent -ge 0 -and $snap.CpuPercent -le 100) "CPU $($snap.CpuPercent)% in range"
        Assert ($null -ne $snap.MemUsedPercent -and $snap.MemTotalBytes -gt 0) ("RAM {0}% of {1:N0} GB" -f $snap.MemUsedPercent, ($snap.MemTotalBytes / 1GB))
        Assert ($null -ne $snap.DiskActivePercent -and $snap.DiskActivePercent -ge 0 -and $snap.DiskActivePercent -le 100) "disk active $($snap.DiskActivePercent)%"
        Assert ($snap.NetRxBps -ge 0 -and $snap.NetTxBps -ge 0) ("network down {0:N0} up {1:N0} B/s" -f $snap.NetRxBps, $snap.NetTxBps)
        if ($null -ne $snap.GpuPercent) { Assert ($snap.GpuPercent -ge 0 -and $snap.GpuPercent -le 100) "GPU $($snap.GpuPercent)% on engine '$($snap.GpuBusiestEngine)'" }
        else { Skip 'GPU counters (no WDDM 2.0 GPU Engine instances on this machine)' }
        Assert ($snap.SampleMs -lt 1000) "a sample costs $($snap.SampleMs) ms, under the 1 s tick"
        if ($SkipNetwork) { Skip 'gateway / internet ping' }
        else { Assert ($null -ne $snap.InetMs -or $snap.InetStatus -ne 'n/a') "internet ping: $($snap.InetMs) ms ($($snap.InetStatus))" }
    }

    Assert ($sync.lastTick -gt 0) "the UI timer consumed $($sync.lastTick) monitor ticks"
    $drawn = @($sync.graphs.Values | Where-Object { $_.Canvas.Children.Count -gt 0 })
    if ($sync.graphs.cpu.Canvas.ActualWidth -gt 0) { Assert ($drawn.Count -ge 4) "$($drawn.Count) of $($sync.graphs.Count) graphs drew something" }
    else { Skip 'graph rendering (canvas never got a layout pass)' }

    Assert ([bool]$sync.startupProbe) 'the worker job ran and wrote back to $sync'
    Assert (-not $sync.busy) 'busy flag cleared after the job finished'
    Assert ($sync.jobs.Count -eq 0) "finished jobs were disposed (still tracked: $($sync.jobs.Count))"

    $console = ''
    try { $console = [string]$sync.ConsoleBox.Text } catch { }
    Assert ($console -match 'ready|starting|monitor:') 'the OUTPUT pane received log lines'
    $errs = @($console -split "`r?`n" | Where-Object { $_ -match '\[ERR \]|ui tick error|monitor error|monitor stopped unexpectedly' })
    Assert ($errs.Count -eq 0) ("nothing logged an error" + $(if ($errs) { ': ' + ($errs -join ' | ') } else { '' }))

    # ---- shutdown, the way start.ps1 does it -----------------------------------------------------
    Write-Host 'shutting down'
    if ($Show) { $sync.form.Close() }
    $sync.closing = $true
    $sync.timer.Stop()
    Stop-UTMonitor
    Stop-UTJobs
    Assert ($sync.monitor.Handle.IsCompleted) 'the monitor runspace stopped'
    Assert ($sync.jobs.Count -eq 0) 'no worker runspaces left'
    Assert ((Get-Content -LiteralPath $sync.logPath -ErrorAction SilentlyContinue).Count -gt 0) 'the log file was written'
}
finally {
    try { $sync.closing = $true } catch { }
    try { if ($sync.timer) { $sync.timer.Stop() } } catch { }
    try { Stop-UTMonitor } catch { }
    try { Stop-UTJobs } catch { }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed, {2} skipped" -f $script:pass, $script:fail, $script:skip) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
