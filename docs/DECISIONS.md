# unknowntweaks - research-backed design decisions

Compiled 2026-09-05. Every tweak that ships in `config/tweaks.json` traces back to a line here. Confidence: **H** = primary source
(Microsoft Learn, Epic/UE source, vendor docs), **M** = several independent community sources,
**L** = single source / inference.

## 1. Product rules

1. Three tiers, hard-separated in the UI: **Safe** (recommended preset), **Optional** (helps some
   setups, no real risk), **Risky** (real upside for some, real cost; explicit consent, never in
   a preset). A fourth list, **Excluded**, is documented in README so people know why the
   "regedit pack" favourites are not here.
2. Every tweak is reversible: registry originals are snapshotted per tweak before apply
   (`%ProgramData%\unknowntweaks\backup\<id>.json`), and JSON `OriginalValue` is the fallback for a
   `-Force` undo from the console. With no snapshot the UI refuses rather than write its own idea of
   the Windows default onto a machine it may never have touched. Restore point is offered before the
   first apply.
3. Undo is driven by the snapshot, not by the catalogue. Every registry value, service and task the
   snapshot names is restored even when the tweak that wrote it no longer lists it, so dropping an
   entry from `config/tweaks.json` cannot strand a machine that already applied it.
4. A tweak whose `MinBuild` this Windows does not meet is a **skip**, not a failure: the label says
   which build it needs and "Select recommended" leaves it out, so the preset never ends in red on
   Windows 10. (Found 2026-09-05: `WindowedGamesOpt` needs 22621 and was reported as an error on
   every Windows 10 run.)
5. Nothing touches anti-cheat, Defender, Windows Update service, IPv6, Spectre mitigations,
   pagefile, HPET, `useplatformclock`, MMCSS `Tasks\Games`, `Win32PrioritySeparation`,
   `SystemResponsiveness=0`, Nagle keys, XP-era Tcpip keys. The README table gives the reason for each.
6. No process injection, no overlays, no DLLs. Only registry, services, scheduled tasks,
   powercfg, bcdedit (Risky, with BitLocker suspend), INI files that Epic's own support flow
   already tells users to touch, and winget.
7. ASCII-only sources; Windows PowerShell 5.1 is the runtime (WPF + Checkpoint-Computer).
8. (2026-09-06) The interface explains items, not itself. Every list is one line per item; the
   hover card carries the description and, for tweaks, a "why it works" section drawn from the
   `Evidence` field in `config/tweaks.json`, which `Test-Logic` requires on every tweak. The
   paragraphs that used to explain the tool's own design (tier blurbs, "excluded on purpose", the
   placebo argument list, the startup and debloat notes, the network essays) were removed; the
   mechanics that still matter at the moment of action sit on that action's button as a tooltip.
   The research stays in this file and in the README table.

## 2. Safe tier (default preset) - exact values

| Id | Change | Undo (Windows default) | Conf |
|---|---|---|---|
| GameDVR | `HKCU\System\GameConfigStore` `GameDVR_Enabled`=0 DWord; `HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR` `AppCaptureEnabled`=0; `HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR` `AllowGameDVR`=0 | 1 / 1 / remove | H |
| MouseAccel | `HKCU\Control Panel\Mouse` `MouseSpeed`="0", `MouseThreshold1`="0", `MouseThreshold2`="0" (**REG_SZ**, WinUtil's DWord is a bug); sign-out to apply | "1","6","10" | H |
| AccessibilityKeys | `HKCU\Control Panel\Accessibility\StickyKeys` `Flags`="506"; `ToggleKeys` `Flags`="58"; `Keyboard Response` `Flags`="122" (REG_SZ) | "510","62","126" | H |
| EdgeBackground | `HKLM\SOFTWARE\Policies\Microsoft\Edge` `StartupBoostEnabled`=0, `BackgroundModeEnabled`=0 | remove | H |
| Widgets | `HKLM\SOFTWARE\Policies\Microsoft\Dsh` `AllowNewsAndInterests`=0 (Win11 widgets); `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds` `EnableFeeds`=0 (Win10 news and interests; ADMX Feeds.admx, policy EnableFeeds, read off C:\Windows\PolicyDefinitions 2026-09-05); `HKCU\...\Explorer\Advanced` `TaskbarDa`=0 (Win11 taskbar button) | remove / remove / remove | H |
| SearchCopilotRecall | `HKCU\Software\Policies\Microsoft\Windows\Explorer` `DisableSearchBoxSuggestions`=1; `HKCU\Software\Microsoft\Windows\CurrentVersion\Search` `BingSearchEnabled`=0; `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` `DisableAIDataAnalysis`=1 (24H2 keys; `TurnOffWindowsCopilot` is deprecated) | remove | H |
| Telemetry | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection` `AllowTelemetry`=1 (0 only honoured on Enterprise); `HKCU\...\AdvertisingInfo` `Enabled`=0; `HKCU\...\Privacy` `TailoredExperiencesWithDiagnosticDataEnabled`=0; `HKCU\Software\Microsoft\Siuf\Rules` `NumberOfSIUFInPeriod`=0; `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting` `Disabled`=1; service `DiagTrack` Disabled (orig Automatic); tasks: Compatibility Appraiser, ProgramDataUpdater, Consolidator, UsbCeip, DiskDiagnosticDataCollector, QueueReporting, DmClient, DmClientOnScenarioDownload, MapsUpdateTask | remove / 1 / 1 / remove / remove / Automatic / enable | H/M |
| Suggestions | `HKCU\...\ContentDeliveryManager` `SubscribedContent-338388Enabled`=0, `-338389Enabled`=0, `-353698Enabled`=0, `SilentInstalledAppsEnabled`=0, `SystemPaneSuggestionsEnabled`=0; `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent` `DisableWindowsConsumerFeatures`=1 | 1 / remove | M |
| ActivityHistory | `HKLM\SOFTWARE\Policies\Microsoft\Windows\System` `EnableActivityFeed`=**0**, `PublishUserActivities`=0, `UploadUserActivities`=0 (WinUtil writes 1 for the first - bug) | remove | H |
| DeliveryOptimization | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization` `DODownloadMode`=0 (never 100) | remove | H |
| WUDrivers | `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` `ExcludeWUDriversInQualityUpdate`=1; `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching` `SearchOrderConfig`=0 | remove / 1 | H |
| FastStartupOff | `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power` `HiberbootEnabled`=0 (keeps hibernation, true cold boot) | 1 | M |
| ExplorerQoL | `HKCU\...\Explorer\Advanced` `HideFileExt`=0; `...\Advanced\TaskbarDeveloperSettings` `TaskbarEndTask`=1 | 1 / remove | M |
| WindowedGamesOpt | `HKCU\Software\Microsoft\DirectX\UserGpuPreferences` `DirectXUserGlobalSettings` REG_SZ - ensure token `SwapEffectUpgradeEnable=1;` (merge into existing `;` list, do not clobber) | remove token | H(MS text)/M(key) |
| UsbPcieNoSleep | `powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0`; `... 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0`; `powercfg /setactive SCHEME_CURRENT` (desktop; on laptops apply AC only) | index 1 / 1 | H |
| TempFiles | remove `%TEMP%\*`, `%SystemRoot%\Temp\*` (SilentlyContinue) | n/a | H |
| StartupDelay | `HKCU\...\Explorer\Serialize` `StartupDelayInMSec`=0 | remove | M |

## 3. Optional tier

| Id | Change | Notes | Conf |
|---|---|---|---|
| HAGS | `HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` `HwSchMode`=2 (undo: remove) reboot | Required for DLSS FG; safe on GTX10+/RX5000+; older GPUs skip | H |
| GameModeOff | `HKCU\Software\Microsoft\GameBar` `AutoGameModeEnabled`=0 (undo 1) | try if stutter; default ON is fine | M |
| GameBarPopups | `HKCU\Software\Microsoft\GameBar` `ShowStartupPanel`=0, `UseNexusForGameBarEnabled`=0 | QoL | M |
| FSOGlobalOff | `HKCU\System\GameConfigStore` `GameDVR_FSEBehaviorMode`=2, `GameDVR_HonorUserFSEBehaviorMode`=1, `GameDVR_DXGIHonorFSEWindowsCompatible`=1, `GameDVR_EFSEFeatureFlags`=0 (undo remove) | only for legacy DX9/11 titles; loses Auto HDR/VRR paths | M |
| PowerThrottlingOff | `HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling` `PowerThrottlingOff`=1 | laptops on AC; no desktop effect | H |
| UltimatePerf | `powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61`, parse the GUID out of the joined output (`-match` on an array never sets `$Matches`), `/setactive`; undo restores the recorded previous scheme, falling back to the `SCHEME_BALANCED` alias, and deletes the created scheme only once it is no longer active | desktop only; negligible on HWP/CPPC CPUs | H |
| HibernateOff | `powercfg /hibernate off` (undo on); flag key is `HKLM\SYSTEM\CurrentControlSet\Control\Power` `HibernateEnabled` (WinUtil's Session Manager path is wrong) - do not write it, powercfg does | desktop only | H |
| VisualEffects | WinUtil Display set: `DragFullWindows`="0", `MenuShowDelay`="200", `MinAnimate`="0", `KeyboardDelay`=0, `ListviewAlphaSelect`=0, `ListviewShadow`=0, `TaskbarAnimations`=0, `VisualFXSetting`=3, `EnableAeroPeek`=0, `EnableTransparency`=0 + `UserPreferencesMask` binary 90,12,03,80,10,00,00,00 | desktop snappiness only | M |
| WUDefer | `DeferFeatureUpdates`=1,`DeferFeatureUpdatesPeriodInDays`=365,`BranchReadinessLevel`=16 | stability; no effect with AllowTelemetry=0 | H |
| NicPowerSaving | `Disable-NetAdapterPowerManagement -Name <physical up adapters>` ; `*EEE`=0 via `Set-NetAdapterAdvancedProperty` if keyword exists | real on laptops/USB NICs; undo Enable-/Reset- | H |
| BackgroundApps | `HKCU\...\BackgroundAccessApplications` `GlobalUserDisabled`=1 (undo 0) | Win11 mostly per-app anyway | M |
| LocationOff | ConsentStore location `Value`="Deny" (HKLM+HKCU), `lfsvc` Disabled (orig Manual) | breaks Find-my-device/maps | M |
| TeredoOff | `netsh interface teredo set state disabled` (undo default) | breaks Xbox app party chat - say so | M |
| SearchIndexOff | service `WSearch` Disabled (orig Automatic delayed) | HDD stutter only; breaks Start search of files | M |

## 4. Risky tier (each with its own consent line and undo)

| Id | Change | Cost | Conf |
|---|---|---|---|
| HVCIOff | `HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity` `Enabled`=0; undo `Enabled`=1 + `WasEnabledBy`=2; reboot. Never touch `Locked`/`Mandatory`. Skip if Credential Guard running. | -4..-8% FPS when ON (Tom's HW); security downgrade; Vanguard allows VBS off (VAN9005), EAC requires HVCI only on Arm/Insider | H |
| DynamicTickOff | `bcdedit /set disabledynamictick yes`; undo `/deletevalue`; reboot. **Prereq:** if BitLocker/Device Encryption on C:, `manage-bde -protectors -disable C: -RebootCount 1` first and tell the user. | MS: debugging only; no measured gain; idle power | H |
| TimerResGlobal | `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel` `GlobalTimerResolutionRequests`=1 (undo remove) - key only; we do not ship a resolution tool. **Windows 11 / Server 2022+ only** (`MinBuild` 22000): inert on Windows 10. | valleyofdoom/TimerResolution: "for debugging purposes"; power | M |
| MSIModeGPU | For each `Enum\PCI\*` display device where `MSISupported` is absent or 0: record, set 1; undo restores record. Skip if already 1 (modern drivers). | boot hang if unsupported; per-device opt-in | H |
| GamePriorityIFEO | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FortniteClient-Win64-Shipping.exe\PerfOptions` `CpuPriorityClass`=6 (Above Normal). Undo delete key. Never High/Realtime, never `Debugger`. | applies through EAC; no ban evidence | M |
| CoreParkingOff | `powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100` (undo: re-import exported .pow) | breaks X3D dual-CCD / Intel hybrid parking; auto-skip when CPU name matches X3D | H |
| SysMainOff | service `SysMain` Disabled (orig Automatic) | no gain on SSD; slower launches | M |

## 5. Fortnite integration

* Game config: `%LOCALAPPDATA%\FortniteGame\Saved\Config\WindowsClient\GameUserSettings.ini`.
  Key-level merge only (never replace the file), preserve BOM/CRLF, clear+restore read-only,
  back up first, refuse while `FortniteClient-Win64-Shipping`/`FortniteLauncher` run. (H)
* Rendering: 2026 client offers Performance (`[D3DRHIPreference] PreferredRHI=dx12`,
  `PreferredFeatureLevel=es31`, `[PerformanceMode] MeshQuality=0`) or DX12 (`sm6`). DX11 was
  removed from the **Rendering Mode menu** ~2026-04, but the D3D11 RHI still ships and `-d3d11`
  on the command line still forces it - corrected 2026-09-06, see s13. On D3D11 the client now
  caps the feature level at ES3_1, so `-d3d11` is the legacy DX11 Performance Mode renderer; the
  DX11 SM5 path is the part that is actually gone. (H)
* Competitive settings shipped as `config/fortnite.json` with three profiles:
  `MaxFPS` (performance mode, everything low), `Balanced` (DX12, low shadows/effects, TSR),
  `KeepVisuals` (only latency keys: Reflex On+Boost, VSync off, motion blur off, FPS cap). Every
  key is one the in-game menu exposes (risk "none"). Hidden keys (`bShowGrass`,
  `FrontendFrameRateLimit`) are separate opt-ins labelled "hidden key".
* Engine.ini / Scalability.ini / Input.ini: **not written, ever** (blocked since v1.7.2; cvar
  "fog/foliage removal" is exactly what FNCS rule 8.2.1 bans). (H)
* Shader cache clear (NVIDIA `%LOCALAPPDATA%\NVIDIA\DXCache`, `GLCache`,
  `%PROGRAMDATA%\NVIDIA Corporation\NV_Cache`; AMD `%LOCALAPPDATA%\AMD\DxCache`, `DxcCache`,
  `GLCache`, `VkCache`) offered as a stutter fix with game+launcher closed. (M)
* Launch options: written into the Epic launcher's own
  `%LOCALAPPDATA%\EpicGamesLauncher\Saved\Config\WindowsEditor\GameUserSettings.ini` (or
  `Windows\` if that is the one present, newest wins). Launcher must be closed first
  (`EpicGamesLauncher`, `EpicWebHelper`, `EpicOnlineServicesUserHelper`), backup, write, restart
  via `com.epicgames.launcher://apps/fn%3A4fe75bbc5a674f4f9b356b5c90567da5%3AFortnite?action=launch&silent=true`.
  **Section and key confirmed 2026-09-05** against a live Epic Games Launcher 20.2.6 install:

  ```ini
  [<AccountId>_Settings]
  fn:<CatalogItemId>:Fortnite_AdditionalCommandsEnabled=True
  fn:<CatalogItemId>:Fortnite_AdditionalCommands=-NOSPLASH
  ```

  The section is `<AccountId>_Settings`, where AccountId is the 32-hex id from
  `HKCU\Software\Epic Games\Unreal Engine\Identifiers` `AccountId` (fallback: the `_Settings` or
  `_General` section already in the file). The key is the same `namespace:catalogItemId:artifact`
  triple the launcher URL above uses - `NamespaceId`/`ItemId`/`ArtifactId` from
  `LauncherInstalled.dat`, or `CatalogNamespace`/`CatalogItemId`/`AppName` from the manifest -
  suffixed `_AdditionalCommands`; the tick box beside the text field is that key plus `Enabled`.
  Writing the text without the boolean makes the launcher ignore it. An entry the launcher has
  already written wins over the constructed name (matched to this game so a second Epic game's
  entry is not hijacked); if neither id can be read the writer refuses rather than inventing a
  section, and the "probe" that diffs the file after the user types a marker in the launcher UI
  stays available for launcher builds that store it elsewhere. (H)
* Args that still do something (UE 5.3 source): `-NOSPLASH` (cosmetic), `-FeatureLevelES31`
  (Performance mode), `-d3d12 -sm6` (DX12), `-d3d11` (legacy DX11 Performance Mode, added
  2026-09-06, s13), `-nosound`, `-FULLSCREEN/-WINDOWED/-ResX/-ResY`.
  **Placebo/harmful, not offered:** `-USEALLAVAILABLECORES` (only compressed-archive threads),
  `-lanplay`, `-limitclientticks` (server-only), `-PREFERREDPROCESSOR` (does not exist),
  `-high`, `-malloc=*` (compiled out), `-NOVERIFYGC`, `-NOTEXTURESTREAMING` (VRAM crashes; Epic
  has a support article), `-onethread`/`-norenderthread`. Default recommendation:
  `-NOSPLASH` plus the rendering flag matching the chosen profile. (H)
* Install path: `%ProgramData%\Epic\UnrealEngineLauncher\LauncherInstalled.dat`
  `InstallationList[].AppName == 'Fortnite'` -> `InstallLocation`; manifests
  `%ProgramData%\Epic\EpicGamesLauncher\Data\Manifests\*.item`. Game process
  `FortniteClient-Win64-Shipping`. (H)

## 6. Network

* Region ping targets (all AWS, verified 2026-09-05): `ping-nae` (Ohio+Virginia), `ping-nac`
  (Dallas Local Zone), `ping-naw` (Oregon+N.California), `ping-eu` (Paris/Frankfurt/London),
  `ping-oce` (Sydney), `ping-br` (Sao Paulo), `ping-asia` (Tokyo), `ping-me` (Bahrain; ICMP
  may not answer) - all `.ds.on.epicgames.com`, IPv4 only. Multi-region names: resolve and
  ping each A record in "detailed" mode. (H)
* Valorant: no stable endpoint; Riot Direct drops ICMP; anycast GA IPs mislead. Show in-game
  RTT advice only. (H)
* ExitLag-style routing needs relay infrastructure; impossible locally. UI text says so and
  offers: manual region choice, wired, router SQM, WARP A/B test. DNS never changes in-match
  ping. (H)
* DNS benchmark: raw UDP A-query via `UdpClient` with `ReceiveTimeout`, cache-busting label,
  median of 5. Set via `Set-DnsClientServerAddress -InterfaceIndex`, reset with
  `-ResetServerAddresses`. Providers: Cloudflare, Google, Quad9 (+9.9.9.11 ECS), OpenDNS,
  AdGuard, Control D. (H)
* Wi-Fi detection: `Get-NetAdapter` `PhysicalMediaType -eq 'Native 802.11'`. (H)
* Repair tools: `netsh winsock reset`, `netsh int ip reset`, `ipconfig /flushdns` (reboot). (H)

## 7. Live monitor

* PDH via P/Invoke `PdhAddEnglishCounterW` (language-neutral). Paths:
  `\Processor Information(_Total)\% Processor Utility` (cap 100; fallback `% Processor Time`),
  `\PhysicalDisk(_Total)\% Idle Time` (active = 100-idle), `\GPU Engine(*)\Utilization Percentage`
  (group by luid+engine, sum over pids, headline = max engine), `\GPU Adapter Memory(*)\Dedicated Usage`.
  RAM via `GlobalMemoryStatusEx` (`dwMemoryLoad`). Network via
  `NetworkInterface.GetAllNetworkInterfaces()` deltas, filtered to Up + non-virtual. First rate
  sample discarded. WMI `Win32_PerfFormattedData_*` fallback if Add-Type fails. (H)
* Foreground game: `GetForegroundWindow` + `GetWindowThreadProcessId` + rect vs screen; shell
  blacklist; known-game list. (H)
* Sampler runs in a background runspace writing to `$sync`; UI `DispatcherTimer` polls; log
  lines through a `ConcurrentQueue`. Never touch WPF from the sampler.

## 8. Anti-cheat and policy notes surfaced in the UI

* EAC/Epic: no doc treats registry/power/priority tweaks as violations; bans come from code
  injected into the game (AMD Anti-Lag+ precedent). We inject nothing.
* Vanguard: blocks vulnerable drivers (old Afterburner/RTSS), requires Exploit Protection
  (VAN9002) - we never disable Exploit Protection; VBS off is allowed (VAN9005 article).
* FNCS 8.2.1: cvar-level visual removal is cheating; we only write in-menu keys.

## 9. Corrections applied after the code review

The review found these in the first cut. They are listed because each one is a trap worth
remembering, not just a diff.

1. **The Balanced power scheme GUID was wrong** (`...ff5e3b6c6b90`; the real one ends `ff5bb260df2e`).
   The code now uses the `SCHEME_BALANCED` alias, which cannot be mistyped.
2. **`-match` against a command's output filters an array and never populates `$Matches`.** Both
   powercfg GUID captures now join the output with `Out-String` first.
3. **`@($null).Count` is 1, not 0**, so the "this tweak has no state to restore" check was always
   false. Every list is filtered before it is counted.
4. **Failed registry, service and task writes were swallowed**, so a tweak that changed nothing was
   reported as applied. The setters now return success and the tweak fails loudly.
5. **Undo without a snapshot forced the tool's assumed defaults onto the machine.** It now refuses
   unless explicitly forced, because those defaults are only ever a guess about someone else's PC.
6. **Re-applying an applied tweak overwrote the recorded original with the tweaked value**, which
   would have made undo restore the tweak. Script state is now first-write-wins and re-apply is
   refused.
7. **A guard that refused a tweak still left it marked as applied**, because the snapshot was taken
   first. Guards moved to a `GuardScript` that runs before anything is recorded or changed.
8. **BitLocker detection failed open**: any error meant "not encrypted", and a `bcdedit` change on a
   drive whose protection was not suspended can demand the 48-digit recovery key at the next boot.
   Unknown is now treated as encrypted, and `bcdedit` refuses to run unless the suspend succeeded.
9. **The elevation path would re-download from the placeholder URL and run it as administrator.**
   A build compiled without a real owner now refuses to relaunch at all.
10. **The Epic launcher was restarted with the tool's administrator token**, so every game started
    from it afterwards would inherit it. It is now started through the shell, unelevated.
11. **`2>&1` on a native command turns stderr into terminating errors** under the workers'
    `Stop` preference, so a tool printing a harmless warning aborted the whole job. All native calls
    go through one helper that relaxes the preference and reports the exit code.
12. **`[Convert]::ToInt32` overflowed** on a power setting of `0xFFFFFFFF` ("never").
13. **The restore-point helper permanently changed the 24-hour throttle key**; it is now put back.
14. **Unreal's config parser keeps the last duplicate of a key**, so rewriting only the first
    occurrence silently did nothing on a hand-edited file.
15. **The Fortnite config backup was taken before the read-only flag was cleared**, so restoring it
    produced a file the game could no longer save to.
16. **`Medal.Medal` does not exist** in the winget repository; the package is `MedalB.V.Medal`.
    All 39 other ids were verified against the manifests. Four missing VALORANT regions were added.
17. **Several tweaks needing a reboot or sign-out carried no flag**, so the tool told the user a
    change was live when it was not.
18. **(2026-09-06) `VendorGpuTasks` undo caught its own failure and logged it**, so an undo that
    re-enabled nothing was counted as a success and the snapshot was deleted - item 4 again, in a
    script instead of a setter. Found by running the apply/undo round trip unelevated on this
    machine, where Task Scheduler answers "Access is denied": the apply was reported failed
    correctly, the undo was not. Undo scripts now collect failures and throw, which the engine
    turns into "1 failed" and a kept snapshot. Rule for anything added later: an `UndoScript`
    that cannot restore something must throw, never just log.

## 10. Startup entries and debloat

Added 2026-09-06. Both tabs change what runs on someone's machine, so both follow the same rule as
the tweaks: say exactly what is changed, and prefer the mechanism Windows itself already exposes.

### Startup entries

* The enable/disable flag lives in `StartupApproved`, the key Task Manager's Startup tab and the
  Settings app write. Layout confirmed on a live Windows 10 19045 machine and cross-checked against
  the format notes at windowsir.blogspot.com:

  ```
  [HKCU\...\Explorer\StartupApproved\Run]  "Steam"=hex:03,00,00,00,03,d3,51,ae,9e,37,dd,01
  ```

  12 bytes. Byte 0 is the flag - `0x02` and `0x06` mean enabled, `0x03` (and `0x07`) mean disabled,
  i.e. **bit 0 set is "disabled"**. Bytes 4..11 are the FILETIME the entry was disabled, which is
  what Task Manager renders as "Disabled on ..."; an enabled entry carries a zero timestamp. Our
  writes are byte-identical to Windows' own, verified by a scratch `Run` value round trip. (H)
* Sources read: `HKLM\...\Run` -> `StartupApproved\Run`, `HKLM\SOFTWARE\WOW6432Node\...\Run` ->
  `StartupApproved\Run32`, `HKCU\...\Run` -> `StartupApproved\Run`, the user and common Startup
  folders -> `StartupApproved\StartupFolder` keyed by the `.lnk` file name. (H)
* **Nothing is deleted.** Most debloat scripts delete `Run` values, which is not reversible, hides
  the entry from the user, and desynchronises Task Manager. Flagging is reversible by definition
  and needs no snapshot, which is why the STARTUP tab is the one part of the tool with no backup
  file behind it.
* Deliberately narrower than Sysinternals Autoruns: no drivers, services, COM/shell-extension
  hijacks, Winlogon, AppInit or image-hijack entries. Autoruns is a forensics tool for people who
  can recover from a bad call; those categories are where a wrong tick stops a machine booting, and
  none of them are what "too much starts with Windows" means to a gamer.
* Scheduled tasks: only ones with a logon trigger, and only outside `\Microsoft\`. The vendor
  updaters and tray helpers people want gone (Epic, Adobe, GPU vendors, OneDrive) live outside it;
  Windows' own logon tasks are not ours to guess at, and the documented telemetry ones are already
  handled by name in `config/tweaks.json`. Tasks are enabled/disabled through
  `Enable-/Disable-ScheduledTask`, not by editing the task XML. (H)

### Debloat

* `Remove-AppxPackage` for the current account, plus `Remove-AppxProvisionedPackage -Online` when
  "also for new accounts" is ticked, which is what stops a package returning for a new profile or
  after a feature update. (H)
* This is the **only** irreversible action in the tool. `docs/DECISIONS.md` s1 rule 2 says every
  tweak is reversible; debloat is explicitly outside the tweak engine for that reason. Mitigations:
  a confirmation dialog that says so in as many words, and an append-only
  `backup\removed-apps.txt` listing every package removed with a timestamp, to reinstall from.
* The catalogue only ever offers packages that are **actually installed** (joined against
  `Get-AppxPackage`), with `IsFramework` and `NonRemovable` dropped first.
* `Get-UTAppxNeverRemove` is a **code-side** blocklist, checked last, that `config/debloat.json`
  cannot override - the config is data and a careless edit should not be able to brick a machine.
  A test asserts no catalogue entry is on it. It covers the Store, `StorePurchaseApp`,
  `DesktopAppInstaller` (winget itself), Windows Security, the Start menu and shell hosts, the
  account/credential brokers, the frameworks (`VCLibs`, `UI.Xaml`, `.NET`, `WindowsAppRuntime`,
  `WebView2`, the media extensions), Edge, and the GPU vendor control panels.
* Two Xbox packages are on that blocklist because this is a gaming tool:
  **`XboxIdentityProvider`** (Xbox sign-in for PC games - removing it is the documented cause of
  Minecraft, Forza and Game Pass titles refusing to sign in) and **`GamingServices`** (the Game Pass
  install and licensing service, painful to restore once broken). `XboxGamingOverlay`,
  `XboxGameOverlay`, `Xbox.TCUI` and the speech overlay *can* be removed but are opt-in with the
  cost written next to them - Game Bar owns the built-in FPS counter, Win+Alt+R capture and the
  per-game Game Mode toggle, and TCUI draws the Xbox panels some Game Pass titles open in-game.
  Only the retired Windows 10 Xbox Console Companion is in the recommended set. A test enforces
  that. (H)

## 11. Verification pass, 2026-09-05

Every registry edit, service and scheduled task in `config/tweaks.json` was re-checked against
current sources. Four things changed; the rest held up. Sources are named so anyone can argue
with the conclusion rather than with the tool.

### Changed

| Tweak | Finding | Action |
|---|---|---|
| `NetworkThrottle` | The throttle only limits **non-multimedia** traffic to 10 packets/ms (~10,000/s), orders of magnitude above a game's packet rate, so it was never going to add FPS - that part the old note had right. What it got wrong was "harmless": djdallmann/GamingPCSetup measured NDIS.sys **DPC latency rising** when the throttle is removed, using xperf under network load. For a latency-sensitive game that is a net negative. | **Removed** from the catalogue and added to the Excluded table in README. |
| `TimerResGlobal` | `GlobalTimerResolutionRequests` exists on **Windows 11 / Server 2022 and newer only**; on Windows 10 the key is inert. It also had no `MinBuild`, so Windows 10 users could apply a key that does nothing. valleyofdoom/TimerResolution, the reference implementation, states plainly that it "should only be used for debugging purposes". | `MinBuild` 22000 added; description now says it does nothing on its own and cites the debugging-only guidance. |
| `FSOGlobalOff` | Windows ignores the fullscreen-optimization setting entirely for **DirectX 12** titles. Fortnite has been DX12 or Performance mode since DX11 was removed (~2026-04), so this cannot help Fortnite at all - not "gains nothing", cannot apply. **Corrected 2026-09-06 (s13):** the D3D11 RHI still ships and `-d3d11` forces it, so this tweak does apply to a Fortnite launched that way; the description now says so. | Description rewritten to say why, and to keep it scoped to old DX9/11 titles. |
| `Widgets` | Neither shipped key is a Windows 10 key: `Dsh\AllowNewsAndInterests` and `TaskbarDa` are both Windows 11. The Windows 10 news-and-interests policy is `EnableFeeds`, confirmed from `C:\Windows\PolicyDefinitions\Feeds.admx` on a live 19045 machine. | `EnableFeeds` added. See s2. |

### Re-confirmed, no change needed

| Tweak | Evidence |
|---|---|
| `HVCIOff` | Tom's Hardware measured VBS/HVCI costing up to 10-15% in CPU-bound titles, ~5% geomean across four platforms in the 2021 run. The largest single FPS item in the catalogue, and correctly in the Risky tier with its own consent line. |
| `GameDVR` | Background capture is a real encode pipeline; disabling it is the one Game Bar change with a Microsoft policy behind it. Safe tier is right. |
| `MouseAccel` | REG_SZ `MouseSpeed`/`MouseThreshold1`/`MouseThreshold2` = "0" is the correct and complete way to kill pointer acceleration; WinUtil's DWord version is still a bug. Directly relevant to aim. |
| `AccessibilityKeys` | 510->506, 62->58, 122->126 each clear bit 2 (`SKF_HOTKEYACTIVE`), which is exactly the hotkey and nothing else. Verified arithmetically. |
| `GamePriorityIFEO` | `PerfOptions\CpuPriorityClass`=6 is Above Normal and is applied by the loader to the image itself, so it reaches `FortniteClient-Win64-Shipping.exe` without touching the running process. Documented caveat: child processes do not inherit it (IFEO inheritance is capped at Idle/Below Normal by design), which does not matter here. |
| `HAGS` | Gamers Nexus and BabelTechReviews both measure ~zero average FPS change; the real reasons to enable it are DLSS Frame Generation and the 24H2 flip queue. Optional tier and the existing "older GPUs skip it" wording are honest. Reddit reports of stutter on 8 GB cards (HAGS raises VRAM use) are consistent with leaving it opt-in. |
| `GameModeOff` | Community results are genuinely split and Microsoft's default is on. The description already says most people should leave it on. Correct as an opt-in troubleshooting step, not a boost. |
| `UltimatePerf` | Measured difference vs High Performance is inside noise, and at least one test found Ultimate *worse* in 1% lows. The description already says "negligible on modern CPUs with hardware P-states". Optional, not recommended: correct. |
| `CoreParkingOff` | Intel moved parking control on-die at Skylake and AMD followed, so the classic unpark win is mostly gone. Still real on X3D dual-CCD and Intel hybrid in the *wrong* direction, which is why the guard skips X3D. Risky tier is right. |
| `SysMainOff` | Windows already disables prefetch behaviour on SSDs; disabling the service is a myth with a real downside (slower launches). Kept in Risky purely because it is requested constantly, and the description says there is no measurable FPS gain. |

### Sources

- djdallmann/GamingPCSetup, NETWORK research (xperf DPC latency measurements): <https://djdallmann.github.io/GamingPCSetup/CONTENT/RESEARCH/NETWORK/>
- valleyofdoom/TimerResolution: <https://github.com/valleyofdoom/TimerResolution>
- Tom's Hardware, VBS/HVCI gaming benchmarks: <https://www.tomshardware.com/news/windows-11-gaming-benchmarks-performance-vbs-hvci-security> and <https://www.tomshardware.com/news/windows-vbs-harms-performance-rtx-4090>
- Microsoft ADMX `Feeds.admx` (`EnableFeeds`), read from `C:\Windows\PolicyDefinitions` on Windows 10 19045
- Microsoft Q&A / Learn threads on fullscreen optimizations and DirectX 12: <https://learn.microsoft.com/en-us/answers/questions/4181557/cant-disable-full-screen-optimizations>
- IFEO PerfOptions reference: <https://gist.github.com/HelderMagalhaes/899766e74da8cd3923fd47c41c07b320>

## 12. A paid tweaking panel's command list, reviewed 2026-09-06

A 774-line dump of every `cmd /c` line a paid Windows tweaking panel runs was handed over to be
mined for anything the catalogue was missing. Most of it is the standard regedit-pack material this
project already refuses, so the useful output of the review is mostly the **Excluded** table in
README: someone who paid for that panel deserves to know which of its buttons are placebo and which
are damage. Four things were worth taking.

### Added

| Id | Change | Why it earned a place | Conf |
|---|---|---|---|
| `VBSOff` | `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard` `EnableVirtualizationBasedSecurity`=0 (undo: remove) **and** `bcdedit /set hypervisorlaunchtype off` (undo: `Auto`), via `Invoke-UTBcdEdit` so BitLocker is suspended first. Risky tier, reboot. | The single largest FPS item in the whole file and the one thing `HVCIOff` could not finish. Memory integrity is one service *inside* VBS; the hypervisor keeps costing frames after HVCI is off, which is exactly what `HVCIOff`'s existing "Credential Guard is running, the gain will be smaller" warning is about. Tom's Hardware: up to 10% on an RTX 4090 rig, ~5% geomean across four platforms. Value name and the `0` = disabled semantics read out of `C:\Windows\PolicyDefinitions\DeviceGuard.admx` on this machine (policy `VirtualizationBasedSecurity`, `<disabledValue><decimal value="0"/>`), so this is the Group Policy setting, not a folk key. | H |
| `VendorGpuTasks` | Disable root-folder scheduled tasks matching `NvTmRep*`, `NvTmMon*`, `NvProfileUpdater*`, `NvNodeLauncher*`, `NvDriverUpdateCheckDaily*`, `NVIDIA GeForce Experience SelfUpdate*`, `NVIDIA App SelfUpdate*`, `AMD User Experience Program*`, `AMDRyzenMasterSDKTask*`, `AMDInstallLauncher*`, `AMDLinkUpdate*`, `AMDRadeonSoftware*`. Per-task previous state recorded for undo. Optional tier. | Real background work, vendor telemetry and update polling, and the one category the STARTUP tab cannot reach: it only lists tasks with a **logon** trigger, and these fire daily or on an event. NvTmMon is the NVIDIA Telemetry Monitor and NvTmRep the crash/telemetry reporter; disabling them has no effect on the driver or the control panel. The source list `schtasks /DELETE`s the AMD ones - we disable instead, because s10 says nothing in this tool deletes what it can flag. Driver installs re-create them, and the description says so. Enumerated on this machine 2026-09-06: the current NVIDIA driver ships `NVIDIA App SelfUpdate_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}` in the root folder, not the `GeForce Experience SelfUpdate` name the source list hardcodes - which is why this matches by pattern rather than by that list's GUID-suffixed names. | M |
| `Telemetry` (extended) | `\Microsoft\Windows\Autochk\Proxy` added to the task list. | Windows' own description of the task, read off this machine on 2026-09-06, is *"This task collects and uploads autochk SQM data if opted-in to the Microsoft Customer Experience Improvement Program."* That is the same CEIP family as `Consolidator` and `UsbCeip`, which were already there. Primary source is the OS. | H |
| `debloat.json` | `MicrosoftWindows.Client.WebExperience` added, **not** recommended. | The list's `winget uninstall "windows web experience pack"` pointed at a genuine gap: the Widgets board had a policy tweak but no package entry. Left unrecommended because the reversible `Widgets` tweak already stops it running and debloat is the one irreversible action in the tool. | H |

Checked and deliberately left out, with the reasoning that is not in the README table:

* **`Disable-MMAgent -MemoryCompression`.** The one genuine judgement call in the file. Microsoft
  documents the cmdlet but never recommends the change; every "it helped" report is community
  A/B testing, and the mechanism cuts both ways - compression only does work when memory is under
  pressure, which is precisely when replacing it with disk paging is worse. Under 16 GB it is a
  clear negative. At 16 GB and up the compression it would have avoided mostly never happens, so
  there is nothing to win. No primary source either way means it does not ship; s1 rule 2.
* **Per-device `SelectiveSuspendEnabled` / `EnhancedPowerManagementEnabled` / `AllowIdleIrpInD3`
  sprayed over every `Enum` node.** Redundant: `UsbPcieNoSleep` already sets the power-plan USB
  selective suspend policy, which the USB stack honours globally regardless of the per-device
  values. The spray writes hundreds of unsnapshotted values to device nodes to achieve what one
  documented power setting already does.
* **`sc config` on ~110 services.** Nothing in it is an FPS change, and the list disables `BFE`
  (the Base Filtering Engine - the Windows Firewall and every anti-cheat's network filter depend on
  it), `Winmgmt` (WMI, which this tool and half of Windows use), `WlanSvc` (Wi-Fi), `NlaSvc` and
  `Wcmsvc` (network profile and connection manager, so the firewall picks the wrong profile),
  `TokenBroker` (Store and Xbox sign-in) and `LanmanWorkstation` (file shares). The four services
  this project does touch are each named in s2-s4 with a cost written next to them.
  **This is not a hypothetical risk - the source file proves it happened.** Cross-referencing every
  `sc config` line against every other line touching the same service name: `NlaSvc`, `Wcmsvc`,
  `RmSvc` and `lmhosts` each appear with `start= disabled` in one place and `start= auto` (the
  Windows default) in another, and `Dhcp`, `DPS`, `nsi`, `WlanSvc` and `Winmgmt` - the rest of the
  same Network Location Awareness / Connection Manager dependency chain, plus WMI - each get a
  `net start` line sitting right next to them. NLA depends on DHCP, DPS and NSI; disabling any of
  them takes NLA down with it, which is what makes Windows Firewall apply the Public profile to
  every network and can leave a PC reporting "No internet access" with a live connection. Read as a
  sequence rather than a deduplicated list, this is a later version of the same panel putting back
  the network stack an earlier version broke - concatenated into one file with no version markers,
  so a person running the "regedit pack" version by hand has no way to know the restore lines exist,
  only the breakage. (`sort -u` on every `sc config <name>` line's target service name against every
  `start= (auto|demand|disabled)` value it is ever given, this repo, 2026-09-06.)
* **Blanket `schtasks /Change /Disable` over the whole `\Microsoft\Windows\` tree.** Includes
  `Defrag\ScheduledDefrag`, which is what issues scheduled TRIM to an SSD; `WaaSMedic` and the
  `UpdateOrchestrator` set, which is disabling Windows Update by the back door; and
  `RecoveryEnvironment\VerifyWinRE`. The documented telemetry ones were already shipped by name.

### Sources

- Tom's Hardware VBS benchmarks (as above), plus the RTX 4090 follow-up: <https://www.tomshardware.com/news/windows-vbs-harms-performance-rtx-4090>
- Riot Games, VAN9005 / VBS on Windows 10: <https://support.riotgames.com/en-us/valorant/support-tools/addressing-virtualization-based-security-vbs-settings-on-windows-10-van9005-valorant>
- Microsoft Learn, Virtualization-based Security (VBS): <https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/oem-vbs>
- Microsoft ADMX `DeviceGuard.admx`, read from `C:\Windows\PolicyDefinitions` on Windows 10 19045, 2026-09-06
- `Get-ScheduledTask` descriptions read from this machine, Windows 10 19045, 2026-09-06
- gHacks, NVIDIA telemetry tasks: <https://www.ghacks.net/2016/11/07/nvidia-telemetry-tracking/>

## 13. Launch argument `-d3d11`, 2026-09-06

s5 and s11 said DX11 was removed from Fortnite around 2026-04. That was true of the Rendering
Mode menu and wrong about the engine, and this machine proved it. The Epic launcher here already
carried `Fortnite_AdditionalCommands=-high -d3d11`, and `FortniteGame.log` from the run on
2026-09-05 23:26 (client `++Fortnite+Release-42.10-CL-57819926`) reads:

```
LogRHI: Using Forced RHI: D3D11
LogRHI: Found D3DRHIPreference PreferredFeatureLevel: sm6
LogRHI: Using Highest Feature Level of D3D11: ES3_1
LogRHI: Loading RHI module D3D11RHI
LogRHI: Checking if RHI D3D11 with Feature Level ES3_1 is supported by your system.
LogD3D11RHI: Chosen D3D11 Adapter: NVIDIA GeForce GTX 1650
```

So on the current client: the D3D11 RHI module is still compiled in and loads; `-d3d11` on the
command line is honoured (`Using Forced RHI`); and with D3D11 forced the engine ignores the config's
`sm6` and caps at **ES3_1**, which is the feature level Performance Mode uses. `-d3d11` therefore
brings back the *legacy DX11 Performance Mode* that competitive players lost when the menu option
went, not a full DX11 SM5 renderer. Epic's own help centre still hosts "How do I force Fortnite to
use DirectX 11?", and the article on the menu removal says players on DX11 were moved to
Performance Mode, which is consistent with the log.

**Shipped:** a fourth rendering option in `config/fortnite.json`, `-d3d11`, off by default,
mutually exclusive with `-d3d12 -sm6` (the existing symmetric `Excludes` handles both orders).
Combining it with `-FeatureLevelES31` is allowed: redundant, since D3D11 caps at ES3_1 anyway, but
not contradictory. The label says "older NVIDIA cards" rather than "most NVIDIA": the evidence
here is one GTX 1650, and Epic's note that DX12 Performance Mode "works best with modern computers
with up-to-date driver support" is the honest counterweight for RTX owners. (H for "it works on
42.10"; M for who it is best for.)

**Not shipped:** `-high`, which was on the same command line. It stays on the placebo list for the
reason already there (a Source-engine switch Unreal never parses). Nothing in the log responds to
it. Anyone who wants it anyway can type it in the "extra" box, which is what that box is for.

**Also corrected:** the `FSOGlobalOff` description no longer says Fortnite "cannot" be DX11; it
now says the tweak applies to a Fortnite launched with `-d3d11`.

### Sources

- `%LOCALAPPDATA%\FortniteGame\Saved\Logs\FortniteGame.log` and the Epic launcher's
  `WindowsEditor\GameUserSettings.ini` on this machine, 2026-09-05/06
- Epic, "Has the DirectX 11 option been permanently removed from Rendering Mode in Fortnite?": <https://www.epicgames.com/help/c-202300000001636/c-202300000001721/has-the-directx-11-option-been-permanently-removed-from-rendering-mode-in-fortnite-a202300000083887>
- Epic, "How do I force Fortnite to use DirectX 11?": <https://www.epicgames.com/help/en-US/c-Category_Fortnite/c-Fortnite_TechnicalSupport/how-do-i-force-fortnite-to-use-directx-11-a000085695>
- Epic, "What performance mode should I use, DirectX11 or DirectX12?": <https://www.epicgames.com/help/en-US/c-202300000001636/c-202300000001690/a202300000011726>
