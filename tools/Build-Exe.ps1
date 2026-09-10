<#
.SYNOPSIS
    Wraps the compiled unknowntweaks.ps1 into a single unknowntweaks.exe.
.DESCRIPTION
    The exe is a small launcher with the script embedded as a resource. On run it writes the script
    to %LOCALAPPDATA%\unknowntweaks\app and starts Windows PowerShell 5.1 on it.

    Two decisions worth knowing:

    * The script is written to a stable path rather than a temp file that is deleted afterwards.
      unknowntweaks relaunches itself elevated by re-running its own file, so deleting the file when
      the first process exits would pull it out from under the elevated one.
    * The exe carries a manifest asking for administrator, so there is one UAC prompt from the exe
      instead of a second one when the script relaunches itself.

    Built with the C# compiler that ships in the .NET Framework, so nothing is downloaded and no
    third-party packer is involved. The result is unsigned: see docs/PUBLISHING.md for what that
    means for the people you send it to.
.PARAMETER Version
    Stamped into the exe's file properties. Defaults to the version in the compiled script.
.PARAMETER OutFile
    Where to write the exe. Defaults to unknowntweaks.exe next to the script.
#>
[CmdletBinding()]
param([string]$Version, [string]$OutFile, [switch]$SkipCompile)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'unknowntweaks.ps1'
if (-not $OutFile) { $OutFile = Join-Path $root 'unknowntweaks.exe' }

if (-not $SkipCompile) {
    Write-Host 'compiling the script first (use -SkipCompile to reuse the existing one)'
    & (Join-Path $root 'Compile.ps1') | Write-Host
}
if (-not (Test-Path -LiteralPath $script)) { throw "unknowntweaks.ps1 not found at $script. Run Compile.ps1 first." }

if (-not $Version) {
    $head = Get-Content -LiteralPath $script -TotalCount 12
    $m = @($head | Select-String -Pattern '^\s*Version\s*:\s*(\S+)')
    if ($m.Count) { $Version = $m[0].Matches[0].Groups[1].Value } else { $Version = '0.0.0' }
}
# Win32 file versions must be four numeric parts.
$fileVersion = ($Version -replace '[^0-9.]', '')
while (($fileVersion -split '\.').Count -lt 4) { $fileVersion += '.0' }

$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'The .NET Framework C# compiler was not found; this needs .NET Framework 4.x, which ships with Windows.' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('ut-exe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compat.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
    </application>
  </compatibility>
</assembly>
'@
    $manifestPath = Join-Path $work 'app.manifest'
    Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding UTF8

    $source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Reflection.Emit;

[assembly: AssemblyTitle("unknowntweaks")]
[assembly: AssemblyProduct("unknowntweaks")]
[assembly: AssemblyDescription("Free, open-source Windows gaming optimizer")]
[assembly: AssemblyCompany("UNKNOWN AIMER")]
[assembly: AssemblyCopyright("MIT")]
[assembly: AssemblyVersion("$fileVersion")]
[assembly: AssemblyFileVersion("$fileVersion")]

static class Launcher {
  [STAThread]
  static int Main(string[] args) {
    try {
      // A stable path, not a temp file: the script relaunches itself from its own path, so a file
      // deleted when this process exits would be gone before the elevated run reads it.
      string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "unknowntweaks", "app");
      Directory.CreateDirectory(dir);
      string path = Path.Combine(dir, "unknowntweaks.ps1");
      using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("script"))
      using (FileStream f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None)) {
        s.CopyTo(f);
      }
      string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
      ProcessStartInfo psi = new ProcessStartInfo(ps);
      psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + path + "\"";
      psi.UseShellExecute = false;
      psi.WindowStyle = ProcessWindowStyle.Hidden;
      Process p = Process.Start(psi);
      p.WaitForExit();
      return p.ExitCode;
    } catch (Exception ex) {
      Console.Error.WriteLine("unknowntweaks could not start: " + ex.Message);
      return 1;
    }
  }
}
"@
    $sourcePath = Join-Path $work 'Launcher.cs'
    Set-Content -LiteralPath $sourcePath -Value $source -Encoding UTF8

    $args = @(
        '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu'
        ('/out:' + $OutFile)
        ('/win32manifest:' + $manifestPath)
        ('/resource:' + $script + ',script')
    )
    # Without an icon the exe inherits the generic console-application one, which is what a file
    # people were told to download least wants to look like. Rebuild it with tools/New-UTIcon.ps1.
    $icon = Join-Path $root 'assets\icon.ico'
    if (Test-Path -LiteralPath $icon) { $args += ('/win32icon:' + $icon) }
    else { Write-Warning 'assets\icon.ico is missing; building without an icon. Run tools\New-UTIcon.ps1.' }
    $args += $sourcePath
    & $csc $args | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

    $info = Get-Item -LiteralPath $OutFile
    Write-Host ("Built {0} ({1:N0} bytes, version {2}, script {3:N0} bytes embedded)" -f $info.FullName, $info.Length, $Version, (Get-Item -LiteralPath $script).Length)
    Write-Host 'It is unsigned, so SmartScreen will warn the first people who run it. See docs/PUBLISHING.md.'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
