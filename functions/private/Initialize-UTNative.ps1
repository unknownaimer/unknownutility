function Initialize-UTNative {
    <#
    .SYNOPSIS
        Compiles the small C# helper set once per process (types are AppDomain-wide, so worker runspaces see them).
    .DESCRIPTION
        UT.NativeV1.PdhQuery : PDH query with PdhAddEnglishCounterW so counter paths work on non-English Windows.
        UT.NativeV1.Sys      : GetSystemTimes / GlobalMemoryStatusEx (CPU time and RAM without counters).
        UT.NativeV1.Win      : foreground window + fullscreen classification.
        UT.NativeV1.Dwm      : dark title bar.
        C# 5 only (the PowerShell 5.1 compiler does not know newer syntax).
    #>
    if ('UT.NativeV1.PdhQuery' -as [type]) { return $true }
    $src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace UT.NativeV1 {

  public class PdhSample { public string Instance; public double Value; public uint Status; }

  public static class Pdh {
    public const uint PDH_FMT_DOUBLE = 0x00000200, PDH_FMT_NOCAP100 = 0x00008000;
    public const uint PDH_MORE_DATA = 0x800007D2;
    public const uint PDH_CSTATUS_VALID_DATA = 0, PDH_CSTATUS_NEW_DATA = 1;

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    public struct PDH_FMT_COUNTERVALUE {
      [FieldOffset(0)] public uint CStatus;
      [FieldOffset(8)] public double doubleValue;
    }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] public static extern uint PdhOpenQueryW(string szDataSource, IntPtr dwUserData, out IntPtr phQuery);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] public static extern uint PdhAddEnglishCounterW(IntPtr hQuery, string szFullCounterPath, IntPtr dwUserData, out IntPtr phCounter);
    [DllImport("pdh.dll")] public static extern uint PdhCollectQueryData(IntPtr hQuery);
    [DllImport("pdh.dll")] public static extern uint PdhGetFormattedCounterValue(IntPtr hCounter, uint dwFormat, IntPtr lpdwType, out PDH_FMT_COUNTERVALUE pValue);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] public static extern uint PdhGetFormattedCounterArrayW(IntPtr hCounter, uint dwFormat, ref uint lpdwBufferSize, out uint lpdwItemCount, IntPtr ItemBuffer);
    [DllImport("pdh.dll")] public static extern uint PdhCloseQuery(IntPtr hQuery);
  }

  public class PdhQuery : IDisposable {
    IntPtr _q = IntPtr.Zero;
    readonly Dictionary<string, IntPtr> _counters = new Dictionary<string, IntPtr>(StringComparer.OrdinalIgnoreCase);
    public PdhQuery() {
      uint rc = Pdh.PdhOpenQueryW(null, IntPtr.Zero, out _q);
      if (rc != 0) throw new InvalidOperationException("PdhOpenQuery failed: 0x" + rc.ToString("X8"));
    }
    public bool AddEnglish(string key, string englishPath) {
      IntPtr h; uint rc = Pdh.PdhAddEnglishCounterW(_q, englishPath, IntPtr.Zero, out h);
      if (rc != 0) return false;
      _counters[key] = h; return true;
    }
    public bool Has(string key) { return _counters.ContainsKey(key); }
    public uint Collect() { return Pdh.PdhCollectQueryData(_q); }
    public double GetValue(string key, bool noCap100) {
      IntPtr h; if (!_counters.TryGetValue(key, out h)) return double.NaN;
      Pdh.PDH_FMT_COUNTERVALUE v;
      uint fmt = Pdh.PDH_FMT_DOUBLE | (noCap100 ? Pdh.PDH_FMT_NOCAP100 : 0u);
      uint rc = Pdh.PdhGetFormattedCounterValue(h, fmt, IntPtr.Zero, out v);
      if (rc != 0) return double.NaN;
      if (v.CStatus != Pdh.PDH_CSTATUS_VALID_DATA && v.CStatus != Pdh.PDH_CSTATUS_NEW_DATA) return double.NaN;
      return v.doubleValue;
    }
    public List<PdhSample> GetArray(string key, bool noCap100) {
      List<PdhSample> list = new List<PdhSample>();
      IntPtr h; if (!_counters.TryGetValue(key, out h)) return list;
      uint fmt = Pdh.PDH_FMT_DOUBLE | (noCap100 ? Pdh.PDH_FMT_NOCAP100 : 0u);
      uint size = 0, count = 0;
      uint rc = Pdh.PdhGetFormattedCounterArrayW(h, fmt, ref size, out count, IntPtr.Zero);
      if (rc != Pdh.PDH_MORE_DATA || size == 0) return list;
      IntPtr buf = Marshal.AllocHGlobal((int)size);
      try {
        rc = Pdh.PdhGetFormattedCounterArrayW(h, fmt, ref size, out count, buf);
        if (rc != 0) return list;
        const int itemSize = 24;
        for (int i = 0; i < count; i++) {
          IntPtr item = new IntPtr(buf.ToInt64() + (long)i * itemSize);
          IntPtr namePtr = Marshal.ReadIntPtr(item, 0);
          uint status = (uint)Marshal.ReadInt32(item, 8);
          double val = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(item, 16));
          PdhSample s = new PdhSample();
          s.Instance = namePtr == IntPtr.Zero ? "" : Marshal.PtrToStringUni(namePtr);
          s.Status = status;
          s.Value = (status == Pdh.PDH_CSTATUS_VALID_DATA || status == Pdh.PDH_CSTATUS_NEW_DATA) ? val : double.NaN;
          list.Add(s);
        }
      } finally { Marshal.FreeHGlobal(buf); }
      return list;
    }
    public void Dispose() { if (_q != IntPtr.Zero) { Pdh.PdhCloseQuery(_q); _q = IntPtr.Zero; } }
  }

  public static class Sys {
    [StructLayout(LayoutKind.Sequential)] public struct FILETIME { public uint Low; public uint High; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
    [StructLayout(LayoutKind.Sequential)]
    public class MEMORYSTATUSEX {
      public uint dwLength = 64; public uint dwMemoryLoad;
      public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
    static ulong ToU64(FILETIME ft) { return ((ulong)ft.High << 32) | ft.Low; }
    public class CpuTimes { public ulong Idle, Kernel, User; public bool Ok; }
    public static CpuTimes GetCpuTimes() {
      FILETIME i, k, u; CpuTimes t = new CpuTimes();
      t.Ok = GetSystemTimes(out i, out k, out u);
      if (t.Ok) { t.Idle = ToU64(i); t.Kernel = ToU64(k); t.User = ToU64(u); }
      return t;
    }
    public class MemInfo { public ulong TotalPhys, AvailPhys; public uint Load; public bool Ok; }
    public static MemInfo GetMem() {
      MEMORYSTATUSEX m = new MEMORYSTATUSEX(); MemInfo r = new MemInfo();
      r.Ok = GlobalMemoryStatusEx(m);
      if (r.Ok) { r.TotalPhys = m.ullTotalPhys; r.AvailPhys = m.ullAvailPhys; r.Load = m.dwMemoryLoad; }
      return r;
    }
  }

  public static class Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    public delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr hMon, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc cb, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong32(IntPtr hWnd, int nIndex);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT pv, int cb);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    const int GWL_STYLE = -16, DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    const long WS_CAPTION = 0x00C00000L;
    const uint MONITOR_DEFAULTTONEAREST = 2;
    static long GetWindowLongPtr(IntPtr hWnd, int nIndex) {
      return IntPtr.Size == 8 ? GetWindowLongPtr64(hWnd, nIndex).ToInt64() : (long)GetWindowLong32(hWnd, nIndex);
    }
    public class FgInfo {
      public IntPtr Hwnd; public uint Pid; public string ProcessName = ""; public string ClassName = "";
      public bool CoversMonitor; public bool Borderless; public int Quns; public bool IsShell; public bool HostedUwp;
    }
    public static FgInfo GetForeground() {
      FgInfo f = new FgInfo();
      f.Hwnd = GetForegroundWindow();
      int q; f.Quns = (SHQueryUserNotificationState(out q) == 0) ? q : 0;
      if (f.Hwnd == IntPtr.Zero) return f;
      f.IsShell = (f.Hwnd == GetShellWindow() || f.Hwnd == GetDesktopWindow());
      uint pid; GetWindowThreadProcessId(f.Hwnd, out pid); f.Pid = pid;
      StringBuilder sb = new StringBuilder(256); GetClassNameW(f.Hwnd, sb, 256); f.ClassName = sb.ToString();
      try { f.ProcessName = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
      if (string.Equals(f.ProcessName, "ApplicationFrameHost", StringComparison.OrdinalIgnoreCase)) {
        uint childPid = 0;
        EnumChildWindows(f.Hwnd, delegate(IntPtr h, IntPtr l) {
          StringBuilder cs = new StringBuilder(256); GetClassNameW(h, cs, 256);
          if (cs.ToString() == "Windows.UI.Core.CoreWindow") { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) { childPid = p; return false; } }
          return true;
        }, IntPtr.Zero);
        if (childPid != 0) { f.Pid = childPid; f.HostedUwp = true; try { f.ProcessName = System.Diagnostics.Process.GetProcessById((int)childPid).ProcessName; } catch { } }
      }
      RECT r;
      if (DwmGetWindowAttribute(f.Hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(f.Hwnd, out r);
      IntPtr mon = MonitorFromWindow(f.Hwnd, MONITOR_DEFAULTTONEAREST);
      MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
      if (mon != IntPtr.Zero && GetMonitorInfoW(mon, ref mi)) {
        const int tol = 2;
        f.CoversMonitor = r.Left <= mi.rcMonitor.Left + tol && r.Top <= mi.rcMonitor.Top + tol &&
                          r.Right >= mi.rcMonitor.Right - tol && r.Bottom >= mi.rcMonitor.Bottom - tol;
      }
      long style = GetWindowLongPtr(f.Hwnd, GWL_STYLE);
      f.Borderless = (style & WS_CAPTION) == 0;
      return f;
    }
  }

  public static class Dwm {
    [DllImport("dwmapi.dll", PreserveSig = true)] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("Shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  }
}
'@
    try {
        Add-Type -TypeDefinition $src -ErrorAction Stop
        return $true
    } catch {
        Write-UTLog ('Native helpers could not be compiled ({0}); the monitor falls back to WMI and the title bar stays light' -f $_.Exception.Message) -Level Warn
        return $false
    }
}
