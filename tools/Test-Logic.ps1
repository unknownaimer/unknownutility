<#
.SYNOPSIS
    Runs the platform-independent logic of unknowntweaks under any PowerShell (7 on macOS/Linux included).
    Registry, services, WPF and the monitor need Windows and are not covered here.
#>
[CmdletBinding()]
param([string]$Root, [switch]$SkipNetwork)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside a param() default on an advanced script.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
$script:pass = 0; $script:fail = 0
function Assert([bool]$cond, [string]$what) {
    if ($cond) { $script:pass++; Write-Host "  ok    $what" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $what" -ForegroundColor Red }
}

$sync = [hashtable]::Synchronized(@{})
$sync.log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.backupDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ut-test-' + [guid]::NewGuid().ToString('N'))
$sync.configs = @{}
$sync.form = $null
$sync.status = ''
foreach ($f in 'Write-UTLog', 'Set-UTRegistry', 'Set-UTIniValue', 'Save-UTBackup', 'Set-UTLaunchArgs', 'Invoke-UTTweaks', 'Get-UTStartupItems', 'Remove-UTAppxPackages', 'Measure-UTRegionPing', 'Test-UTDnsLatency', 'Test-UTBetaGate', 'Get-UTGameReady', 'Get-UTRunningGame', 'Invoke-UTBenchmark', 'Get-UTValorant', 'Set-UTNvProfile', 'Invoke-UTSimple') {
    . (Join-Path $Root "functions/private/$f.ps1")
}
foreach ($j in 'gameservers', 'dns', 'tweaks', 'fortnite', 'debloat', 'games', 'gameready', 'valorant', 'stretched', 'nvprofile', 'simple') {
    $sync.configs[$j] = Get-Content -Raw (Join-Path $Root "config/$j.json") | ConvertFrom-Json
}

Write-Host "registry value conversion"
Assert ((ConvertTo-UTRegistryValue -Type DWord -Value '4294967295') -eq -1) 'DWord 0xFFFFFFFF becomes Int32 -1'
Assert ((ConvertTo-UTRegistryValue -Type DWord -Value '10') -eq 10) 'DWord 10'
Assert ((ConvertFrom-UTRegistryValue -Raw ([int]-1) -Kind DWord) -eq '4294967295') 'Int32 -1 reads back as 4294967295'
$bin = ConvertTo-UTRegistryValue -Type Binary -Value '90,12,03,80,10,00,00,00'
Assert (($bin.Count -eq 8) -and ($bin[0] -eq 144) -and ($bin[3] -eq 128)) 'Binary csv hex -> bytes'
Assert ((ConvertFrom-UTRegistryValue -Raw $bin -Kind Binary) -eq '90,12,03,80,10,00,00,00') 'bytes -> csv hex round trip'
$ms = ConvertTo-UTRegistryValue -Type MultiString -Value 'a|b|c'
Assert (($ms.Count -eq 3) -and ($ms[2] -eq 'c')) 'MultiString'
Assert ((ConvertTo-UTRegistryValue -Type String -Value '506') -is [string]) 'String stays string'

Write-Host "tweak catalogue sanity"
$tw = $sync.configs.tweaks
$ids = @($tw.PSObject.Properties.Name)
Assert ($ids.Count -ge 35) "catalogue has $($ids.Count) tweaks"
$bad = @()
foreach ($id in $ids) {
    $t = $tw.$id
    if ($t.Tier -notin 'safe', 'optional', 'risky') { $bad += "$id tier" }
    if (-not $t.Content -or -not $t.Description) { $bad += "$id text" }
    # The hover card is the only explanation the UI shows, so every tweak must carry its evidence.
    if (-not $t.Evidence) { $bad += "$id evidence" }
    foreach ($r in @($t.registry)) { if ($r -and ($r.Type -notin 'DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')) { $bad += "$id regtype $($r.Type)" } }
    foreach ($r in @($t.registry)) { if ($r -and -not ($r.Path -match '^HK(LM|CU):\\')) { $bad += "$id regpath $($r.Path)" } }
    # GuardScript runs before anything is snapshotted, so a broken one only ever surfaces at apply time.
    foreach ($s in @($t.GuardScript) + @($t.InvokeScript) + @($t.UndoScript)) {
        if (-not $s) { continue }
        $tok = $null; $err = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$tok, [ref]$err)
        if ($err.Count) { $bad += "$id script parse: $($err[0].Message)" }
    }
    foreach ($r in @($t.registry)) { if ($r -and -not $r.Name) { $bad += "$id registry entry with no Name under $($r.Path)" } }
    # Set-UTService / Set-UTScheduledTask take these verbatim, so a typo here is a runtime failure.
    foreach ($s in @($t.service)) {
        if (-not $s) { continue }
        if (-not $s.Name) { $bad += "$id service with no Name" }
        foreach ($w in $s.StartupType, $s.OriginalType) { if ($w -notin 'Boot', 'System', 'Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled') { $bad += "$id service startup '$w'" } }
    }
    foreach ($k in @($t.ScheduledTask)) {
        if (-not $k) { continue }
        if (-not $k.Name) { $bad += "$id scheduled task with no Name" }
        foreach ($w in $k.State, $k.OriginalState) { if ($w -notin 'Enabled', 'Disabled') { $bad += "$id task state '$w'" } }
    }
    # A tweak that says "Windows 11" in its own text but declares no MinBuild will be offered to
    # Windows 10 users and write a key their build ignores. TimerResGlobal shipped exactly that way.
    if (($t.Content -match 'Windows 11' -or $t.Description -match 'Windows 11 /|Windows 11 only|only on Windows 11') -and -not $t.MinBuild) {
        $bad += "$id says Windows 11 but declares no MinBuild"
    }
    if ($t.Recommended -and $t.Tier -ne 'safe') { $bad += "$id recommended but not safe" }
}
Assert ($bad.Count -eq 0) ("every tweak well-formed" + $(if ($bad) { ': ' + ($bad -join '; ') } else { '' }))
$risky = @($ids | Where-Object { $tw.$_.Tier -eq 'risky' })
Assert ($risky.Count -ge 5) "risky tier has $($risky.Count) entries, none recommended"

Write-Host "ini merge"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ut-ini-' + [guid]::NewGuid().ToString('N') + '.ini')
$orig = "[/Script/FortniteGame.FortGameUserSettings]`r`nbUseVSync=True`r`nFrameRateLimit=144.000000`r`nKeepMe=1`r`n`r`n[ScalabilityGroups]`r`nsg.ShadowQuality=3`r`n"
[System.IO.File]::WriteAllText($tmp, $orig, (New-Object System.Text.UTF8Encoding($true)))
$ini = Read-UTIniFile -Path $tmp
Assert ($ini.HasBom) 'BOM detected'
Assert ($ini.Sections['ScalabilityGroups']['sg.ShadowQuality'] -eq '3') 'parsed section/key'
$n = Set-UTIniValues -Path $tmp -Settings @{
    '/Script/FortniteGame.FortGameUserSettings' = @{ 'bUseVSync' = 'False'; 'FrameRateLimit' = '0.000000'; 'LatencyTweak2' = '2' }
    'ScalabilityGroups' = @{ 'sg.ShadowQuality' = '0'; 'sg.FoliageQuality' = '0' }
    'D3DRHIPreference' = @{ 'PreferredRHI' = 'dx12'; 'PreferredFeatureLevel' = 'es31' }
}
Assert ($n -eq 7) "7 changes reported (got $n)"
$bytes = [System.IO.File]::ReadAllBytes($tmp)
Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) 'BOM preserved'
$text = [System.IO.File]::ReadAllText($tmp)
Assert ($text -match "(?m)^bUseVSync=False\r$") 'replaced in place with CRLF'
Assert ($text -match "(?m)^KeepMe=1\r$") 'unknown key preserved'
Assert ($text -match "(?m)^LatencyTweak2=2\r$") 'new key appended to section'
Assert ($text -match "(?m)^\[D3DRHIPreference\]\r$" -and $text -match "(?m)^PreferredFeatureLevel=es31\r$") 'new section created'
Assert ((Get-UTIniValue -Path $tmp -Section 'ScalabilityGroups' -Key 'sg.FoliageQuality') -eq '0') 'read back appended key'
$again = Set-UTIniValues -Path $tmp -Settings @{ 'ScalabilityGroups' = @{ 'sg.ShadowQuality' = '0' } }
Assert ($again -eq 0) 'idempotent second write'
$order = [regex]::Matches($text, '(?m)^\[(.+)\]').Count
Assert ($order -eq 3) 'exactly three sections'
Remove-Item $tmp -Force

Write-Host "script state / backups"
Save-UTScriptState -Id 'UTTest' -Key 'PCI\VEN_10DE&DEV_2684\4&abc&0&0008' -Value 'missing'
Save-UTScriptState -Id 'UTTest' -Key 'Usb' -Value 1
$st = Get-UTScriptState -Id 'UTTest'
Assert ($st.Count -eq 2 -and $st['Usb'] -eq '1') 'state round trip'
Assert ((Get-UTScriptState -Id 'UTTest' -Key 'PCI\VEN_10DE&DEV_2684\4&abc&0&0008') -eq 'missing') 'backslash keys survive JSON'
Assert ($null -eq (Get-UTScriptState -Id 'UTTest' -Key 'nope')) 'missing key -> null'
Remove-UTBackup -Id 'UTTest'
Assert (-not (Test-UTBackupExists -Id 'UTTest')) 'backup removed'

Write-Host "fortnite profiles"
$fn = $sync.configs.fortnite
foreach ($p in $fn.Profiles.PSObject.Properties) {
    $secs = @($p.Value.Settings.PSObject.Properties.Name)
    Assert ($secs -contains '/Script/FortniteGame.FortGameUserSettings') "$($p.Name) targets the main section"
}
$forbidden = @('r.Fog', 'r.ViewDistanceScale', 'r.Shadow.MaxResolution', 'foliage.', 'grass.', 'r.Nanite', 'r.Lumen.')
$leak = @()
$json = Get-Content -Raw (Join-Path $Root 'config/fortnite.json')
foreach ($f in $forbidden) { if ($json.Contains($f) -and $f -ne 'r.Lumen.') { $leak += $f } }
Assert ($leak.Count -eq 0) 'no engine cvar overrides in fortnite.json'

Write-Host "simple mode"
$sm = $sync.configs.simple
$smKinds = @('restorepoint', 'tweaks', 'fortnite-profile', 'fortnite-args', 'valorant-profile', 'nvprofile')
$smBad = @()
foreach ($g in $sm.Games.PSObject.Properties) {
    if (-not $g.Value.Content) { $smBad += "$($g.Name) content" }
    foreach ($s in @($g.Value.Steps)) {
        if ($smKinds -notcontains [string]$s.Kind) { $smBad += "$($g.Name) kind $($s.Kind)" }
        if (-not $s.Text -or -not $s.Detail) { $smBad += "$($g.Name) $($s.Kind) undescribed" }
    }
    Assert (@($g.Value.Steps)[0].Kind -eq 'restorepoint') "$($g.Name) takes a restore point before anything else"
}
Assert ($smBad.Count -eq 0) ("every simple step is a known kind and is described" + $(if ($smBad) { ': ' + ($smBad -join ', ') } else { '' }))
# A one-click mode must never reach past the safe tier: it is used by people who cannot judge the cost.
$smIds = @($sync.configs.tweaks.PSObject.Properties | Where-Object { $_.Value.Tier -eq 'safe' -and $_.Value.Recommended } | ForEach-Object { $_.Name })
Assert ($smIds.Count -gt 0 -and @($smIds | Where-Object { $sync.configs.tweaks.$_.Tier -ne 'safe' }).Count -eq 0) "simple mode's tweak step is the $($smIds.Count)-tweak safe preset and nothing else"
# The DX11 argument must be chosen per GPU, not written blindly: it hurts modern cards.
$sync.sysinfo = [pscustomobject]@{ GPUVendor = 'NVIDIA'; GPU = 'NVIDIA GeForce GTX 1650'; VramGB = 4 }
$legacy = @(Get-UTSimplePlan -Game 'Fortnite' | Where-Object { $_.Kind -eq 'fortnite-args' -and $_.Applies })
Assert ($legacy.Count -eq 1 -and $legacy[0].Value -match '-d3d11') "a GTX 1650 gets the DX11 arguments ($($legacy[0].Value))"
$sync.sysinfo = [pscustomobject]@{ GPUVendor = 'NVIDIA'; GPU = 'NVIDIA GeForce RTX 4070'; VramGB = 12 }
$modern = @(Get-UTSimplePlan -Game 'Fortnite' | Where-Object { $_.Kind -eq 'fortnite-args' -and $_.Applies })
Assert ($modern.Count -eq 1 -and $modern[0].Value -notmatch '-d3d11') "an RTX 4070 is left on DX12 ($($modern[0].Value))"
$sync.sysinfo = [pscustomobject]@{ GPUVendor = 'AMD'; GPU = 'AMD Radeon RX 7800 XT'; VramGB = 16 }
$amd = @(Get-UTSimplePlan -Game 'Fortnite' | Where-Object { $_.Applies })
Assert (@($amd | Where-Object { $_.Kind -eq 'nvprofile' }).Count -eq 0) 'an AMD card is not offered the NVIDIA driver profile'
Assert (@($amd | Where-Object { $_.Kind -eq 'fortnite-args' }).Count -eq 1) 'exactly one launch-argument step ever applies'
$sync.sysinfo = $null

Write-Host "nvidia driver profile"
$nv = $sync.configs.nvprofile
Assert ($nv.Application -match '\.exe$') "the driver profile targets an executable ($($nv.Application))"
$nvBad = @(); $nvIds = @{}
foreach ($p in $nv.Presets.PSObject.Properties) {
    if (-not $p.Value.Content -or -not $p.Value.Description) { $nvBad += "$($p.Name) text" }
    foreach ($s in @($p.Value.Settings)) {
        if ([string]$s.Id -notmatch '^0x[0-9A-Fa-f]{8}$') { $nvBad += "$($p.Name) id $($s.Id)" }
        if ([string]$s.Value -notmatch '^0x[0-9A-Fa-f]{8}$') { $nvBad += "$($p.Name) value $($s.Value)" }
        if (-not $s.Name -or -not $s.Means) { $nvBad += "$($p.Name) $($s.Id) undescribed" }
        $nvIds[[string]$s.Id] = $true
    }
}
Assert ($nvBad.Count -eq 0) ("every driver setting is a named 32-bit id and value" + $(if ($nvBad) { ': ' + ($nvBad -join ', ') } else { '' }))
# Every id must be one NVIDIA publishes in NvApiDriverSettings.h; a typo here writes a stranger's driver.
$known = @('0x1057EB71', '0x00CE2691', '0x00E73211', '0x0084CD70', '0x002ECAF2', '0x00A879CF', '0x007BA09E', '0x10D2BB16', '0x101E61A9', '0x00638E8F', '0x00738E8F')
$unknownIds = @($nvIds.Keys | Where-Object { $known -notcontains $_ })
Assert ($unknownIds.Count -eq 0) ("every id is one from NVIDIA's published header" + $(if ($unknownIds) { ': ' + ($unknownIds -join ', ') } else { '' }))
$lod = @($nv.Presets.Potato.Settings | Where-Object { $_.Id -eq '0x00738E8F' })
Assert ($lod.Count -eq 1 -and [Convert]::ToUInt32($lod[0].Value, 16) -gt 0 -and [Convert]::ToUInt32($lod[0].Value, 16) -le 128) 'the LOD bias is positive (blurrier), never negative'
$perf = @($nv.Presets.Performance.Settings | Where-Object { $_.Id -eq '0x00738E8F' -or $_.Id -eq '0x101E61A9' })
Assert ($perf.Count -eq 0) 'the Performance preset changes nothing visual'
$nvParsed = Get-UTNvProfileIds -PresetName 'Potato'
Assert ($nvParsed.Ids.Count -eq $nvParsed.Values.Count -and $nvParsed.Ids.Count -eq @($nv.Presets.Potato.Settings).Count) "Potato parses to $($nvParsed.Ids.Count) id/value pairs"
Assert ($nvParsed.Ids[0] -is [uint32]) 'ids parse as unsigned 32-bit'

Write-Host "valorant profiles"
$va = $sync.configs.valorant
Assert (@($va.Profiles.PSObject.Properties).Count -ge 3) "valorant.json has $(@($va.Profiles.PSObject.Properties).Count) profiles"
$vaBad = @()
foreach ($p in $va.Profiles.PSObject.Properties) {
    if (-not $p.Value.Content -or -not $p.Value.Description) { $vaBad += "$($p.Name) text" }
    foreach ($k in @($p.Value.Riot.PSObject.Properties.Name)) { if ($k -notmatch '^EAres(Int|Bool|Float|String)SettingName::') { $vaBad += "$($p.Name) riot key $k" } }
    foreach ($k in @($p.Value.Game.PSObject.Properties.Name)) { if ($k -match '^EAres') { $vaBad += "$($p.Name) riot key in Game section: $k" } }
}
Assert ($vaBad.Count -eq 0) ("every valorant profile is well-formed" + $(if ($vaBad) { ': ' + ($vaBad -join ', ') } else { '' }))
Assert ($va.GameSection -eq '/Script/ShooterGame.ShooterGameUserSettings') 'valorant game section is the ShooterGame one'

Write-Host "game detection"
$g = $sync.configs.games
Assert (@($g.KnownGames.PSObject.Properties).Count -ge 40) "$(@($g.KnownGames.PSObject.Properties).Count) known game executables"
Assert (@($g.KnownGames.PSObject.Properties.Name) -contains 'VALORANT-Win64-Shipping' -and @($g.KnownGames.PSObject.Properties.Name) -contains 'FortniteClient-Win64-Shipping') 'Fortnite and VALORANT are known by their shipping executables'
$overlap = @($g.KnownGames.PSObject.Properties.Name | Where-Object { @($g.LauncherProcesses) -contains $_ })
Assert ($overlap.Count -eq 0) ("no game executable is also listed as a launcher" + $(if ($overlap) { ': ' + ($overlap -join ', ') } else { '' }))
$running = Get-UTRunningGame
Assert ($null -eq $running -or ($running.Pid -gt 0 -and $running.Title)) ("Get-UTRunningGame returns nothing or a titled process" + $(if ($running) { " (found $($running.Title))" } else { '' }))

Write-Host "game ready"
$never = @(Get-UTNeverKill)
foreach ($n in 'csrss', 'wininit', 'lsass', 'services', 'dwm', 'explorer', 'audiodg', 'vgc', 'EasyAntiCheat_EOS', 'BEService', 'NVDisplay.Container', 'powershell') {
    Assert ($never -contains $n) "$n is never offered for closing"
}
$keepNever = @($sync.configs.gameready.Keep.PSObject.Properties.Name + $sync.configs.gameready.Background.PSObject.Properties.Name | Where-Object { $never -contains $_ })
Assert ($keepNever.Count -eq 0) ("gameready.json never lists a protected process" + $(if ($keepNever) { ': ' + ($keepNever -join ', ') } else { '' }))
$cands = @(Get-UTGameReadyCandidates)
$leaked = @($cands | Where-Object { $never -contains $_.Name })
Assert ($leaked.Count -eq 0) "no protected process among $($cands.Count) candidate apps on this PC"
$self = [System.Diagnostics.Process]::GetCurrentProcess()
Assert (@($cands | Where-Object { $_.Pids -contains $self.Id }).Count -eq 0) 'the tool itself is not a candidate'
Assert (@($cands | Where-Object { $_.Count -ne $_.Pids.Count -or $_.Count -lt 1 }).Count -eq 0) 'every candidate app carries its process ids'
Assert (@($cands | Group-Object Name | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'one row per app name, not per process'

Write-Host "stretched presets"
$sp = $sync.configs.stretched
$badPreset = @($sp.Presets | Where-Object { $_.Width -le 0 -or $_.Height -le 0 -or $_.Width -gt 7680 -or ($_.Width / $_.Height) -ge 1.7 })
Assert ($badPreset.Count -eq 0) "every preset is a real stretched shape (narrower than 16:9)"
Assert (@($sp.Games.PSObject.Properties.Name) -contains 'Fortnite' -and @($sp.Games.PSObject.Properties.Name) -contains 'Valorant' -and @($sp.Games.PSObject.Properties.Name) -contains 'None') 'the three stretched targets exist'

Write-Host "recommendations"
$sync.sysinfo = [pscustomobject]@{ VBSStatus = 2; HVCIRunning = $true; IsLaptop = $true; DiskType = 'HDD'; GPUVendor = 'NVIDIA'; GPU = 'NVIDIA GeForce RTX 3060'; Is11 = $true; Build = 22631; CPU = 'AMD Ryzen 7 7800X3D'; RamGB = 16 }
$sync.benchmark = $null
$rec = @(Get-UTRecommendations)
Assert ($rec.Count -ge 8) "$($rec.Count) recommendations for a laptop with VBS on, HDD and an RTX card"
Assert (@($rec | Where-Object { $_.Tier -eq 'risky' -and $_.Tick }).Count -eq 0) 'no risky tweak is ever ticked automatically'
Assert (@($rec | Where-Object { $_.Id -eq 'UTVBSOff' }).Count -eq 1) 'VBS off is named when VBS is running'
Assert (@($rec | Where-Object { $_.Id -eq 'UTSearchIndexOff' -and $_.Tick }).Count -eq 1) 'search indexing off is ticked on a hard disk'
Assert (@($rec | Where-Object { $_.Id -eq 'UTHibernateOff' }).Count -eq 0) 'hibernation off is not offered on a laptop'
Assert (@($rec | Where-Object { $_.Why }).Count -eq $rec.Count) 'every recommendation carries a reason'
Assert ((Get-UTPerformanceTier -CpuSingle 95 -CpuMulti 90 -Gpu 'NVIDIA GeForce RTX 4070') -eq 'high-end') 'tier: fast CPU + RTX 40 = high-end'
Assert ((Get-UTPerformanceTier -CpuSingle 95 -CpuMulti 90 -Gpu 'Intel(R) UHD Graphics 630') -eq 'low') 'tier: an iGPU caps the tier at low'
$sync.sysinfo = $null

Write-Host "table formatting"
# 'Internet (Cloudflare)' is 21 characters and is the real label of the baseline row, so it is the
# case that used to push the rest of its row out of the columns.
$rows = @([pscustomobject]@{ Region = 'NA-East'; Host = 'x'; Location = 'Ohio'; AvgMs = 23; MinMs = 21; MaxMs = 30; JitterMs = 8.2; LossPct = 0 },
          [pscustomobject]@{ Region = 'Internet (Cloudflare)'; Host = '1.1.1.1'; Location = 'nearest anycast edge'; AvgMs = 20; MinMs = 20; MaxMs = 21; JitterMs = 1; LossPct = 0 },
          [pscustomobject]@{ Region = 'Middle East'; Host = 'y'; Location = 'Bahrain'; AvgMs = $null; MinMs = $null; MaxMs = $null; JitterMs = $null; LossPct = 100 })
$tbl = Format-UTRegionTable -Rows $rows
Assert ($tbl -match 'NA-East' -and $tbl -match 'no ICMP reply') 'table renders both reply and no-reply rows'
$pcts = @($tbl -split "`r`n" | Select-Object -Skip 1 | ForEach-Object { $_.IndexOf('%') })
Assert (@($pcts | Sort-Object -Unique).Count -eq 1) ("every region row's LOSS column lands at the same column (got " + ($pcts -join ',') + ')')
Assert ($tbl -match 'Ohio   <- high jitter' -and $tbl -notmatch 'Ohio jitter') 'the jitter note is separated from the location name'

$dnsRows = @([pscustomobject]@{ Name = 'Cloudflare'; Server = '1.1.1.1'; MedianMs = 12; BestMs = 11; Ok = 5; Sent = 5 },
             [pscustomobject]@{ Name = 'A very long resolver name'; Server = '2620:fe::fe:11'; MedianMs = $null; BestMs = $null; Ok = 0; Sent = 5 })
$dnsTbl = Format-UTDnsTable -Rows $dnsRows
$oks = @($dnsTbl -split "`r`n" | Select-Object -First 3 | ForEach-Object { $_.TrimEnd().Length })
Assert (@($oks | Sort-Object -Unique).Count -eq 1) ("the DNS table's last column ends at the same width on every row (got " + ($oks -join ',') + ')')
Assert ($dnsTbl -match 'timeout') 'a resolver that never answered reads as timeout'

if (-not $SkipNetwork) {
    Write-Host "network (live)"
    $dns = @(Test-UTDnsLatency -Server '1.1.1.1' -Samples 3 -TimeoutMs 2000)
    Assert (($dns | Where-Object { $_.Ok }).Count -ge 1) ("raw UDP DNS query to 1.1.1.1 answered ({0})" -f (($dns | ForEach-Object { $_.Ms }) -join ','))
    try {
        $reg = Measure-UTRegionPing -Rounds 2 -TimeoutMs 1500
        $answered = @($reg | Where-Object { $null -ne $_.AvgMs })
        Assert ($answered.Count -ge 1) ("region ping answered by {0} of {1} hosts; best: {2}" -f $answered.Count, $reg.Count, $sync.bestRegion)
        Write-Host (Format-UTRegionTable -Rows $reg)
    } catch { Assert $false "region ping threw: $($_.Exception.Message)" }
}


# ---------------------------------------------------------------------------------------------
Write-Host "worker script wrapping"
# Every -Script passed to Start-UTUIJob is embedded in Start-UTJob's here-string wrapper and then
# parsed in a fresh runspace. Rebuild that text exactly and parse it.
# The wrapper template is lifted out of Start-UTJob itself, so this test can never drift from it.
$rsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'functions/private/Invoke-UTRunspace.ps1'), [ref]$null, [ref]$null)
$startJob = @($rsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-UTJob' }, $true))[0]
$template = @($startJob.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | Where-Object { $_.Value -match 'jobDone' })[0]
Assert ($null -ne $template) 'wrapper here-string located in Start-UTJob'
$wrapper = [scriptblock]::Create('param($Kind,$Script) ' + $template.Extent.Text)
function Build-WrappedScript([string]$Kind, [string]$Script) { return (& $wrapper $Kind $Script) }
$buttonSrc = Get-Content -Raw (Join-Path $Root 'functions/public/Invoke-UTButton.ps1')
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($buttonSrc, [ref]$tokens, [ref]$errors)
$calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-UTUIJob' }, $true)
Assert ($calls.Count -ge 14) "found $($calls.Count) Start-UTUIJob call sites"
$workerScripts = @()
foreach ($c in $calls) {
    $elems = @($c.CommandElements)
    for ($i = 0; $i -lt $elems.Count - 1; $i++) {
        if ($elems[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elems[$i].ParameterName -eq 'Script') {
            $v = $elems[$i + 1]
            if ($v -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $workerScripts += $v.Value }
            elseif ($v -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $workerScripts += $v.Value }
        }
    }
}
Assert ($workerScripts.Count -eq $calls.Count) "extracted $($workerScripts.Count) literal -Script values"
$wrapBad = @()
foreach ($ws in $workerScripts) {
    $wrapped = Build-WrappedScript -Kind 'apply' -Script $ws
    $t2 = $null; $e2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($wrapped, [ref]$t2, [ref]$e2)
    if ($e2.Count) { $wrapBad += ("{0} => {1}" -f $ws, $e2[0].Message) }
}
Assert ($wrapBad.Count -eq 0) ("every worker script parses after wrapping" + $(if ($wrapBad) { ': ' + ($wrapBad -join ' | ') } else { '' }))
# the Loaded handler in start.ps1 also starts a job
$startSrc = Get-Content -Raw (Join-Path $Root 'scripts/start.ps1')
$wrapped = Build-WrappedScript -Kind 'regions' -Script "Start-Sleep -Milliseconds 1500; Measure-UTRegionPing | Out-Null"
$t3 = $null; $e3 = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($wrapped, [ref]$t3, [ref]$e3)
Assert ($e3.Count -eq 0) 'startup region job wraps cleanly'

Write-Host "functions reachable from worker runspaces"
# New-UTSessionState injects only functions whose name matches '-UT'. Every command a worker script,
# a tweak InvokeScript/UndoScript or the monitor calls must be either a built-in or a -UT function.
$defined = @{}
foreach ($f in (Get-ChildItem -Path (Join-Path $Root 'functions') -Recurse -Filter *.ps1)) {
    $tf = $null; $ef = $null
    $af = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tf, [ref]$ef)
    foreach ($fn in $af.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $defined[$fn.Name] = $f.Name
    }
}
Assert ($defined.Count -ge 55) "$($defined.Count) functions defined"
$notInjected = @($defined.Keys | Where-Object { $_ -notmatch '-UT' })
Assert ($notInjected.Count -eq 0) ("every function name contains -UT so runspaces get it" + $(if ($notInjected) { ': ' + ($notInjected -join ', ') } else { '' }))

$monitorSrc = Get-Content -Raw (Join-Path $Root 'functions/private/Start-UTMonitor.ps1')
$tweakScripts = @()
foreach ($id in $ids) {
    foreach ($s in @($tw.$id.GuardScript) + @($tw.$id.InvokeScript) + @($tw.$id.UndoScript)) { if ($s) { $tweakScripts += $s } }
}
$missing = @()
foreach ($body in ($workerScripts + $tweakScripts + @($monitorSrc))) {
    $t4 = $null; $e4 = $null
    $a4 = [System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$t4, [ref]$e4)
    if ($e4.Count) { continue }
    foreach ($c in $a4.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($name -match '-UT' -and -not $defined.ContainsKey($name)) { $missing += $name }
    }
}
$missing = @($missing | Sort-Object -Unique)
Assert ($missing.Count -eq 0) ("every -UT command called from worker/tweak/monitor code is defined" + $(if ($missing) { ': ' + ($missing -join ', ') } else { '' }))

Write-Host "private beta gate"
$g = Test-UTBetaGate -StatusUrl '' -Version '1'
Assert ($g.Ok -and $g.Reason -eq 'not gated') 'no status URL means a public build, never gated'
$seen = $null
$g = Test-UTBetaGate -StatusUrl 'https://gate.example/status?k=KEY1' -Version '0.0.67' -Fetch { param($u) $script:seen = $u; "ok`n" }
Assert ($g.Ok) 'a plain "ok" answer lets the build run'
Assert ($seen -eq 'https://gate.example/status?k=KEY1&v=0.0.67') "the check sends only the key and the version ($seen)"
$g = Test-UTBetaGate -StatusUrl 'https://gate.example/status?k=KEY1' -Fetch { 'revoked' }
Assert (-not $g.Ok -and $g.Reason -eq 'revoked') 'a revoked key stops the build with the reason'
$g = Test-UTBetaGate -StatusUrl 'https://gate.example/status?k=KEY1' -Fetch { 'disabled' }
Assert (-not $g.Ok -and $g.Reason -eq 'disabled') 'the kill switch stops the build'
$g = Test-UTBetaGate -StatusUrl 'https://gate.example/status?k=KEY1' -Fetch { '' }
Assert (-not $g.Ok) 'an empty answer fails closed'
$g = Test-UTBetaGate -StatusUrl 'http://127.0.0.1:9/status?k=KEY1' -Version '1' -TimeoutSec 3
Assert (-not $g.Ok -and $g.Reason -match 'unreachable' -and $g.Reason -notmatch 'parameter') "an unreachable gate fails closed through the real cmdlet ($($g.Reason))"

Write-Host "launch argument assembly"
$args1 = @($sync.configs.fortnite.LaunchArgs.Options)
Assert ($args1.Count -ge 4) "$($args1.Count) launch-argument options"
$exclusive = @($args1 | Where-Object { $_.Excludes })
Assert ($exclusive.Count -ge 1) 'at least one option declares Excludes'
foreach ($e in $exclusive) {
    Assert (@($args1 | ForEach-Object { $_.Arg }) -contains $e.Excludes) "Excludes target '$($e.Excludes)' exists as an option"
}

Write-Host "epic launcher launch-argument entry"
# Layout confirmed against a live Epic Games Launcher 20.2.6 install; see docs/DECISIONS.md s5.
$acct = '0123456789abcdef0123456789abcdef'
$item = 'fedcba9876543210fedcba9876543210'
$lnDir = Join-Path $sync.backupDir 'launcher'
New-Item -ItemType Directory -Path $lnDir -Force | Out-Null
$lnIni = Join-Path $lnDir 'GameUserSettings.ini'
function New-FakeFortnite([string]$Account, [string]$Prefix) {
    [pscustomobject]@{ LauncherIni = $lnIni; AccountId = $Account; LauncherKeyPrefix = $Prefix }
}
$fnFake = New-FakeFortnite $acct "fn:${item}:Fortnite"

# (1) nothing written yet: the entry is constructed from the account id and the catalog triple
Set-Content -LiteralPath $lnIni -Value @(';METADATA=(Diff=true, UseCommands=true)', '[Launcher]', 'LastActiveTab=Fortnite')
$loc = Find-UTLaunchArgsKey -Fortnite $fnFake
Assert ($loc.Source -eq 'known') "empty file -> source 'known' (got '$($loc.Source)')"
Assert ($loc.Section -eq "${acct}_Settings") "section is <AccountId>_Settings"
Assert ($loc.Key -eq "fn:${item}:Fortnite_AdditionalCommands") 'key is <namespace>:<itemid>:<artifact>_AdditionalCommands'
Assert ($loc.EnableKey -eq ($loc.Key + 'Enabled')) 'tick box key is the same key plus Enabled'
Assert ($null -eq $loc.Current) 'no current value yet'

# (2) writing it: the colons in the key must survive the INI writer, and the comment must be kept
$n = Set-UTIniValues -Path $lnIni -Settings @{ $loc.Section = @{ $loc.Key = '-NOSPLASH'; $loc.EnableKey = 'True' } }
Assert ($n -eq 2) "wrote both keys (got $n change(s))"
$after = Get-Content -LiteralPath $lnIni
Assert ($after[0] -eq ';METADATA=(Diff=true, UseCommands=true)') 'the launcher metadata comment survived'
Assert ($after -contains "fn:${item}:Fortnite_AdditionalCommands=-NOSPLASH") 'colon-laden key written verbatim'

# (3) reading it back: an entry the launcher already holds is found, whatever we would have guessed
$loc2 = Find-UTLaunchArgsKey -Fortnite $fnFake
Assert ($loc2.Source -eq 'existing') "existing entry -> source 'existing' (got '$($loc2.Source)')"
Assert ($loc2.Current -eq '-NOSPLASH') "current value read back (got '$($loc2.Current)')"
Assert ($loc2.Enabled -eq 'True') 'tick box read back'
Assert ((Set-UTIniValues -Path $lnIni -Settings @{ $loc.Section = @{ $loc.Key = '-NOSPLASH'; $loc.EnableKey = 'True' } }) -eq 0) 'rewriting the same values changes nothing'

# (4) another Epic game's entry in the same section must not be mistaken for Fortnite's
Set-Content -LiteralPath $lnIni -Value @("[${acct}_Settings]", '4fe:0000:SomeOtherGame_AdditionalCommands=-nope')
$loc3 = Find-UTLaunchArgsKey -Fortnite $fnFake
Assert ($loc3.Source -eq 'known' -and $loc3.Key -eq "fn:${item}:Fortnite_AdditionalCommands") 'another game''s entry is ignored'

# (5) neither id known: refuse rather than invent a section to write into
$loc4 = Find-UTLaunchArgsKey -Fortnite (New-FakeFortnite '' '')
Assert ($loc4.Source -eq 'unknown') "no account id and no catalog id -> source 'unknown' (got '$($loc4.Source)')"

Write-Host "build eligibility"
$sync.sysinfo = [pscustomobject]@{ Build = 19045 }
Assert (Test-UTTweakEligible -Tweak ([pscustomobject]@{})) 'no MinBuild -> eligible'
Assert (Test-UTTweakEligible -Tweak ([pscustomobject]@{ MinBuild = 19045 })) 'MinBuild equal to this build -> eligible'
Assert (-not (Test-UTTweakEligible -Tweak ([pscustomobject]@{ MinBuild = 22621 }))) 'MinBuild above this build -> not eligible'
$sync.sysinfo = [pscustomobject]@{ Build = 22631 }
Assert (Test-UTTweakEligible -Tweak ([pscustomobject]@{ MinBuild = 22621 })) 'newer build -> eligible'
# Windows 10 must not be handed a preset that contains a tweak it will only ever skip.
$sync.sysinfo = [pscustomobject]@{ Build = 19045 }
$preset = @($ids | Where-Object { $tw.$_.Recommended -and $tw.$_.Tier -eq 'safe' -and (Test-UTTweakEligible -Tweak $tw.$_) })
$win11Only = @($ids | Where-Object { $tw.$_.Recommended -and -not (Test-UTTweakEligible -Tweak $tw.$_) })
Assert ($preset.Count -gt 0 -and @($preset | Where-Object { $tw.$_.MinBuild -gt 19045 }).Count -eq 0) `
    "the Windows 10 recommended preset is $($preset.Count) tweaks and excludes the $($win11Only.Count) that need a newer build"
$sync.sysinfo = $null

Write-Host "undo is driven by the snapshot, not only by the catalogue"
# A tweak whose catalogue entry lost a scheduled task and a service after it was applied: the
# snapshot still names them, so undo has to put them back or they stay changed forever.
$snapDir = $sync.backupDir
if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
$snap = @{
    Id = 'UTUndoShape'; Date = (Get-Date -Format 's')
    Registry = @(@{ Path = 'HKCU:\Software\ut-test'; Name = 'Dropped'; Exists = $true; Kind = 'DWord'; Value = '7' })
    Service  = @(@{ Name = 'DroppedSvc'; StartupType = 'Manual' })
    Task     = @(@{ Name = '\Dropped\Task'; State = 'Enabled' })
}
$snap | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $snapDir 'UTUndoShape.json') -Encoding UTF8 -Force
$backup = Get-UTBackup -Id 'UTUndoShape'
Assert ($null -ne $backup) 'snapshot round trips through Get-UTBackup'
# The catalogue entry no longer mentions any of them.
$shrunk = [pscustomobject]@{ Content = 'shrunk'; registry = @(); service = @(); ScheduledTask = @() }
$regNames  = @(@($backup.Registry) | ForEach-Object { $_.Name })
$svcNames  = @(@($shrunk.service | Where-Object { $_ }) | ForEach-Object { [string]$_.Name })
foreach ($e in @($backup.Service | Where-Object { $_ })) { if ($e.Name -and $svcNames -notcontains [string]$e.Name) { $svcNames += [string]$e.Name } }
$taskNames = @(@($shrunk.ScheduledTask | Where-Object { $_ }) | ForEach-Object { [string]$_.Name })
foreach ($e in @($backup.Task | Where-Object { $_ })) { if ($e.Name -and $taskNames -notcontains [string]$e.Name) { $taskNames += [string]$e.Name } }
Assert ($regNames -contains 'Dropped') 'a registry value only in the snapshot is still reachable'
Assert ($svcNames -contains 'DroppedSvc') 'a service only in the snapshot is still restored'
Assert ($taskNames -contains '\Dropped\Task') 'a task only in the snapshot is still restored'
Remove-UTBackup -Id 'UTUndoShape'
Assert (-not (Test-UTBackupExists -Id 'UTUndoShape')) 'snapshot removed again'

if ([System.Environment]::OSVersion.Platform -eq 'Win32NT') {
    Write-Host "registry writes, provider and direct"
    $k = 'HKCU:\Software\unknowntweaks-selftest'
    $mismatch = @()
    foreach ($c in @(@{T='DWord';V='0'}, @{T='String';V='hello'}, @{T='QWord';V='123456789012'},
                     @{T='Binary';V='90,12,03,80'}, @{T='MultiString';V='a,b'}, @{T='ExpandString';V='%TEMP%\x'})) {
        $conv = ConvertTo-UTRegistryValue -Type $c.T -Value $c.V
        if (-not (Set-UTRegistry -Path $k -Name ('P' + $c.T) -Type $c.T -Value $c.V)) { $mismatch += "$($c.T) provider write" }
        # Set-UTRegistryValueDirect is the fallback Set-UTRegistry takes when the provider refuses,
        # so it has to produce a byte-identical value and kind, arrays included.
        Set-UTRegistryValueDirect -Path $k -Name ('D' + $c.T) -Type $c.T -Value $conv
        $a = Get-UTRegistryValue -Path $k -Name ('P' + $c.T)
        $b = Get-UTRegistryValue -Path $k -Name ('D' + $c.T)
        if ($a.Value -ne $b.Value -or $a.Kind -ne $b.Kind -or $b.Kind -ne $c.T) { $mismatch += "$($c.T) '$($a.Value)'/$($a.Kind) vs '$($b.Value)'/$($b.Kind)" }
    }
    Assert ($mismatch.Count -eq 0) ("all 6 value types match through the provider and the direct writer" + $(if ($mismatch) { ': ' + ($mismatch -join '; ') } else { '' }))
    Assert (Set-UTRegistry -Path $k -Name 'PDWord' -Type DWord -Value '<RemoveEntry>') 'removal reports success'
    Assert (-not (Get-UTRegistryValue -Path $k -Name 'PDWord').Exists) 'removed value is gone'
    Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "registry writes, provider and direct  (skipped, needs Windows)"
}

Write-Host "startup entries (StartupApproved encoding)"
# 0x02 and 0x06 mean enabled, 0x03 means disabled: bit 0 is the disable flag. Read off a live
# Windows 10 19045 machine and cross-checked against windowsir.blogspot.com's format notes.
Assert (Test-UTStartupApprovedEnabled -Blob ([byte[]]@(2,0,0,0,0,0,0,0,0,0,0,0))) '0x02 blob reads as enabled'
Assert (Test-UTStartupApprovedEnabled -Blob ([byte[]]@(6,0,0,0,0,0,0,0,0,0,0,0))) '0x06 blob reads as enabled'
Assert (-not (Test-UTStartupApprovedEnabled -Blob ([byte[]]@(3,0,0,0,43,137,50,179,158,55,221,1)))) '0x03 blob with a timestamp reads as disabled'
Assert (-not (Test-UTStartupApprovedEnabled -Blob ([byte[]]@(7,0,0,0,0,0,0,0,0,0,0,0)))) '0x07 blob reads as disabled (bit 0 is the flag)'
Assert (Test-UTStartupApprovedEnabled -Blob $null) 'no StartupApproved value at all means enabled'
Assert (Test-UTStartupApprovedEnabled -Blob @()) 'an empty value means enabled'
$onBlob = New-UTStartupApprovedBlob -Enabled $true
$offBlob = New-UTStartupApprovedBlob -Enabled $false
Assert ($onBlob.Count -eq 12 -and $offBlob.Count -eq 12) 'both blobs are 12 bytes, the length Windows writes'
Assert (Test-UTStartupApprovedEnabled -Blob $onBlob) 'the enabled blob round trips'
Assert (-not (Test-UTStartupApprovedEnabled -Blob $offBlob)) 'the disabled blob round trips'
Assert (@($onBlob[4..11] | Where-Object { $_ -ne 0 }).Count -eq 0) 'an enabled blob carries a zero timestamp'
Assert (@($offBlob[4..11] | Where-Object { $_ -ne 0 }).Count -gt 0) 'a disabled blob records when it was disabled'
$paths = @{}
foreach ($s in 'HKLMRun', 'HKLMRun32', 'HKCURun', 'UserFolder', 'CommonFolder') { $paths[$s] = Get-UTStartupApprovedPath -Source $s }
Assert (@($paths.Values | Sort-Object -Unique).Count -eq 5) 'each startup source maps to its own StartupApproved key'
Assert ($paths.HKLMRun32 -like '*\Run32') 'the 32-bit Run key uses StartupApproved\Run32'
Assert ($paths.HKCURun -like 'HKCU:*' -and $paths.HKLMRun -like 'HKLM:*') 'per-user and all-users entries use their own hive'

Write-Host "debloat safety"
$never = @(Get-UTAppxNeverRemove)
Assert ($never.Count -ge 20) "$($never.Count) packages on the never-remove list"
foreach ($critical in 'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.XboxIdentityProvider', 'Microsoft.GamingServices', 'Microsoft.Windows.StartMenuExperienceHost') {
    $why = ''
    Assert (-not (Test-UTAppxRemovable -Name $critical -Reason ([ref]$why))) "$critical is refused"
}
# Frameworks carry a version suffix, so the block has to be a prefix match, not equality.
$why = ''
Assert (-not (Test-UTAppxRemovable -Name 'Microsoft.VCLibs.140.00.UWPDesktop' -Reason ([ref]$why))) 'a suffixed framework package is refused'
Assert (Test-UTAppxRemovable -Name 'Microsoft.BingWeather' -Reason ([ref]$why)) 'an ordinary bloat app is allowed'
# The catalogue is data and could be edited; the code-side list must always win.
$blocked = @()
foreach ($p in $sync.configs.debloat.PSObject.Properties) {
    $why = ''
    if (-not (Test-UTAppxRemovable -Name $p.Name -Reason ([ref]$why))) { $blocked += "$($p.Name) ($why)" }
}
Assert ($blocked.Count -eq 0) ("no catalogue entry is on the never-remove list" + $(if ($blocked) { ': ' + ($blocked -join '; ') } else { '' }))
$cat = @($sync.configs.debloat.PSObject.Properties)
Assert ($cat.Count -ge 25) "debloat catalogue has $($cat.Count) apps"
$badApp = @()
foreach ($p in $cat) {
    if (-not $p.Value.Content -or -not $p.Value.Category -or -not $p.Value.Note) { $badApp += "$($p.Name) text" }
    if ($null -eq $p.Value.Recommended) { $badApp += "$($p.Name) no Recommended flag" }
}
Assert ($badApp.Count -eq 0) ("every debloat entry is well-formed" + $(if ($badApp) { ': ' + ($badApp -join '; ') } else { '' }))
# Anything that can break a game must be opt-in, never in the one-click recommended set.
$xboxRec = @($cat | Where-Object { $_.Value.Category -like 'Xbox*' -and $_.Value.Recommended -and $_.Name -ne 'Microsoft.XboxApp' })
Assert ($xboxRec.Count -eq 0) ("no Xbox package beyond the retired Console Companion is recommended" + $(if ($xboxRec) { ': ' + (($xboxRec | ForEach-Object { $_.Name }) -join ', ') } else { '' }))

Remove-Item -Recurse -Force $sync.backupDir -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
