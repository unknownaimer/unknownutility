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

  public static class Display {
    public class Mode { public int Width; public int Height; public int Hz; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
      public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
      public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
      public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
      public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
      public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct RATIONAL { public uint Numerator, Denominator; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_SOURCE_INFO { public LUID adapterId; public uint id, modeInfoIdx, statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_TARGET_INFO { public LUID adapterId; public uint id, modeInfoIdx, outputTechnology, rotation, scaling; public RATIONAL refreshRate; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO { public PATH_SOURCE_INFO sourceInfo; public PATH_TARGET_INFO targetInfo; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] public struct REGION2D { public uint cx, cy; }
    [StructLayout(LayoutKind.Sequential)] public struct VIDEO_SIGNAL_INFO { public ulong pixelRate; public RATIONAL hSyncFreq, vSyncFreq; public REGION2D activeSize, totalSize; public uint videoStandard, scanLineOrdering; }
    [StructLayout(LayoutKind.Sequential)] public struct SOURCE_MODE { public uint width, height, pixelFormat; public int x, y; }
    [StructLayout(LayoutKind.Explicit, Size = 48)] public struct MODE_UNION { [FieldOffset(0)] public VIDEO_SIGNAL_INFO targetVideoSignalInfo; [FieldOffset(0)] public SOURCE_MODE sourceMode; }
    [StructLayout(LayoutKind.Sequential)] public struct MODE_INFO { public uint infoType, id; public LUID adapterId; public MODE_UNION u; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr lparam);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, [Out] MODE_INFO[] modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint numPaths, PATH_INFO[] paths, uint numModes, MODE_INFO[] modes, uint flags);
    const int DM_PELSWIDTH = 0x80000, DM_PELSHEIGHT = 0x100000, DM_DISPLAYFREQUENCY = 0x400000;
    const uint CDS_UPDATEREGISTRY = 1, QDC_ONLY_ACTIVE_PATHS = 2;
    const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x20, SDC_APPLY = 0x80, SDC_SAVE_TO_DATABASE = 0x200, SDC_ALLOW_CHANGES = 0x400;
    static DEVMODE Blank() { DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }
    public static Mode GetCurrent() {
      DEVMODE d = Blank(); Mode m = new Mode();
      if (EnumDisplaySettingsW(null, -1, ref d)) { m.Width = d.dmPelsWidth; m.Height = d.dmPelsHeight; m.Hz = d.dmDisplayFrequency; }
      return m;
    }
    public static List<Mode> EnumModes() {
      List<Mode> list = new List<Mode>(); HashSet<string> seen = new HashSet<string>();
      DEVMODE d = Blank();
      for (int i = 0; EnumDisplaySettingsW(null, i, ref d); i++) {
        if (d.dmBitsPerPel != 32) continue;
        string k = d.dmPelsWidth + "x" + d.dmPelsHeight + "@" + d.dmDisplayFrequency;
        if (!seen.Add(k)) continue;
        Mode m = new Mode(); m.Width = d.dmPelsWidth; m.Height = d.dmPelsHeight; m.Hz = d.dmDisplayFrequency; list.Add(m);
      }
      return list;
    }
    public static int SetMode(int width, int height, int hz, bool persist) {
      DEVMODE d = Blank();
      d.dmPelsWidth = width; d.dmPelsHeight = height; d.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
      if (hz > 0) { d.dmDisplayFrequency = hz; d.dmFields |= DM_DISPLAYFREQUENCY; }
      return ChangeDisplaySettingsExW(null, ref d, IntPtr.Zero, persist ? CDS_UPDATEREGISTRY : 0, IntPtr.Zero);
    }
    static int Query(out PATH_INFO[] paths, out MODE_INFO[] modes, out uint np, out uint nm) {
      paths = null; modes = null; np = 0; nm = 0;
      int rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm);
      if (rc != 0) return rc;
      paths = new PATH_INFO[np]; modes = new MODE_INFO[nm];
      return QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);
    }
    static int Primary(PATH_INFO[] paths, MODE_INFO[] modes, uint np) {
      for (int i = 0; i < np; i++) {
        uint idx = paths[i].sourceInfo.modeInfoIdx;
        if (idx < modes.Length && modes[idx].u.sourceMode.x == 0 && modes[idx].u.sourceMode.y == 0) return i;
      }
      return np > 0 ? 0 : -1;
    }
    public static uint GetScaling() {
      PATH_INFO[] paths; MODE_INFO[] modes; uint np, nm;
      if (Query(out paths, out modes, out np, out nm) != 0) return 0;
      int p = Primary(paths, modes, np);
      return p < 0 ? 0 : paths[p].targetInfo.scaling;
    }
    public static int SetScaling(uint scaling) {
      PATH_INFO[] paths; MODE_INFO[] modes; uint np, nm;
      int rc = Query(out paths, out modes, out np, out nm);
      if (rc != 0) return rc;
      int p = Primary(paths, modes, np);
      if (p < 0) return -1;
      paths[p].targetInfo.scaling = scaling;
      return SetDisplayConfig(np, paths, nm, modes, SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES);
    }
    public static string StructSizes() { return Marshal.SizeOf(typeof(PATH_INFO)) + "," + Marshal.SizeOf(typeof(MODE_INFO)); }
  }

  public static class NvApi {
    [StructLayout(LayoutKind.Sequential, Pack = 8)] public struct TIMINGEXT { public uint flag; public ushort rr; public uint rrx1k, aspect; public ushort rep; public uint status; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 40)] public byte[] name; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)] public struct TIMING { public ushort HVisible, HBorder, HFrontPorch, HSyncWidth, HTotal; public byte HSyncPol; public ushort VVisible, VBorder, VFrontPorch, VSyncWidth, VTotal; public byte VSyncPol; public ushort interlaced; public uint pclk; public TIMINGEXT etc; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)] public struct TIMING_FLAG { public uint interlacedAndReserved, formatUnion, scaling; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)] public struct TIMING_INPUT { public uint version, width, height; public float rr; public TIMING_FLAG flag; public uint type; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)] public struct VIEWPORTF { public float x, y, w, h; }
    [StructLayout(LayoutKind.Sequential, Pack = 8)] public struct CUSTOM_DISPLAY { public uint version, width, height, depth, colorFormat; public VIEWPORTF srcPartition; public float xRatio, yRatio; public TIMING timing; public uint hwModeSetOnly; }
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr QueryInterface(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int InitializeFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int PrimaryIdFn(out uint displayId);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetTimingFn(uint displayId, ref TIMING_INPUT input, out TIMING timing);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int TryFn(ref uint displayId, uint count, ref CUSTOM_DISPLAY cd);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SaveFn(ref uint displayId, uint count, uint outputOnly, uint monitorOnly);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int RevertFn(ref uint displayId, uint count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int EnumFn(uint displayId, uint index, ref CUSTOM_DISPLAY cd);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int DeleteFn(ref uint displayId, uint count, ref CUSTOM_DISPLAY cd);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ErrorFn(int status, StringBuilder text);
    const uint ID_Initialize = 0x0150E828, ID_PrimaryId = 0x1E9D8A31, ID_GetTiming = 0x175167E9, ID_Try = 0x1F7DB630, ID_Save = 0x49882876, ID_Revert = 0xCBBD40F0, ID_Enum = 0xA2072D59, ID_Delete = 0x552E5B9B, ID_Error = 0x6C2D048C;
    const uint TIMING_INPUT_VER = 32 | (1 << 16), CUSTOM_DISPLAY_VER = 144 | (1 << 16);
    const uint OVERRIDE_AUTO = 1, OVERRIDE_CVT_RB = 6;
    static T Fn<T>(uint id) where T : class {
      IntPtr p = QueryInterface(id);
      if (p == IntPtr.Zero) throw new InvalidOperationException("NvAPI function 0x" + id.ToString("X") + " not exported by this driver");
      return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
    }
    static string Err(int status) {
      try { StringBuilder sb = new StringBuilder(64); Fn<ErrorFn>(ID_Error)(status, sb); return "NvAPI error " + status + " (" + sb + ")"; }
      catch { return "NvAPI error " + status; }
    }
    public static string StructSizes() { return Marshal.SizeOf(typeof(TIMING_INPUT)) + "," + Marshal.SizeOf(typeof(TIMING)) + "," + Marshal.SizeOf(typeof(CUSTOM_DISPLAY)); }
    public static bool IsAvailable() {
      try { return Fn<InitializeFn>(ID_Initialize)() == 0; } catch { return false; }
    }
    static uint PrimaryId() {
      int rc = Fn<InitializeFn>(ID_Initialize)(); if (rc != 0) throw new InvalidOperationException(Err(rc));
      uint id; rc = Fn<PrimaryIdFn>(ID_PrimaryId)(out id); if (rc != 0) throw new InvalidOperationException(Err(rc));
      return id;
    }
    public static bool HasMode(int width, int height) {
      uint id = PrimaryId(); EnumFn e = Fn<EnumFn>(ID_Enum);
      for (uint i = 0; i < 64; i++) {
        CUSTOM_DISPLAY cd = new CUSTOM_DISPLAY(); cd.version = CUSTOM_DISPLAY_VER;
        if (e(id, i, ref cd) != 0) break;
        if (cd.width == width && cd.height == height) return true;
      }
      return false;
    }
    public static string AddMode(int width, int height, int hz) {
      if (Marshal.SizeOf(typeof(CUSTOM_DISPLAY)) != 144 || Marshal.SizeOf(typeof(TIMING_INPUT)) != 32) return "struct layout mismatch " + StructSizes();
      uint id = PrimaryId();
      TIMING_INPUT ti = new TIMING_INPUT(); ti.version = TIMING_INPUT_VER; ti.width = (uint)width; ti.height = (uint)height; ti.rr = hz; ti.type = OVERRIDE_AUTO;
      TIMING timing;
      int rc = Fn<GetTimingFn>(ID_GetTiming)(id, ref ti, out timing);
      if (rc != 0) { ti.type = OVERRIDE_CVT_RB; rc = Fn<GetTimingFn>(ID_GetTiming)(id, ref ti, out timing); }
      if (rc != 0) return "GetTiming: " + Err(rc);
      CUSTOM_DISPLAY cd = new CUSTOM_DISPLAY();
      cd.version = CUSTOM_DISPLAY_VER; cd.width = (uint)width; cd.height = (uint)height; cd.depth = 32; cd.colorFormat = 0;
      cd.srcPartition.x = 0; cd.srcPartition.y = 0; cd.srcPartition.w = 1; cd.srcPartition.h = 1; cd.xRatio = 1; cd.yRatio = 1; cd.timing = timing; cd.hwModeSetOnly = 0;
      rc = Fn<TryFn>(ID_Try)(ref id, 1, ref cd);
      if (rc != 0) return "TryCustomDisplay: " + Err(rc);
      rc = Fn<SaveFn>(ID_Save)(ref id, 1, 0, 0);
      int rv = Fn<RevertFn>(ID_Revert)(ref id, 1);
      if (rc != 0) return "SaveCustomDisplay: " + Err(rc);
      return rv == 0 ? "ok" : "ok (revert of the trial mode reported " + Err(rv) + ")";
    }
    public static string DeleteMode(int width, int height) {
      uint id = PrimaryId(); EnumFn e = Fn<EnumFn>(ID_Enum);
      for (uint i = 0; i < 64; i++) {
        CUSTOM_DISPLAY cd = new CUSTOM_DISPLAY(); cd.version = CUSTOM_DISPLAY_VER;
        if (e(id, i, ref cd) != 0) break;
        if (cd.width != width || cd.height != height) continue;
        int rc = Fn<DeleteFn>(ID_Delete)(ref id, 1, ref cd);
        return rc == 0 ? "ok" : "DeleteCustomDisplay: " + Err(rc);
      }
      return "not found";
    }
  }

  public static class Bench {
    static ulong sink;
    static double Loop(int ms) {
      ulong x = 88172645463325252UL; double f = 1.0; long n = 0;
      System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
      while (sw.ElapsedMilliseconds < ms) {
        for (int i = 0; i < 100000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; f = f * 1.0000001 + (x & 0xFF); }
        n += 100000;
      }
      sink += x + (ulong)f;
      return n / sw.Elapsed.TotalSeconds;
    }
    public static double CpuSingle(int ms) { return Loop(ms); }
    public static double CpuMulti(int ms, int threads) {
      double[] r = new double[threads]; System.Threading.Thread[] t = new System.Threading.Thread[threads];
      for (int i = 0; i < threads; i++) { int k = i; t[i] = new System.Threading.Thread(delegate() { r[k] = Loop(ms); }); t[i].Start(); }
      for (int i = 0; i < threads; i++) t[i].Join();
      double sum = 0; foreach (double v in r) sum += v; return sum;
    }
    public static double MemCopy(int mb, int passes) {
      byte[] a = new byte[mb * 1024 * 1024], b = new byte[mb * 1024 * 1024];
      Buffer.BlockCopy(a, 0, b, 0, a.Length);
      System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
      for (int i = 0; i < passes; i++) { Buffer.BlockCopy(a, 0, b, 0, a.Length); Buffer.BlockCopy(b, 0, a, 0, a.Length); }
      return (2.0 * passes * a.Length) / sw.Elapsed.TotalSeconds / (1024.0 * 1024.0 * 1024.0);
    }
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
