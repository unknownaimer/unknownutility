# unknowntweaks

A free, open-source Windows gaming optimizer for the Fortnite community. One line in PowerShell, a
clean dark interface, live CPU / RAM / GPU / disk / network graphs on the left, and only tweaks that
have a documented mechanism. Everything is reversible. Nothing is paywalled, nothing is hidden.

```powershell
irm "https://GATE/ut?k=YOUR-KEY" | iex
```

Open PowerShell (no admin needed, it asks for elevation itself), paste, press Enter.

## What it does

**Left panel**: Task-Manager-style graphs sampled once a second (CPU, memory, GPU busiest engine
and VRAM, disk active time, network up/down), the game currently in the foreground with its GPU
share, ping to your router and to the internet, your best Fortnite region, and whether you are on
Wi-Fi.

**TWEAKS tab**, three hard-separated tiers:

- **Safe** (the recommended preset): Game DVR off, mouse acceleration off, accessibility hotkeys
  off, Edge background processes off, Widgets off, Bing/Copilot/Recall off, telemetry and the
  Compatibility Appraiser task off, suggestions and silent app installs off, activity history off,
  Delivery Optimization peer uploads off, Windows Update driver replacement off, fast startup off,
  file extensions and End task, windowed-game optimizations on, USB / PCIe power saving off,
  temp file cleanup.
- **Optional**: hardware-accelerated GPU scheduling, Game Mode off, Game Bar pop-ups off, global
  fullscreen-optimizations off, power throttling off, Ultimate Performance plan, hibernation off,
  visual effects for performance, feature-update deferral, NIC power saving off, background Store
  apps off, location off, Teredo off, search indexing off, NVIDIA / AMD telemetry and updater
  tasks off.
- **Risky**: memory integrity (HVCI) off, virtualization-based security off (the whole
  hypervisor, the largest measured FPS item), dynamic tick off (with BitLocker suspended for one
  reboot first), global timer resolution key, MSI mode for the GPU, Fortnite process priority via
  Image File Execution Options (works through Easy Anti-Cheat, never High or Realtime), core
  parking off (skipped on X3D CPUs), SysMain off. Each one explains its cost and asks again.

Every item in the list is one line. Hover it for what it changes, why it works, and where that
comes from.

Before the first apply the tool offers a System Restore point. Before every tweak it snapshots the
real current values (registry kind and data, service startup type, task state) to
`%ProgramData%\unknowntweaks\backup\<id>.json`, so **Undo** restores what *you* had, not what
Windows ships with. **Undo everything** reverts every tweak the tool has ever applied on that PC,
including from an earlier session, without you having to remember which ones you picked.

The reversibility is enforced, not just promised:

- A tweak that cannot write its snapshot does not apply at all.
- A tweak that is already applied refuses to re-apply, because re-running it would record the
  tweaked values as the originals and undo would then restore the tweak.
- Undo on something this tool never applied does nothing, instead of forcing its idea of the
  Windows default onto your machine.
- A failed registry, service or task write makes the whole tweak report as failed, so nothing is
  ever labelled applied when it is not.
- Checks that can refuse a tweak (an X3D CPU for core parking, an encrypted drive for a boot
  setting) run *before* anything is recorded or changed.

**FORTNITE tab**: three profiles for `GameUserSettings.ini` (Max FPS / Performance Mode, Balanced
DX12, Latency only) written as a key-level merge with a backup, plus optional hidden keys, lock and
unlock of the file, shader cache clearing, and **launch arguments written into the Epic Games
Launcher's own settings file** (the launcher is closed and restarted for that). Only arguments the
Unreal engine actually parses on a client are offered, including `-d3d11` for the legacy DX11
Performance Mode renderer; the placebo ones are in the table further down, with the reason.

**NETWORK tab**: pings Epic's eight regional datacenter hosts (the same ones the in-game region list
uses) with jitter and loss, benchmarks public DNS resolvers with real uncached queries and a real
timeout, sets or resets DNS, shows your link (and warns about Wi-Fi), flushes DNS, traceroutes to
your best region, and repairs the network stack. It also tells you honestly why an ExitLag-style
ping reducer cannot be replicated by a script.

**STARTUP tab**: an Autoruns-shaped view of what actually runs when you log in - the `Run` keys for
this account and all users (64- and 32-bit), both Startup folders, and third-party scheduled tasks
with a logon trigger - with the command line each one runs. Ticking entries and pressing **Disable
selected** writes the same `StartupApproved` flag that Task Manager's Startup tab writes, so:

- nothing is deleted; the `Run` value or the shortcut stays exactly where it is,
- Task Manager and the Settings app agree with this list and can undo it,
- turning it back on is one tick, with no snapshot needed.

It is deliberately narrower than [Sysinternals Autoruns](https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns):
no drivers, services, COM hijacks, Winlogon or AppInit entries. Those are where Autoruns lets an
unsure user make a machine unbootable, and none of them are what "too much starts with Windows"
means. Scheduled tasks under `\Microsoft\` are left out for the same reason - the vendor updaters
and tray helpers worth killing live outside it.

**DEBLOAT tab**: removes preinstalled Store apps, joined against what is really installed so the
list is never a wall of things that are already gone. **Select recommended** ticks only the apps
with no gaming or system role: Cortana, Copilot, the Bing apps, the Office promotion tile, Solitaire,
Tips, Get Help, Feedback Hub, Dev Home, Mixed Reality Portal, Skype, People, Maps and the retired
Xbox Console Companion. Media players, mail, Phone Link and everything else is opt-in with the
reason written next to it.

This is the one part of the tool **Undo cannot reverse**: a package is uninstalled, not switched
off. It says so before it does anything, and every name removed is appended to
`%ProgramData%\unknowntweaks\backup\removed-apps.txt` so you have a list to reinstall from the
Store. "Also for new accounts" additionally deprovisions the package so a new user account or a
Windows feature update does not bring it back.

A hard-coded list in the code - not in the JSON, so a careless edit to the catalogue cannot get
past it - refuses to remove the Microsoft Store, `DesktopAppInstaller` (winget itself), Windows
Security, the Start menu and shell hosts, the frameworks other apps link against, and, because this
is a gaming tool, **`XboxIdentityProvider` and `GamingServices`**: removing those is the documented
cause of Minecraft, Forza and Game Pass titles refusing to sign in. Xbox Game Bar and the Xbox
in-game UI can be removed, but they are opt-in with a warning rather than part of the one-click set.

**APPS tab**: silent winget installs for the usual gaming, monitoring, runtime and utility apps.

**INFO tab**: what the tool detected (OS build, CPU, GPUs and VRAM, RAM, disk type, laptop or
desktop, power plan, HAGS, VBS / memory integrity / Credential Guard, Secure Boot, BitLocker, which
user you elevated as) and where the logs and backups live.

## What it refuses to do, and why

Most paid "Fortnite regedit packs" are a mix of placebo and harm. These are left out on purpose:

| Popular tweak | Reality |
|---|---|
| `SystemResponsiveness=0` | Microsoft clamps values below 10 to 20, the default. Placebo. |
| MMCSS `Tasks\Games` priorities | Microsoft: "GPU Priority is not yet used", "SFIO Priority is not used". Fortnite does not register with it. Placebo. |
| `Win32PrioritySeparation=0x26` | Identical scheduling to the client default of 2. Placebo. |
| Nagle / `TcpAckFrequency` / `TCPNoDelay` | TCP only. Fortnite and Valorant gameplay is UDP. Placebo. |
| `NetworkThrottlingIndex=0xFFFFFFFF` | Removed 2026-09-05. It only caps non-multimedia traffic at 10 packets/ms, hundreds of times more than a game sends, so it was never going to add FPS. Worse, djdallmann/GamingPCSetup measured NDIS.sys **DPC latency going up** with it disabled, which is the opposite of what a latency-sensitive game wants. Excluded. |
| XP-era TCP keys (`TcpWindowSize`, `Tcp1323Opts`, `SackOpts`) | Ignored or actively slow downloads since Vista. Harmful. |
| `DisablePagingExecutive`, `LargeSystemCache`, `IRQ8Priority` | NT4/2000-era keys, no effect on modern kernels. Placebo. |
| Spectre/Meltdown mitigations off | Roughly zero gain on modern CPUs, real security loss, anti-cheat refusals. Excluded. |
| `bcdedit useplatformclock yes` | Forces a slow HPET timer path: the classic stutter cause. Excluded; the tool never sets it. |
| Disable Defender / Windows Update / IPv6 | Security, driver and anti-cheat update loss, Xbox networking breakage. Excluded. |
| Page file off | Commit-limit crashes and stutter. Excluded. |
| Engine.ini / Scalability.ini fog and foliage cvars | Fortnite has ignored these since 2017, and FNCS rule 8.2.1 treats client modification as cheating. Never written. |
| `-USEALLAVAILABLECORES`, `-lanplay`, `-limitclientticks`, `-high`, `-malloc=system` | Placebo on a client (verified in the engine source); `-NOTEXTURESTREAMING` is actively harmful. |

The rest of this table came out of a line-by-line read of a paid tweaking panel's command list on
2026-09-06. Four things in it were worth taking (see [docs/DECISIONS.md](docs/DECISIONS.md) s12);
these were not.

| Popular tweak | Reality |
|---|---|
| `Set-ProcessMitigation -System -Disable` over every mitigation | Turns off DEP, ASLR, CFG and SEHOP system-wide in one line. The single most damaging command in that panel: no measurable FPS, every kernel-level anti-cheat can see it, and it undoes twenty years of exploit hardening. Excluded. |
| `fsutil behavior set DisableDeleteNotify 1` | Turns **TRIM off**. The SSD stops being told which blocks are free, so write performance degrades permanently as the drive fills. Sold as a latency tweak. Harmful. |
| `Remove-Item "HKLM\...\Image File Execution Options\*" -Recurse` | Deletes every IFEO key, including ones other software legitimately owns and the per-game priority entry this tool writes. Nothing is snapshotted first. Harmful. |
| `bcdedit` pack: `nx optout`, `pae ForceDisable`, `increaseuserva`, `tpmbootentropy ForceDisable`, `integrityservices disable`, `disableelamdrivers yes`, `nolowmem` / `avoidlowmemory` / `firstmegabytepolicy`, `custom:160000xx`, `linearaddress57 OptOut`, `tscsyncpolicy legacy` | `increaseuserva` and `pae` are 32-bit settings an x64 kernel ignores; the `custom:` values are undocumented debug flags; `nx optout` disables DEP and `disableelamdrivers` disables early-launch anti-malware, both of which anti-cheat drivers can observe. No FPS evidence for any of them. Excluded. |
| `powercfg` processor idle disable (`5d76a2ca-...` = 1) and `PROCTHROTTLEMIN 100` | Blocking C-states and pinning the minimum processor state at 100% keeps the CPU hot and out of the thermal headroom modern boost algorithms need, so peak clocks go **down**. The Ultimate Performance plan already covers the legitimate half of this. Excluded. |
| `Disable-MMAgent -MemoryCompression` | Genuinely mixed rather than fake. Compression only does work when memory is under pressure, and that is exactly when paging to disk instead is worse: below 16 GB it hurts, and at 16 GB and up there was little for it to save in the first place. No primary source either way, so it does not ship. |
| `Disable-NetAdapterLso` / `-Rsc` / `-ChecksumOffload` / `-IPsecOffload`, and the `Disable-NetAdapterBinding` sweep | Offloads exist to move work off the CPU. Turning them off raises CPU and NDIS DPC time, which is the same measurement that got `NetworkThrottlingIndex` removed from this tool. Excluded. |
| `netsh int ip reset`, `netsh winsock reset`, `netcfg -d` presented as tweaks | Repair commands, not tweaks. `netcfg -d` tears down every network adapter, binding and protocol on the machine. They fix a broken stack; they do not add frames. |
| Firewall rule blocking `173.194.55.0/24` and `206.111.0.0/16` ("StopThrottling") | Those are Google and YouTube CDN ranges. Blocking them breaks video playback and does nothing to a game server. Excluded. |
| `Get-AppxPackage \| Remove-AppxPackage` with no filter | Tries to remove every Store app for the user, shell hosts and sign-in brokers included. The DEBLOAT tab exists precisely so this is a reviewed list with a code-side never-remove blocklist behind it. Excluded. |
| Blanket `sc config <service> start= disabled` over ~110 services | That list includes `BFE` (Windows Firewall, and every anti-cheat's network filter), `Winmgmt` (WMI), `WlanSvc` (Wi-Fi), `NlaSvc` / `Wcmsvc` (network profile detection, so the firewall picks the wrong profile) and `TokenBroker` (Store and Xbox sign-in). None of it is an FPS change. The panel's own command history proves the point: `NlaSvc`, `Wcmsvc`, `RmSvc` and `lmhosts` each get `start= disabled` in one place and `start= auto` (the Windows default) in another, and `Dhcp`, `DPS`, `nsi`, `WlanSvc` and `Winmgmt` - the rest of that same network-location dependency chain, plus WMI - get a `net start` right alongside them. Read together, that is a later version of the panel putting back the network stack an earlier version broke. The four services this tool does touch are named individually with their cost. |
| Blanket `schtasks /Change /Disable` over `\Microsoft\Windows\` | Sweeps up `Defrag\ScheduledDefrag`, which is what issues scheduled TRIM to an SSD; the `UpdateOrchestrator` and `WaaSMedic` tasks, which is Windows Update disabled by the back door; and `RecoveryEnvironment\VerifyWinRE`. The documented telemetry tasks are already disabled here by name. |
| Deleting `C:\Windows\Prefetch`, deleting then re-creating `SoftwareDistribution`, `takeown /f C:\Windows\Temp /r` | Prefetch data is what makes the *next* launch faster, so deleting it is a guaranteed small loss. Re-creating `SoftwareDistribution` with `md` gives it the wrong ACL and breaks Windows Update. `takeown` permanently changes ownership of a system directory. All harmful. |
| `wmic path win32_networkadapter where index=N call disable` | Disables an adapter by index number, which is not stable between machines or reboots. As likely to kill the NIC you are playing on as a virtual one. Excluded. |
| Importing a `.pow` power plan downloaded from a CDN link at runtime | An opaque binary of someone else's power settings, fetched over the network, with no way to see what it changes or to undo it. This tool sets individual power settings by name and records the previous value. Excluded. |
| Per-device `SelectiveSuspendEnabled` / `EnhancedPowerManagementEnabled` / `AllowIdleIrpInD3` written to every `Enum` node | Redundant. The USB selective suspend power setting this tool already sets is honoured by the USB stack globally; the sprayed version writes hundreds of unsnapshotted values to device nodes to reach the same place. |
| `deltree`, `dfrgui`, `SFC /scannow`, `cleanmgr`, and message boxes telling you to go and click things yourself | Windows 9x commands that no longer exist, launchers for tools Windows already ships, and pop-ups instructing the user to make the change by hand. Not tweaks. |

The full research behind every decision, and the defects a code review found in the first cut,
are in [docs/DECISIONS.md](docs/DECISIONS.md). Before publishing a build, work
through [docs/TESTING.md](docs/TESTING.md): the automated checks cannot cover WPF, the registry or
the performance counters, and that round trip of apply, reboot, play a match, undo, reboot is the
whole promise of the tool. To publish without attaching your name to it, follow
[docs/PUBLISHING.md](docs/PUBLISHING.md).

## Support and credits

Made by **UNKNOWN AIMER**.

- Support and questions: <https://discord.gg/PF44W3rxJ3>
- TikTok: <https://www.tiktok.com/@aimerunknown>

The same links are on the boot screen and in the INFO tab inside the tool.

## Anti-cheat

The tool injects nothing into any process, loads no drivers, and never disables Exploit
Protection or Defender. Registry, power, service and INI changes are not what gets people banned;
code injected into the game is. The clearest precedent is AMD Anti-Lag+, which was withdrawn after
its in-game code injection triggered bans.

One honest caveat about the memory integrity tweak in the Risky tier. At the time of the research,
Riot Vanguard did not require it on Windows 10 or 11 x64, and Easy Anti-Cheat required it only on
Arm and Insider builds. Anti-cheat requirements change without announcement. If a protected game
stops launching after you use that tweak, turn it back on before you change anything else.

## Building from source

The one-liner downloads `unknowntweaks.ps1`, which is generated. Edit the sources instead:

```
config/      tweaks.json, fortnite.json, dns.json, gameservers.json, games.json, applications.json
functions/   one function per file; private/ helpers, public/ UI
xaml/        the window
scripts/     start.ps1, the entry point
tools/       Test-Syntax.ps1 (static), Test-Logic.ps1 (behaviour), Test-Startup.ps1 (the real window)
```

```powershell
.\tools\Test-Syntax.ps1          # parses everything, flags PowerShell 7-only syntax, checks JSON/XAML
.\tools\Test-Logic.ps1           # behaviour, including a live ping of Epic's region hosts
.\tools\Test-Startup.ps1         # builds the window and runs the monitor for real, then closes it
.\Compile.ps1 -Beta -StatusUrl https://GATE/status   # private beta; drop both for the public build
.\unknowntweaks.ps1
```

All three run on the Windows PowerShell 5.1 that ships with Windows, which is the runtime the tool
itself uses, so there is nothing to install first. The first two also run under PowerShell 7 on any
platform.

`Test-Syntax.ps1` parses every script with the PowerShell AST, rejects syntax that only works on
PowerShell 7, rejects non-ASCII (Windows PowerShell reads a file without a byte order mark as ANSI),
validates the JSON and XAML, and cross-checks that every control the code reaches for actually
exists in the window.

`Test-Logic.ps1` exercises the registry value conversions and writes, the INI merge, the snapshot
format that undo depends on, the build-eligibility rules and the worker-script wrapping, and it
lifts the wrapper template out of the source so the test can never drift from what the code really
does.

`Test-Startup.ps1` does everything `scripts/start.ps1` does - native helpers, system detection, the
XAML, every dynamically built checkbox and graph card, the sampler runspace, the UI timer and one
worker job - except that it never calls `ShowDialog`, points its logs and backups at a temp folder,
and only ever reads. It is the only check that catches a renamed control, a style key that stopped
resolving, or a monitor that dies on its first tick. Give it `-Show` to open the real window
off-screen for a moment, or `-SkipNetwork` on a machine with no internet.

`Compile.ps1` bakes the account and repository name into the file (used only when the tool
re-launches itself elevated). They default to `unknownaimer/unknownutility`; pass `-Owner` and
`-Repo` to build for another.

## Requirements

Windows 10 or 11, Windows PowerShell 5.1 (built in; the tool relaunches itself into it from
PowerShell 7), an administrator account. Works on non-English Windows: the monitor uses the
language-neutral performance counter API.

## License

MIT. Architecture inspired by Chris Titus Tech's WinUtil (MIT). No affiliation with Epic Games.
