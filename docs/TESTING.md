# Testing unknowntweaks on Windows

Run the automated checks first. All three work on the Windows PowerShell 5.1 that is already on the
machine:

```powershell
.\tools\Test-Syntax.ps1          # parsing, 5.1 compatibility, JSON, XAML, control cross-check
.\tools\Test-Logic.ps1           # registry conversion and writes, INI merge, snapshots, job wrapping
.\tools\Test-Startup.ps1         # the window, the dynamic controls, the monitor and a worker job
```

Between them they cover parsing, the JSON and XAML, the INI merge, registry value conversion and
real writes under `HKCU\Software\unknowntweaks-selftest`, snapshot round trips, worker-script
wrapping, the live region pinger, and a full headless start: every checkbox and graph card built,
the sampler publishing real counters, the UI timer draining them, and a worker job running and
being disposed.

What they still cannot do is change a setting and put it back. Nothing automated applies a tweak,
touches a service, writes a boot setting, or edits your real Fortnite config, and no test can tell
you whether Windows still boots afterwards. Do the rest of this document once on a real machine,
ideally a spare PC or a virtual machine with a checkpoint, before telling anyone the build is good.

## Before you start

1. Take a VM checkpoint, or make a System Restore point yourself.
2. Run from a file first, not the one-liner: `powershell -ExecutionPolicy Bypass -File .\unknowntweaks.ps1`.
3. Keep the OUTPUT pane visible. Every action logs there and to
   `%LOCALAPPDATA%\unknowntweaks\logs`.

## 1. It starts at all

| Check | Expected |
|---|---|
| Launch from a non-elevated PowerShell 7 | It relaunches itself: UAC prompt, then a window from Windows PowerShell 5.1 |
| Launch from an elevated Windows PowerShell 5.1 | Window appears directly, no second process |
| Title bar | Dark, not white, on Windows 10 2004+ and Windows 11 |
| Window | Resizes; the left panel and OUTPUT pane have working splitters |
| INFO tab | Shows your real CPU, GPU with VRAM, RAM, disk type, build number, power plan |
| OUTPUT | Shows the disclaimer line and "ready" with your hardware |

If the window never appears, the XAML failed to load: the console prints the inner parser message.

## 2. The live graphs

Let it run for 30 seconds, then:

| Check | Expected |
|---|---|
| CPU graph | Tracks Task Manager within a few percent |
| MEMORY | Matches Task Manager's percentage and GB |
| GPU | Non-zero while something renders; says `n/a` only on a machine without WDDM 2.0 counters |
| DISK ACTIVE | Rises when you copy a large file |
| NETWORK | Rises when you start a download; the value line shows down and up separately |
| router / internet ping | Two plausible numbers, updating |
| Wi-Fi note | Appears only if you are actually on Wi-Fi |
| OUTPUT | Contains `monitor: backend=pdh`. `backend=wmi` means the native helpers failed to compile, which still works but costs more CPU |

Open a game in fullscreen and alt-tab back: the GAME card should name it and show a GPU share.
Try Fortnite specifically, since its process name is what the tool keys on.

**Non-English Windows**: this is the main reason the tool uses the English-name counter API. If you
can, run it once on a German, French, Spanish or Portuguese install and confirm the graphs still
move and the log still says `backend=pdh`.

## 3. Apply and undo, the important part

Do this with **one safe tweak first**, not the whole preset.

1. Tick only **Show file extensions and End task on the taskbar**. Apply.
2. Confirm in Explorer that extensions are now visible.
3. Check `%ProgramData%\unknowntweaks\backup\UTExplorerQoL.json` exists and records
   `HideFileExt` with `Exists: true` and the value you had.
4. Tick it again, press **Undo selected**.
5. Extensions hidden again, and the backup file is gone.

Then the real test:

1. Press **Select recommended**, leave the restore point box ticked, **Apply selected**.
2. Watch the OUTPUT for anything that says failed or access denied.
3. Reboot. Confirm Windows boots normally, sound works, the network works, Start menu search
   works, and notifications still appear.
4. Play a match. Confirm Fortnite launches, Easy Anti-Cheat does not complain, and you can join.
5. Open unknowntweaks again. Every applied tweak should be labelled `[applied by unknowntweaks]`.
6. Press **Undo everything**, accept the confirmation, reboot, and verify Windows is back to how it
   was, including the things you checked in step 3.

That round trip is the whole promise of the tool. If any part of it fails, do not publish.

## 4. The risky tier, one at a time, on a machine you can restore

| Tweak | What to verify afterwards |
|---|---|
| Memory integrity off | Reboot. Windows Security shows Core isolation off. Valorant still launches (Vanguard allows it). Undo puts it back and Windows Security shows it on again. |
| Dynamic tick off | If BitLocker is on, the log must say it suspended protection. Reboot must **not** ask for a recovery key. `bcdedit /enum {current}` shows the value; undo removes it. |
| MSI mode on the GPU | Reboot. If the machine fails to boot, that is the documented risk: recover in Safe Mode and delete the value. Verify the log recorded the previous value per device. |
| Fortnite priority | Launch Fortnite, check Details in Task Manager shows Above Normal for `FortniteClient-Win64-Shipping.exe`. |
| Core parking off | On an X3D CPU it must refuse with a message, not apply. |

## 5. Fortnite tab

| Check | Expected |
|---|---|
| Status block | Names your real install path, config file and the launcher settings file |
| Apply a profile with Fortnite open | Refuses with "Fortnite is running" |
| Apply a profile with it closed | Reports how many keys changed; `GameUserSettings.ini.unknowntweaks.original` and a timestamped `.bak-` appear next to it |
| Open Fortnite | Video settings reflect the profile; the game does not reset the file |
| Keys you set by hand that the profile does not mention | Still there afterwards |
| Restore original file | Puts your first-ever version back |
| Launch arguments | Written into the launcher settings file; the launcher closes and reopens |
| Status block, `launch args key` line | Reads `source: existing` if you have ever set arguments in the launcher, `known` if you have not. `unknown` means it could not read your account id: sign in to the launcher and open it once |
| Epic launcher UI | profile icon > Settings > Manage Games > Fortnite shows your arguments in the box, ticked |

The section and key were confirmed on Epic Games Launcher 20.2.6 and are written directly
(`[<AccountId>_Settings]` / `fn:<CatalogItemId>:Fortnite_AdditionalCommands` plus the same key
suffixed `Enabled`; see docs/DECISIONS.md s5). If a future launcher build moves them and the box
comes up empty, press **Probe launcher key**, follow the instruction it logs (type `-UTPROBE12345`
into the launcher and fully exit it), then **Finish probe**. The log will name the real section and
key, and this machine remembers it from then on; put it in `Find-UTLaunchArgsKey` so nobody else
has to probe.

## 6. Network tab

| Check | Expected |
|---|---|
| Ping regions | A sorted table; your nearest region first with a sane number. Middle East may show no reply, which is normal from most ISPs |
| Benchmark resolvers | Every provider gets a median, or an honest timeout |
| Use selected resolver | `Get-DnsClientServerAddress` shows the new servers on the adapter with the default route |
| Back to automatic | Puts DHCP (or your previous static servers) back |
| Link info | Names the right adapter and warns if Wi-Fi |
| Reset network stack | Asks first; after a reboot the internet still works |

## 7. Apps tab

Install one small thing (7-Zip) and confirm winget runs silently and the log reports success. Then
tick something already installed and confirm it reports "already installed" rather than failing.

## 7a. STARTUP tab

| Check | Expected |
|---|---|
| The list | Matches Task Manager's Startup tab, entry for entry, including which are already off. Extra rows for Startup-folder shortcuts and third-party logon tasks are expected: Task Manager shows those too |
| Nothing under `\Microsoft\` | No Windows scheduled task appears in the list |
| Tick one entry, **Disable selected** | Log says it was disabled. Task Manager now shows the same entry disabled, with a "Disabled on" date |
| The `Run` value itself | Still present and unchanged in `regedit`. Only `Explorer\StartupApproved\Run` gained a value |
| Tick it again, **Enable selected** | Task Manager shows it enabled again; the StartupApproved blob is `02 00 00 00` + eight zero bytes |
| Reboot | The disabled entries do not start; the enabled ones do |
| **Refresh** after installing something that adds a startup entry | The new entry appears |

## 7b. DEBLOAT tab

Do this on a machine you can restore. Removal is the one thing Undo cannot reverse.

| Check | Expected |
|---|---|
| The list | Only apps that are really installed. Nothing you already removed shows up |
| **Select recommended** | Ticks the ads-and-assistants set and the retired Xbox Console Companion. It must **not** tick Game Bar, Xbox TCUI, media players, mail or Phone Link |
| **Remove selected** | Asks first, and the dialog says removal cannot be undone from a snapshot |
| After it runs | The apps are gone from Start; `%ProgramData%\unknowntweaks\backup\removed-apps.txt` lists each one with a timestamp |
| With "also for new accounts" ticked | `Get-AppxProvisionedPackage -Online` no longer lists them |
| Microsoft Store | Still installed and still opens. So does `winget --version` |
| Windows Security | Still opens |
| Game Pass / Xbox sign-in | Launch a Game Pass or Microsoft-published title and confirm it still signs in. `Get-AppxPackage Microsoft.XboxIdentityProvider` and `Microsoft.GamingServices` must both still be present - the tool refuses to remove them, and this is the check that proves it |
| Reinstall one from the Store | Works, and it comes back with its data reset |
## 8. Things to try to break it

- Close the window while a job is running: it should ask before closing, then shut down cleanly with
  no orphaned `powershell.exe`.
- Apply with no tweaks ticked: a warning, not an error.
- Run on a machine with System Protection disabled: the restore point step warns and continues.
- Run as a standard user who types admin credentials at the UAC prompt: the INFO tab warns that
  per-user tweaks will land on the admin account.
- Delete `%ProgramData%\unknowntweaks\backup` and press Undo: **Undo everything** says there is
  nothing to undo, and **Undo selected** says each ticked tweak was not applied on this PC and
  changes nothing. Refusing is deliberate: with no snapshot the tool would be writing its own idea
  of the Windows default onto a machine it may never have touched. The `OriginalValue` fallback in
  `config/tweaks.json` is reachable only from the console, as
  `Invoke-UTTweaks -Ids <id> -Undo -Force`.
