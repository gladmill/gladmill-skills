# Runs in the interactive session (started by ui.ps1): drives AutoCAD's UI step by step. Steps come from <home>\ui.txt, one per line
# (# comments); the result goes to <home>\out\ui-result.txt and "<RunId> <exit code>" to out\ui-done.txt. Steps:
#   command <text>          start a command at the Command: prompt and go on at once (a dialog it opens doesn't block the run);
#                           \n = Enter, an Enter is added at the end; refused while another command or prompt is active
#   type <text>             type text on the command line as it is (answers the prompt that is waiting)
#   idle [sec]              wait until AutoCAD is quiescent: no command, prompt or modal dialog
#   ribbon [<tab>/][<panel>/]<button>   click a ribbon button (labels or ids; a panel name opens its slide-out if needed)
#   dialog <title>          wait for a dialog with that title (* wildcards) and make it the target of the steps below
#   alert [<title>]         wait for a message box (LISP alert, MessageBox, task dialog), print its text, make it the target
#   read                    print the target's controls and values
#   set <label>=<value>     fill a control: edit box, drop-down, list (a;b for several), check box or radio button (on/off)
#   press <button>          press a button in the target
#   expect <regex>          fail unless the target's title, texts and values match
#   closed [<title>]        wait until the target (or a dialog with that title) has closed
#   dialogs                 list AutoCAD's dialogs (title, class, enabled, visible, in front, off screen)
#   front [<title>]         bring the target (or AutoCAD) to the front, moving an off-screen dialog onto the screen
#   keys <sendkeys>         real keystrokes to the target (brought to the front first)    click <x>,<y>   real click at a screen point
#   click <label>           real mouse click on a control of the target (a recorder sees which button closed the dialog)
#   move <x>,<y>            rest the mouse there (no click)
#   shot [name]             screenshot to out\<name>.png                                  sleep <ms>      timeout <sec> (wait per step)
# Dialogs are found among all of acad.exe's windows, in front or not, and filled with window messages or UI Automation, which don't need
# them in front. Only ribbon, click and keys use real input. Security prompts are never answered: a person decides those.
param([string]$RunId = '', [int]$StepTimeoutSec = 20)
. (Join-Path $PSScriptRoot 'common.ps1')
$out = $script:Out
$resFile = Join-Path $out 'ui-result.txt'; '' | Set-Content $resFile -Encoding UTF8
$runFile = Join-Path $out 'ui-run.txt'
function Current { -not $RunId -or "$(Get-Content $runFile -Raw -EA SilentlyContinue)".Trim() -eq $RunId }
function W($s) { if (Current) { Add-Content $resFile $s -Encoding UTF8 } }
function Finish([int]$code) {
  if (Current) { "$RunId $code" | Set-Content (Join-Path $out 'ui-done.txt') }
  [Environment]::Exit($code)
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
$helper = @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Threading;
using System.Windows.Automation;

public class KitEl {
  public AutomationElement E; public string Name = ""; public string Id = ""; public string Type = ""; public string Cls = "";
  public double X, Y, W, H; public bool Off;
}

public class KitCtl {
  public IntPtr H; public int Id; public string Cls = ""; public string Kind = ""; public string Text = ""; public string Label = "";
  public bool Visible; public bool Enabled; public int Style;
}

public static class KitUi {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromRect(ref RECT r, uint f);
  [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] static extern void mouse_event(uint f, int x, int y, uint d, UIntPtr e);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")] static extern IntPtr SMT(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)] static extern IntPtr SMTs(IntPtr h, uint m, IntPtr w, string l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)] static extern IntPtr SMTb(IntPtr h, uint m, IntPtr w, StringBuilder l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  const uint SMTO_ABORTIFHUNG = 2;
  const uint WM_COMMAND = 0x0111, WM_SETTEXT = 0x000C, WM_GETTEXT = 0x000D, WM_GETTEXTLENGTH = 0x000E;
  const uint BM_GETCHECK = 0x00F0, BM_SETCHECK = 0x00F1;
  const uint CB_GETCOUNT = 0x0146, CB_GETCURSEL = 0x0147, CB_GETLBTEXT = 0x0148, CB_GETLBTEXTLEN = 0x0149, CB_FINDSTRINGEXACT = 0x0158, CB_SETCURSEL = 0x014E;
  const uint LB_GETCOUNT = 0x018B, LB_GETCURSEL = 0x0188, LB_GETSEL = 0x0187, LB_GETTEXT = 0x0189, LB_GETTEXTLEN = 0x018A, LB_SETSEL = 0x0185, LB_SETCURSEL = 0x0186, LB_FINDSTRINGEXACT = 0x01A2;

  public static void DpiAware() {
    // physical pixels everywhere: UI Automation rectangles and SetCursorPos then agree at any display scaling
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch (Exception) { }
    try { SetProcessDPIAware(); } catch (Exception) { }
  }

  // ---- windows -------------------------------------------------------------------------------------------------
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Caption(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static int Style(IntPtr h) { return GetWindowLong(h, -16); }
  public static int CtrlId(IntPtr h) { return GetDlgCtrlID(h); }
  public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }
  public static uint Thread(IntPtr h) { uint p; return GetWindowThreadProcessId(h, out p); }

  // Sends with a timeout, so a hung or busy AutoCAD never hangs the run. ok = false when it timed out (the window may still be
  // working on it, e.g. a button whose handler opened a modal dialog).
  public static IntPtr Send(IntPtr h, uint m, IntPtr w, IntPtr l, uint ms, out bool ok) {
    IntPtr r; ok = SMT(h, m, w, l, SMTO_ABORTIFHUNG, ms, out r) != IntPtr.Zero; return r;
  }
  public static int SendInt(IntPtr h, uint m, int w, int l) { bool ok; return Send(h, m, new IntPtr(w), new IntPtr(l), 3000, out ok).ToInt32(); }
  public static bool Post(IntPtr h, uint m, IntPtr w, IntPtr l) { return PostMessage(h, m, w, l); }

  // A control's text, also for controls of another process (GetWindowText reads only captions there).
  public static string Text(IntPtr h) {
    bool ok; int n = Send(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero, 2000, out ok).ToInt32();
    if (!ok || n <= 0) return "";
    var b = new StringBuilder(n + 2); IntPtr r;
    SMTb(h, WM_GETTEXT, new IntPtr(n + 1), b, SMTO_ABORTIFHUNG, 2000, out r);
    return b.ToString();
  }
  public static bool SetText(IntPtr h, string s) { IntPtr r; return SMTs(h, WM_SETTEXT, IntPtr.Zero, s, SMTO_ABORTIFHUNG, 3000, out r) != IntPtr.Zero; }

  // Top-level windows of a process, front to back (EnumWindows order is the z-order).
  public static List<IntPtr> Tops(uint pid) {
    var l = new List<IntPtr>();
    EnumWindows(delegate (IntPtr h, IntPtr x) { if (Pid(h) == pid) l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
  public static List<IntPtr> Kids(IntPtr w) {
    var l = new List<IntPtr>();
    EnumChildWindows(w, delegate (IntPtr h, IntPtr x) { l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
  // AutoCAD's main frame: the visible, unowned top-level window of MFC's frame class (AfxMDIFrame140u on 2024-2026).
  public static IntPtr Frame(uint pid) {
    foreach (var h in Tops(pid))
      if (IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && Cls(h).StartsWith("AfxMDIFrame")) return h;
    return IntPtr.Zero;
  }
  // Dialog-like top-level windows: Win32 / MFC / task dialogs (#32770), DCL dialogs (adesk_dlg*), titled WinForms and WPF windows.
  // Not the frame, palettes (Afx:...), menus, tool tips, drop-down lists or the untitled WPF helper windows.
  public static bool IsDialog(IntPtr h) {
    string c = Cls(h);
    if (c == "#32770" || c.StartsWith("adesk_dlg")) return true;
    if (Caption(h).Length == 0) return false;
    return c.StartsWith("WindowsForms10.Window") || c.StartsWith("HwndWrapper");
  }
  public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
  // True when no part of the window is on any monitor (a position remembered from a monitor that is gone).
  public static bool OffScreen(IntPtr h) { RECT r = Rect(h); return MonitorFromRect(ref r, 0) == IntPtr.Zero; }
  public static void MoveOnScreen(IntPtr h) {
    RECT r = Rect(h); var wa = System.Windows.Forms.Screen.PrimaryScreen.WorkingArea;
    int x = wa.Left + Math.Max(0, (wa.Width - (r.R - r.L)) / 2), y = wa.Top + Math.Max(0, (wa.Height - (r.B - r.T)) / 2);
    SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);   // NOSIZE | NOZORDER | NOACTIVATE
  }

  // ---- foreground ----------------------------------------------------------------------------------------------
  // Windows lets only the foreground owner (or the process that got the last input) hand over the foreground: attach to the
  // foreground thread first; if that is not enough, tap Alt (a hidden task got no input yet). The tap goes to the window in
  // front, so it is skipped when that is one of the target's own process (it would turn on the ribbon's key tips, which eat
  // typed letters). No Esc: it would cancel a command.
  public static bool Front(IntPtr h) { return Front(h, true); }
  // alt = false: only the quiet attempt (attach to the foreground thread). The Alt tap puts AutoCAD into menu mode for a moment, which
  // a recorder watching AutoCAD (Retrace) sees as a modal window.
  public static bool Front(IntPtr h, bool alt) {
    if (IsIconic(h)) ShowWindow(h, 9);
    if (GetForegroundWindow() == h) return true;
    for (int attempt = 0; attempt < (alt ? 2 : 1); attempt++) {
      IntPtr fg = GetForegroundWindow(); uint me = GetCurrentThreadId(), t = fg == IntPtr.Zero ? 0 : Thread(fg);
      bool att = t != 0 && t != me && AttachThreadInput(me, t, true);
      if (attempt == 1 && (fg == IntPtr.Zero || Pid(fg) != Pid(h))) { keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); }
      BringWindowToTop(h); SetForegroundWindow(h);
      if (att) AttachThreadInput(me, t, false);
      System.Threading.Thread.Sleep(250);
      if (GetForegroundWindow() == h) return true;
    }
    return false;
  }
  // The top-level window under a screen point (what a real click there would hit).
  public static IntPtr RootAt(int x, int y) {
    var p = new POINT(); p.X = x; p.Y = y;
    IntPtr w = WindowFromPoint(p); return w == IntPtr.Zero ? w : GetAncestor(w, 2);
  }
  public static void Move(int x, int y) { SetCursorPos(x, y); }
  public static void Click(int x, int y) {
    SetCursorPos(x, y); System.Threading.Thread.Sleep(120);
    mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(40); mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
  }

  // Types text on AutoCAD's command line: WM_COPYDATA to the main frame (dwData 1, Unicode text), which AutoCAD treats as typed
  // input for the active drawing. Returns at once; unlike a COM SendCommand there is no call left waiting while the command
  // runs (a COM caller that went away while a DCL dialog was open left the dialog ignoring its buttons until real input came).
  [StructLayout(LayoutKind.Sequential)] struct COPYDATA { public IntPtr dwData; public int cbData; public IntPtr lpData; }
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")] static extern IntPtr SMTcd(IntPtr h, uint m, IntPtr w, ref COPYDATA l, uint f, uint t, out IntPtr r);
  public static bool TypeText(IntPtr frame, string text) {
    var cd = new COPYDATA(); cd.dwData = new IntPtr(1); cd.cbData = (text.Length + 1) * 2; cd.lpData = Marshal.StringToHGlobalUni(text);
    try { IntPtr r; return SMTcd(frame, 0x004A, IntPtr.Zero, ref cd, SMTO_ABORTIFHUNG, 5000, out r) != IntPtr.Zero; }
    finally { Marshal.FreeHGlobal(cd.lpData); }
  }

  // ---- labels and matching ---------------------------------------------------------------------------------------
  // "&Name:" -> "name"; also drops a trailing ":" and spaces (DCL pads button labels: "  OK  ").
  public static string Norm(string s) {
    if (s == null) return "";
    s = s.Replace("&", "").Replace('\u00a0', ' ').Trim();
    s = System.Text.RegularExpressions.Regex.Replace(s, @"\s+", " ");
    if (s.EndsWith(":")) s = s.Substring(0, s.Length - 1).TrimEnd();
    return s.ToLowerInvariant();
  }
  static string NoDots(string s) { s = Norm(s); if (s.EndsWith("...")) s = s.Substring(0, s.Length - 3); if (s.EndsWith("\u2026")) s = s.Substring(0, s.Length - 1); return s.TrimEnd(); }
  // exact (normalized) first; a label written without its "..." also matches
  public static int Match(string have, string want) {
    if (Norm(have) == Norm(want)) return 2;
    if (NoDots(have) == NoDots(want) && NoDots(have).Length > 0) return 1;
    return 0;
  }
  // The label starts with what was written, then a space or "(" ("Save names" for "Save names (1)", a count the program adds). Only
  // for controls, and only when one control matches this way (Find-Ctl, Find-Elem); titles, tabs and list items match exactly.
  public static bool Starts(string have, string want) {
    string h = Norm(have), w = Norm(want);
    return w.Length > 0 && h.Length > w.Length && h.StartsWith(w, StringComparison.Ordinal) && (h[w.Length] == ' ' || h[w.Length] == '(');
  }

  // How a label reads on screen: "&&" is a literal "&", a single "&" marks the access key; lines joined.
  public static string Show(string s) {
    if (s == null) return "";
    s = s.Replace("&&", "\u0001").Replace("&", "").Replace("\u0001", "&");
    return System.Text.RegularExpressions.Regex.Replace(s, @"\s+", " ").Trim();
  }

  public static string KindOf(IntPtr h, string cls, int style) {
    string c = cls.ToLowerInvariant();
    if (c == "button") {
      switch (style & 0xF) {
        case 2: case 3: case 5: case 6: return "check";
        case 4: case 9: return "radio";
        case 7: return "group";
        case 0xB: return "ownerdrawn";
        default: return "button";
      }
    }
    if (c == "edit" || c.StartsWith("richedit")) return "edit";
    if (c == "combobox") return "combo";
    if (c == "listbox") return "list";
    if (c == "static") return "text";
    if (c.StartsWith("windowsforms10.button")) return "ownerdrawn";
    if (c.StartsWith("windowsforms10.edit")) return "edit";
    if (c.StartsWith("windowsforms10.combobox")) return "combo";
    if (c.StartsWith("windowsforms10.listbox")) return "list";
    if (c.StartsWith("windowsforms10.static")) return "text";
    return "other";
  }

  // The dialog's Win32 controls, each with the label a person reads next to it: its own text for buttons, check boxes and
  // radio buttons; for edit boxes, drop-downs and lists the nearest text before it in tab order (how DCL and dialog
  // templates place "Name:" before the box), else the text just left of it on the same row.
  public static List<KitCtl> Controls(IntPtr dlg) {
    var all = new List<KitCtl>();
    foreach (var h in Kids(dlg)) {
      if (Cls(GetParent(h)).ToLowerInvariant().Contains("combobox")) continue;   // the edit inside an editable drop-down: the combo is the control
      var k = new KitCtl(); k.H = h; k.Cls = Cls(h); k.Style = Style(h); k.Id = CtrlId(h);
      k.Kind = KindOf(h, k.Cls, k.Style); k.Visible = IsWindowVisible(h); k.Enabled = IsWindowEnabled(h);
      k.Text = (k.Kind == "edit" || k.Kind == "combo" || k.Kind == "list") ? "" : Text(h);
      all.Add(k);
    }
    foreach (var k in all) {
      if (k.Kind == "button" || k.Kind == "check" || k.Kind == "radio" || k.Kind == "ownerdrawn" || k.Kind == "group") { k.Label = k.Text; continue; }
      if (k.Kind != "edit" && k.Kind != "combo" && k.Kind != "list") continue;
      for (IntPtr p = GetWindow(k.H, 3); p != IntPtr.Zero; p = GetWindow(p, 3)) {   // GW_HWNDPREV
        string pc = KindOf(p, Cls(p), Style(p));
        if (pc == "text") { string t = Text(p); if (Norm(t).Length > 0) { k.Label = t; break; } continue; }
        if (pc == "group") continue;
        if (pc == "edit" || pc == "combo" || pc == "list" || pc == "button" || pc == "check" || pc == "radio") break;
      }
      if (k.Label.Length > 0) continue;
      RECT kr = Rect(k.H); int best = int.MaxValue;
      // a box alone in a group box ("Description") is named by the group
      long area = long.MaxValue;   // the innermost group box around it
      foreach (var g in all) {
        if (g.Kind != "group" || !g.Visible || Norm(g.Text).Length == 0) continue;
        RECT gr = Rect(g.H); long a = (long)(gr.R - gr.L) * (gr.B - gr.T);
        if (gr.L <= kr.L && gr.T <= kr.T && gr.R >= kr.R && gr.B >= kr.B && a < area) { area = a; k.Label = g.Text; }
      }
      if (k.Label.Length > 0) continue;
      foreach (var s in all) {
        if (s.Kind != "text" || !s.Visible || Norm(s.Text).Length == 0) continue;
        RECT sr = Rect(s.H); int mid = (kr.T + kr.B) / 2;
        if (sr.R <= kr.L + 2 && sr.T <= mid && sr.B >= mid && kr.L - sr.R < best) { best = kr.L - sr.R; k.Label = s.Text; }
      }
    }
    return all;
  }

  // ---- values -------------------------------------------------------------------------------------------------------
  static string ComboItem(IntPtr h, int i) { int n = SendInt(h, CB_GETLBTEXTLEN, i, 0); if (n < 0) return ""; var b = new StringBuilder(n + 2); IntPtr r; SMTb(h, CB_GETLBTEXT, new IntPtr(i), b, SMTO_ABORTIFHUNG, 2000, out r); return b.ToString(); }
  static string ListItem(IntPtr h, int i) { int n = SendInt(h, LB_GETTEXTLEN, i, 0); if (n < 0) return ""; var b = new StringBuilder(n + 2); IntPtr r; SMTb(h, LB_GETTEXT, new IntPtr(i), b, SMTO_ABORTIFHUNG, 2000, out r); return b.ToString(); }
  public static List<string> Items(KitCtl k) {
    var l = new List<string>();
    if (k.Kind == "combo") { int n = SendInt(k.H, CB_GETCOUNT, 0, 0); for (int i = 0; i < n && i < 500; i++) l.Add(ComboItem(k.H, i)); }
    if (k.Kind == "list") { int n = SendInt(k.H, LB_GETCOUNT, 0, 0); for (int i = 0; i < n && i < 500; i++) l.Add(ListItem(k.H, i)); }
    return l;
  }
  static bool MultiList(KitCtl k) { return (k.Style & 0x0008) != 0 || (k.Style & 0x0800) != 0; }   // LBS_MULTIPLESEL, LBS_EXTENDEDSEL
  public static string Value(KitCtl k) {
    switch (k.Kind) {
      case "edit": return Text(k.H);
      case "check": case "radio": { int v = SendInt(k.H, BM_GETCHECK, 0, 0); return v == 1 ? "on" : v == 2 ? "mixed" : "off"; }
      case "combo": { int i = SendInt(k.H, CB_GETCURSEL, 0, 0); return i >= 0 ? ComboItem(k.H, i) : Text(k.H); }
      case "list": {
        var sel = new List<string>(); int n = SendInt(k.H, LB_GETCOUNT, 0, 0);
        if (MultiList(k)) { for (int i = 0; i < n && i < 500; i++) if (SendInt(k.H, LB_GETSEL, i, 0) > 0) sel.Add(ListItem(k.H, i)); }
        else { int i = SendInt(k.H, LB_GETCURSEL, 0, 0); if (i >= 0) sel.Add(ListItem(k.H, i)); }
        return string.Join(";", sel.ToArray());
      }
      default: return k.Text;
    }
  }

  // ---- actions --------------------------------------------------------------------------------------------------------
  // The parent hears about a change through WM_COMMAND, as when a person does it. Sent with a short timeout: quick handlers
  // finish before the next step; one that opens a modal dialog (a DCL action calling alert) keeps running and the run goes on.
  public static bool Notify(KitCtl k, int code) {
    bool ok; IntPtr parent = GetParent(k.H);
    Send(parent, WM_COMMAND, new IntPtr((code << 16) | (k.Id & 0xFFFF)), k.H, 1500, out ok);
    return ok;
  }
  // Edit box: new text, EN_CHANGE, then EN_KILLFOCUS (DCL runs an edit_box action when the box loses the focus).
  public static string SetEdit(KitCtl k, string v) {
    if (!SetText(k.H, v)) return "the edit box did not answer";
    Notify(k, 0x0300); Notify(k, 0x0200);
    return null;
  }
  public static string SetCheck(KitCtl k, bool on) {
    int want = on ? 1 : 0;
    if (SendInt(k.H, BM_GETCHECK, 0, 0) == want) return null;
    int t = k.Style & 0xF;
    if (t == 2 || t == 5) { Notify(k, 0); if (SendInt(k.H, BM_GETCHECK, 0, 0) == want) return null; }   // the program toggles it
    SendInt(k.H, BM_SETCHECK, want, 0); Notify(k, 0);
    return SendInt(k.H, BM_GETCHECK, 0, 0) == want ? null : "the check box did not change";
  }
  // Radio button: BN_CLICKED (DCL and programs with plain radio buttons check it and clear the group); an auto radio button
  // is checked here and its group cleared first.
  public static string SetRadio(KitCtl k, List<KitCtl> all) {
    if ((k.Style & 0xF) == 4) { Notify(k, 0); if (SendInt(k.H, BM_GETCHECK, 0, 0) == 1) return null; }
    // the group: from the control with WS_GROUP at or before it, up to the next WS_GROUP
    int i = all.FindIndex(delegate (KitCtl c) { return c.H == k.H; }), a = i;
    while (a > 0 && (all[a].Style & 0x00020000) == 0) a--;
    for (int j = a; j < all.Count; j++) {
      if (j > a && (all[j].Style & 0x00020000) != 0) break;
      if (all[j].Kind == "radio" && all[j].H != k.H) SendInt(all[j].H, BM_SETCHECK, 0, 0);
    }
    SendInt(k.H, BM_SETCHECK, 1, 0); Notify(k, 0);
    return SendInt(k.H, BM_GETCHECK, 0, 0) == 1 ? null : "the radio button did not change";
  }
  public static string SetCombo(KitCtl k, string v) {
    IntPtr r; if (SMTs(k.H, CB_FINDSTRINGEXACT, new IntPtr(-1), v, SMTO_ABORTIFHUNG, 2000, out r) == IntPtr.Zero) return "the dialog did not answer (busy?)";
    int i = r.ToInt32();
    if (i < 0) {
      if ((k.Style & 0x3) == 2 || (k.Style & 0x3) == 1) { SetText(k.H, v); Notify(k, 5); return null; }   // editable: type it (CBN_EDITCHANGE)
      return "no item '" + v + "' (items: " + string.Join(" | ", Items(k).ToArray()) + ")";
    }
    SendInt(k.H, CB_SETCURSEL, i, 0); Notify(k, 1); Notify(k, 9);   // CBN_SELCHANGE, CBN_SELENDOK
    return null;
  }
  public static string SetList(KitCtl k, string[] vals) {
    var idx = new List<int>();
    foreach (var v in vals) {
      IntPtr r; if (SMTs(k.H, LB_FINDSTRINGEXACT, new IntPtr(-1), v, SMTO_ABORTIFHUNG, 2000, out r) == IntPtr.Zero) return "the dialog did not answer (busy?)";
      int i = r.ToInt32(); if (i < 0) return "no item '" + v + "' (items: " + string.Join(" | ", Items(k).ToArray()) + ")";
      idx.Add(i);
    }
    if (MultiList(k)) { SendInt(k.H, LB_SETSEL, 0, -1); foreach (int i in idx) SendInt(k.H, LB_SETSEL, 1, i); }
    else { if (idx.Count != 1) return "this list takes one item"; SendInt(k.H, LB_SETCURSEL, idx[0], 0); }
    Notify(k, 1);   // LBN_SELCHANGE
    return null;
  }
  // Push button: WM_COMMAND BN_CLICKED to its parent, which is what a click delivers to a dialog; works in front or not.
  public static string Press(KitCtl k) {
    if (!k.Enabled) return "the button is disabled";
    Notify(k, 0);
    return null;
  }

  // ---- UI Automation (WPF, WinForms owner-drawn buttons, task dialogs, the ribbon) --------------------------------------
  // Elements come as snapshots: one FindAll with a cache request fetches a whole subtree's names, ids, types and rectangles in
  // one cross-process call (walking element by element took seconds on the ribbon).
  public static AutomationElement Elem(IntPtr h) { try { return AutomationElement.FromHandle(h); } catch (Exception) { return null; } }
  public static List<KitEl> Descendants(AutomationElement root, int max) {
    var l = new List<KitEl>(); if (root == null) return l;
    var cr = new CacheRequest();
    cr.Add(AutomationElement.NameProperty); cr.Add(AutomationElement.AutomationIdProperty); cr.Add(AutomationElement.ControlTypeProperty);
    cr.Add(AutomationElement.BoundingRectangleProperty); cr.Add(AutomationElement.IsOffscreenProperty); cr.Add(AutomationElement.ClassNameProperty);
    cr.TreeFilter = Automation.ControlViewCondition; cr.AutomationElementMode = AutomationElementMode.Full;
    AutomationElementCollection all;
    try { using (cr.Activate()) { all = root.FindAll(TreeScope.Descendants, Automation.ControlViewCondition); } } catch (Exception) { return l; }
    foreach (AutomationElement e in all) {
      if (l.Count >= max) break;
      var k = new KitEl(); k.E = e;
      try {
        k.Name = (e.Cached.Name ?? ""); k.Id = (e.Cached.AutomationId ?? ""); k.Cls = (e.Cached.ClassName ?? "");
        k.Type = e.Cached.ControlType == null ? "" : e.Cached.ControlType.ProgrammaticName.Replace("ControlType.", "");
        var r = e.Cached.BoundingRectangle; k.Off = e.Cached.IsOffscreen;
        if (!r.IsEmpty && !double.IsInfinity(r.X)) { k.X = r.X; k.Y = r.Y; k.W = r.Width; k.H = r.Height; }
      } catch (Exception) { }
      l.Add(k);
    }
    return l;
  }
  public static List<KitEl> Descendants(KitEl root, int max) { return Descendants(root.E, max); }
  public static string Name(KitEl e) { return e.Name; }
  public static string AutoId(KitEl e) { return e.Id; }
  public static string TypeName(KitEl e) { return e.Type; }
  public static bool Shown(KitEl e) { return !e.Off && e.W > 0 && e.H > 0; }
  public static object Pattern(KitEl e, AutomationPattern p) { object o; try { return e.E.TryGetCurrentPattern(p, out o) ? o : null; } catch (Exception) { return null; } }
  // Invoke on a worker thread: a button whose handler opens a modal dialog doesn't return until that closes. True when it
  // returned within ms (false: still running, which is fine for a button that opens a dialog).
  public static bool InvokeNoWait(KitEl e, int ms) {
    var p = Pattern(e, InvokePattern.Pattern) as InvokePattern; if (p == null) throw new InvalidOperationException("no Invoke pattern");
    Exception err = null;
    var t = new Thread(delegate () { try { p.Invoke(); } catch (Exception x) { err = x; } }); t.IsBackground = true; t.Start();
    bool done = t.Join(ms); if (done && err != null) throw err; return done;
  }
  public static string Val(KitEl e) {
    var v = Pattern(e, ValuePattern.Pattern) as ValuePattern; if (v != null) { try { return v.Current.Value; } catch (Exception) { } }
    var t = Pattern(e, TogglePattern.Pattern) as TogglePattern; if (t != null) { try { var s = t.Current.ToggleState; return s == ToggleState.On ? "on" : s == ToggleState.Off ? "off" : "mixed"; } catch (Exception) { } }
    var si = Pattern(e, SelectionItemPattern.Pattern) as SelectionItemPattern; if (si != null) { try { return si.Current.IsSelected ? "on" : "off"; } catch (Exception) { } }
    var sel = Pattern(e, SelectionPattern.Pattern) as SelectionPattern;
    if (sel != null) { try { var names = new List<string>(); foreach (AutomationElement x in sel.Current.GetSelection()) names.Add(x.Current.Name); return string.Join(";", names.ToArray()); } catch (Exception) { } }
    return null;
  }
}
'@
if (-not ('KitUi' -as [type])) {
  try { Add-Type -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase, System.Windows.Forms, System.Drawing -TypeDefinition $helper -ErrorAction Stop }
  catch { W ("FAIL 0: the helper did not compile: " + (($Error | Select-Object -First 1 | ForEach-Object { "$_" -replace "\s+", " " }))); Finish 2 }
}

function Fail($n, $step, $why) {
  W ("FAIL {0} {1}: {2}" -f $n, $step, $why)
  try { W '--- dialogs now ---'; foreach ($l in (List-Dialogs)) { W "  $l" } } catch { W "  (could not list them: $($_.Exception.Message))" }
  try { Save-Screenshot (Join-Path $out 'ui-fail.png'); W 'screenshot: out\ui-fail.png' } catch { }
  W ("FAIL at step {0} of {1}" -f $n, $script:total)
  Finish 1
}

$proc = $null; $frame = [IntPtr]::Zero
foreach ($p in @(Get-Process acad -EA SilentlyContinue | Sort-Object StartTime -Descending)) {
  $f = [KitUi]::Frame([uint32]$p.Id); if ($f -ne [IntPtr]::Zero) { $proc = $p; $frame = $f; break }
}
if (-not $proc) { W 'FAIL 0: AutoCAD is not running (no acad.exe with a main window)'; Finish 1 }
$apid = [uint32]$proc.Id
[KitUi]::DpiAware()

function Dialog-Info($h) {
  $r = [KitUi]::Rect($h)
  [pscustomobject]@{ H = $h; Title = [KitUi]::Caption($h); Cls = [KitUi]::Cls($h); Enabled = [KitUi]::IsWindowEnabled($h)
    Visible = [KitUi]::IsWindowVisible($h); Front = ([KitUi]::GetForegroundWindow() -eq $h); OffScreen = [KitUi]::OffScreen($h)
    Rect = "$($r.L),$($r.T),$($r.R),$($r.B)" }
}
# AutoCAD's dialogs, front to back, visible ones only (a hidden dialog can't be answered by a person either)
function Dialogs { @([KitUi]::Tops($apid) | Where-Object { [KitUi]::IsWindowVisible($_) -and [KitUi]::IsDialog($_) } | ForEach-Object { Dialog-Info $_ }) }
function List-Dialogs {
  $d = Dialogs
  if (-not $d) { return @("(none; AutoCAD's main window is " + $(if ([KitUi]::IsWindowEnabled($frame)) { 'enabled' } else { 'disabled: something modal is open' }) + ')') }
  $d | ForEach-Object { "[{0}] {1}{2}{3}{4} class={5} at {6}" -f $_.Title, $(if ($_.Enabled) { 'active' } else { 'disabled (a dialog on top of it)' }), $(if ($_.Front) { ', in front' } else { ', not in front' }), $(if ($_.OffScreen) { ', OFF SCREEN' } else { '' }), '', $_.Cls, $_.Rect }
}
function Title-Matches($title, $want) {
  if ($want -match '[*?]') { return [KitUi]::Norm($title) -like [KitUi]::Norm($want) }
  return [KitUi]::Match($title, $want) -gt 0
}
# Waits until $probe returns something (polling every 200 ms) or the step timeout passes.
function Until([scriptblock]$probe, [int]$sec = $script:stepTimeout) {
  $end = (Get-Date).AddSeconds($sec)
  while ($true) { $v = & $probe; if ($v) { return $v }; if ((Get-Date) -gt $end) { return $null }; Start-Sleep -Milliseconds 200 }
}
function Is-Message($h) {
  if ([KitUi]::Cls($h) -ne '#32770') { return $false }
  $kids = [KitUi]::Kids($h)
  if ($kids | Where-Object { [KitUi]::Cls($_) -eq 'DirectUIHWND' }) { return $true }   # task dialog
  $kinds = @($kids | ForEach-Object { [KitUi]::KindOf($_, [KitUi]::Cls($_), [KitUi]::Style($_)) })
  return ($kinds -contains 'button') -and -not ($kinds | Where-Object { $_ -in 'edit', 'combo', 'list', 'check', 'radio' })
}
# The target: the handle chosen by dialog/alert; when that window is gone, the newest visible dialog with the same title.
function Target {
  if ($script:target -ne [IntPtr]::Zero -and [KitUi]::IsWindow($script:target) -and [KitUi]::IsWindowVisible($script:target)) { return $script:target }
  if ($script:targetTitle) {
    $d = Dialogs | Where-Object { Title-Matches $_.Title $script:targetTitle } | Select-Object -First 1
    if ($d) { $script:target = $d.H; return $d.H }
  }
  return $null
}
# A security prompt of AutoCAD's ("Security - Unsigned Executable File") is open: a person answers those, so no input goes anywhere
# while one is up (a real click or keystroke could land on it, and a dialog behind it is disabled anyway).
function Security-Open { Dialogs | Where-Object { $_.Title -match '^Security\b' } | Select-Object -First 1 }
function Need-Target($n, $step, [switch]$Act) {
  $t = Until { Target }
  if (-not $t) { Fail $n $step $(if ($script:targetTitle) { "no dialog '$($script:targetTitle)' open" } else { 'no target dialog: start with a dialog or alert step' }) }
  if ([KitUi]::Caption($t) -match '^Security\b') { Fail $n $step "'$([KitUi]::Caption($t))' is a security prompt; a person answers those" }
  if ($Act) {
    if ($sp = Security-Open) { Fail $n $step "a security prompt is open ([$($sp.Title)]); a person answers it first" }
    # a dialog with a modal one on top is disabled: a person can't use it until that one closes (an alert from its own button)
    if (-not (Until { [KitUi]::IsWindowEnabled($t) } ([Math]::Min(3, $script:stepTimeout)))) { Fail $n $step ("[$([KitUi]::Caption($t))] is disabled: a dialog on top of it waits first: " + ((List-Dialogs) -join '; ')) }
  }
  return $t
}
function Uia-Win32($t) { [KitUi]::Cls($t) -in '#32770' -or [KitUi]::Cls($t) -like 'adesk_dlg*' }
# Win32 controls of the target matching a label (best match first, visible ones only)
function Find-Ctl($t, $label, [string[]]$kinds) {
  $all = [KitUi]::Controls($t)
  $shown = @($all | Where-Object { $_.Visible -and ($kinds.Count -eq 0 -or $_.Kind -in $kinds) })
  $hits = @($shown | ForEach-Object { [pscustomobject]@{ C = $_; Score = [KitUi]::Match($_.Label, $label) } } | Where-Object { $_.Score -gt 0 } | Sort-Object Score -Descending)
  $hit = if ($hits) { $hits[0].C } else { $null }
  if (-not $hit) { $starts = @($shown | Where-Object { [KitUi]::Starts($_.Label, $label) }); if ($starts.Count -eq 1) { $hit = $starts[0] } }   # only when one control starts that way
  [pscustomobject]@{ All = $all; Hit = $hit }
}
# UI Automation element of the target matching a name (or automation id), visible ones only
function Find-Elem($t, $label, [string[]]$types) {
  $root = [KitUi]::Elem($t); if (-not $root) { return $null }
  $els = [KitUi]::Descendants($root, 600)
  $cands = @($els | Where-Object { [KitUi]::Shown($_) -and ($types.Count -eq 0 -or [KitUi]::TypeName($_) -in $types) })
  $hit = $cands | Where-Object { [KitUi]::Match([KitUi]::Name($_), $label) -eq 2 -or [KitUi]::AutoId($_) -eq $label } | Select-Object -First 1
  if (-not $hit) { $hit = $cands | Where-Object { [KitUi]::Match([KitUi]::Name($_), $label) -eq 1 } | Select-Object -First 1 }
  if (-not $hit) { $starts = @($cands | Where-Object { [KitUi]::Starts([KitUi]::Name($_), $label) }); if ($starts.Count -eq 1) { $hit = $starts[0] } }
  if (-not $hit -and $types -contains 'Edit') {
    # an edit box named by the text just before it
    for ($i = 0; $i -lt $els.Count - 1; $i++) {
      if ([KitUi]::TypeName($els[$i]) -eq 'Text' -and [KitUi]::Match([KitUi]::Name($els[$i]), $label) -gt 0) {
        $hit = $els[($i + 1)..([Math]::Min($i + 4, $els.Count - 1))] | Where-Object { [KitUi]::TypeName($_) -in 'Edit', 'ComboBox' -and [KitUi]::Shown($_) } | Select-Object -First 1
        if ($hit) { break }
      }
    }
  }
  $hit
}
function Texts($t) {
  if (Uia-Win32 $t) {
    $c = [KitUi]::Controls($t)
    if (-not ($c | Where-Object { $_.Cls -eq 'DirectUIHWND' })) { return @($c | Where-Object { $_.Visible -and $_.Kind -eq 'text' -and $_.Text.Trim() } | ForEach-Object { $_.Text.Trim() }) }
  }
  $root = [KitUi]::Elem($t); if (-not $root) { return @() }
  @([KitUi]::Descendants($root, 400) | Where-Object { [KitUi]::TypeName($_) -eq 'Text' -and [KitUi]::Name($_).Trim() } | ForEach-Object { [KitUi]::Name($_).Trim() } | Select-Object -Unique)
}
function Read-Target($t) {
  $lines = @("dialog [$([KitUi]::Caption($t))] class=$([KitUi]::Cls($t))")
  if ((Uia-Win32 $t) -and -not ([KitUi]::Kids($t) | Where-Object { [KitUi]::Cls($_) -eq 'DirectUIHWND' })) {
    foreach ($c in [KitUi]::Controls($t)) {
      if (-not $c.Visible -or $c.Kind -in 'group', 'other') { continue }
      $dis = if ($c.Enabled) { '' } else { ' (disabled)' }
      switch ($c.Kind) {
        'text' { if ($c.Text.Trim()) { $lines += "  text   $([KitUi]::Show($c.Text))" } }
        'button' { $lines += "  button [$([KitUi]::Show($c.Text))]$dis" }
        'ownerdrawn' { $lines += "  button [$([KitUi]::Show($c.Text))]$dis" }
        'combo' { $lines += "  combo  $([KitUi]::Show($c.Label)) = '$([KitUi]::Value($c))'  items: $(([KitUi]::Items($c)) -join ' | ')$dis" }
        'list' { $lines += "  list   $([KitUi]::Show($c.Label)) = '$([KitUi]::Value($c))'  items: $(([KitUi]::Items($c)) -join ' | ')$dis" }
        default { $lines += ("  {0,-6} {1} = '{2}'{3}" -f $c.Kind, $([KitUi]::Show($c.Label)), [KitUi]::Value($c), $dis) }
      }
    }
    return $lines
  }
  $root = [KitUi]::Elem($t); $lastText = ''; $prevName = ''
  foreach ($e in [KitUi]::Descendants($root, 400)) {
    if (-not [KitUi]::Shown($e)) { continue }
    $ty = [KitUi]::TypeName($e); $nm = [KitUi]::Show([KitUi]::Name($e))
    if ($ty -in 'Pane', 'Group', 'Custom', 'Image', 'ScrollBar', 'Thumb', 'Separator', 'TitleBar', 'MenuBar') { continue }
    if ($ty -eq 'Text') {
      if ($nm -and $nm -ne $prevName) { $lines += "  text     $nm" }   # not the caption inside the button or check box just listed
      if ($nm) { $lastText = $nm }; continue
    }
    if (-not $nm -and $ty -notin 'Edit', 'ComboBox', 'List') { continue }
    $label = if ($nm) { "[$nm]" } elseif ($lastText) { "($lastText)" } else { '' }   # an unnamed box goes by the text before it
    $v = [KitUi]::Val($e); $id = [KitUi]::AutoId($e)
    $lines += ("  {0,-8} {1}{2}{3}" -f $ty.ToLower(), $label, $(if ($null -ne $v) { " = '$v'" } else { '' }), $(if ($id -and $id -notmatch '^\d+$' -and $id -ne $nm) { "  id=$id" } else { '' }))
    $prevName = $nm
  }
  $lines
}
# Waits (up to 3 s) until the dialog stops changing: a program fills its lists and fields just after the dialog appears.
function Settle($h) {
  $prev = $null; $end = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $end) {
    $sig = try { (Read-Target $h) -join "`n" } catch { '' }
    if ($null -ne $prev -and $sig -eq $prev) { return }
    $prev = $sig; Start-Sleep -Milliseconds 250
  }
}
function OnOff($v) {
  switch -regex ($v.Trim().ToLower()) { '^(on|true|yes|1|x|checked)$' { return $true }; '^(off|false|no|0|unchecked)$' { return $false } }
  return $null
}

# ---- ribbon --------------------------------------------------------------------------------------------------------------
function Ribbon-Root {
  $fr = [KitUi]::Elem($frame); if (-not $fr) { return $null }
  $c = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'AfxControlBar140u')),
    (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Ribbon')))
  $r = $fr.FindFirst([System.Windows.Automation.TreeScope]::Children, $c)
  if (-not $r) { $r = $fr.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, 'Ribbon'))) }
  $r
}
function By-Id($root, $id) { $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))) }
function Ribbon-Item-Match($e, $want) {
  $id = [KitUi]::AutoId($e)
  ($id -like '*_RibbonItemControl') -and ([KitUi]::Match([KitUi]::Name($e), $want) -gt 0 -or $id -eq "${want}_RibbonItemControl")
}
# Every shown ribbon item under $root matching $want (labels or ids), best first
function Find-Items($root, $want) {
  @([KitUi]::Descendants($root, 3000) | Where-Object { [KitUi]::Shown($_) -and (Ribbon-Item-Match $_ $want) } |
    Sort-Object { - [KitUi]::Match([KitUi]::Name($_), $want) })
}
# Items in AutoCAD's popups: a panel slide-out is a Popup window under the main window's element (id <panel>_SlideOutPanelPopup_PopupRoot);
# a minimized ribbon's panels and other popups can be top-level WPF windows of their own.
function Find-Items-Popups($want) {
  $found = @()
  $fr = [KitUi]::Elem($frame)
  if ($fr) {
    $wins = $fr.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
    foreach ($w in $wins) { $found += Find-Items $w $want }
  }
  foreach ($h in [KitUi]::Tops($apid)) {
    if ($h -eq $frame -or -not [KitUi]::IsWindowVisible($h) -or [KitUi]::Cls($h) -notlike 'HwndWrapper*' -or [KitUi]::GetWindow($h, 4) -ne $frame) { continue }
    $e = [KitUi]::Elem($h); if ($e) { $found += Find-Items $e $want }
  }
  $found
}
function Click-Elem($e, $what) {
  $x = [int]($e.X + $e.W / 2); $y = [int]($e.Y + $e.H / 2)
  $root = [KitUi]::RootAt($x, $y)
  if ($root -ne $frame -and [KitUi]::Pid($root) -ne $apid) {
    [KitUi]::Front($frame, $false) | Out-Null; Start-Sleep -Milliseconds 200; $root = [KitUi]::RootAt($x, $y)   # no Alt tap: a recorder would log it
  }
  if ($root -ne $frame -and [KitUi]::Pid($root) -ne $apid) { return "$what at $x,$y is covered by another program's window [$([KitUi]::Caption($root))] class=$([KitUi]::Cls($root))" }
  # AutoCAD's own windows: only the frame or a ribbon popup (a slide-out: a WPF window owned by the frame) may take the click, not a floating palette
  if ($root -ne $frame -and -not ([KitUi]::Cls($root) -like 'HwndWrapper*' -and [KitUi]::GetWindow($root, 4) -eq $frame)) {
    return "$what at $x,$y is covered by AutoCAD's window [$([KitUi]::Caption($root))] class=$([KitUi]::Cls($root)): move or close it"
  }
  [KitUi]::Click($x, $y)
  return $null
}
function Do-Ribbon($n, $step, $path) {
  if (-not [KitUi]::IsWindowEnabled($frame)) { Fail $n $step 'a modal dialog is open, so the ribbon does not take clicks: answer or close it first' }
  $parts = @($path -split '/' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($parts.Count -eq 0 -or $parts.Count -gt 3) { Fail $n $step 'expected ribbon [<tab>/][<panel>/]<button>' }
  $want = $parts[-1]; $tab = if ($parts.Count -ge 2) { $parts[0] } else { $null }; $panel = if ($parts.Count -eq 3) { $parts[1] } else { $null }
  if ([KitUi]::IsIconic($frame)) { [KitUi]::ShowWindow($frame, 9) | Out-Null; Start-Sleep -Milliseconds 400 }
  $rib = Until { Ribbon-Root } 5
  if (-not $rib) { Fail $n $step 'no ribbon found (turn it on with the RIBBON command)' }
  if ($tab) {
    $strip = By-Id $rib 'mMainTabs'
    $tabs = if ($strip) { @([KitUi]::Descendants($strip, 200) | Where-Object { [KitUi]::TypeName($_) -eq 'Button' }) } else { @() }
    # contextual tabs live outside the main strip: also look at every tab-like button in the ribbon
    if (-not ($tabs | Where-Object { [KitUi]::Match([KitUi]::Name($_), $tab) -gt 0 -or [KitUi]::AutoId($_) -eq $tab })) {
      $tabs += @([KitUi]::Descendants($rib, 3000) | Where-Object { [KitUi]::TypeName($_) -eq 'Button' -and [KitUi]::AutoId($_) -match 'Tab' })
    }
    $tb = $tabs | Where-Object { [KitUi]::Match([KitUi]::Name($_), $tab) -eq 2 -or [KitUi]::AutoId($_) -eq $tab } | Select-Object -First 1
    if (-not $tb) { $tb = $tabs | Where-Object { [KitUi]::Match([KitUi]::Name($_), $tab) -eq 1 } | Select-Object -First 1 }
    if (-not $tb) { Fail $n $step ("no ribbon tab '$tab' (tabs: " + ((@($tabs | ForEach-Object { [KitUi]::Name($_) } | Where-Object { $_ }) | Select-Object -Unique) -join ', ') + ')') }
    [KitUi]::InvokeNoWait($tb, 3000) | Out-Null
    Start-Sleep -Milliseconds 300
  }
  # the panel's title bar (opens its slide-out) and the panel element itself, looked up once
  $pe = $null; $scope = $rib
  if ($panel) {
    $pe = @([KitUi]::Descendants($rib, 3000) | Where-Object { [KitUi]::AutoId($_) -like '*_PanelTitleBar' -and [KitUi]::TypeName($_) -eq 'Button' -and ([KitUi]::Match([KitUi]::Name($_), $panel) -gt 0 -or [KitUi]::AutoId($_) -eq "${panel}_PanelTitleBar") -and [KitUi]::Shown($_) }) | Select-Object -First 1
    if (-not $pe) { Fail $n $step "no panel '$panel' on this tab" }
    $pc = By-Id $rib ($pe.Id -replace '_PanelTitleBar$', ''); if ($pc) { $scope = $pc }
  }
  $hit = Until { $f = Find-Items $scope $want; if (-not $f) { $f = Find-Items-Popups $want }; if ($f) { $f[0] } } 3
  if (-not $hit -and $pe) {
    # not on the panel's face: open its slide-out (title bar toggle) and look in the popup
    $err = Click-Elem $pe "the panel title '$panel'"
    if ($err) { Fail $n $step $err }
    $hit = Until { $f = Find-Items-Popups $want; if (-not $f) { $f = Find-Items $scope $want }; if ($f) { $f[0] } } 4
  }
  if (-not $hit) {
    $names = @([KitUi]::Descendants($rib, 3000) | Where-Object { [KitUi]::AutoId($_) -like '*_RibbonItemControl' -and [KitUi]::Shown($_) } | ForEach-Object { [KitUi]::Show([KitUi]::Name($_)) } | Where-Object { $_ } | Select-Object -Unique -First 60)
    Fail $n $step ("no button '$want' showing on the ribbon" + $(if (-not $panel) { ' (a button in a panel slide-out needs <tab>/<panel>/<button>)' } else { '' }) + ". Showing: " + ($names -join ', '))
  }
  # a split button runs its command from its execute part; the arrow part only opens the list
  $exec = @([KitUi]::Descendants($hit, 20) | Where-Object { [KitUi]::AutoId($_) -like '*_FlyoutButtonExecute' -and [KitUi]::Shown($_) }) | Select-Object -First 1
  $target2 = if ($exec) { $exec } else { $hit }
  $err = Click-Elem $target2 "the ribbon button '$want'"
  if ($err) { Fail $n $step $err }
  Wait-Started | Out-Null
  Park-Mouse   # no tool tip left open over the ribbon, and not over the drawing while the command waits for a point
  "clicked '$([KitUi]::Show([KitUi]::Name($hit)))' ($([KitUi]::AutoId($hit) -replace '_RibbonItemControl$', ''))"
}

# ---- commands -----------------------------------------------------------------------------------------------------------
# AutoCAD over COM, only to ask whether it is quiescent (no command, prompt or dialog active). Answers while a command waits.
$script:acad = $null; $script:comErr = ''
function Quiescent {
  try {
    # no COM retry filter (Register-ComRetry) here: a call AutoCAD rejects as busy must answer "busy" at once, not after 30 s
    if (-not $script:acad) { $script:comErr = 'COM: AutoCAD.Application not reachable'; $script:acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application') }
    $script:comErr = ''
    return [bool]$script:acad.GetAcadState().IsQuiescent
  } catch { if ($script:comErr) { $script:comErr += " ($($_.Exception.Message))" }; $script:acad = $null; return $false }
}
# After a click or typed command: wait (up to $sec) until AutoCAD has taken it, i.e. is busy or shows a dialog, then a moment for the
# prompt to settle. Text typed before that can be lost (a ribbon macro starts with ^C^C, which cancels what is pending).
# A command that ends at once looks the same as one not started yet: the wait then just runs out.
function Wait-Started([double]$sec = 2) {
  $end = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $end) {
    # a modal dialog disables the main window; a modeless window (a plugin's tool window) doesn't and doesn't count
    if (-not [KitUi]::IsWindowEnabled($frame) -or -not (Quiescent)) { Start-Sleep -Milliseconds 300; return $true }
    Start-Sleep -Milliseconds 100
  }
  return $false
}
# While the mouse rests on the ribbon (its tool tip open), AutoCAD silently drops text typed with WM_COPYDATA. So typing first moves
# the mouse off the ribbon, onto the command line: not over the drawing, where a jumping cursor drags the rubber band of a prompt that
# waits for a point or distance (and a recorder logs those drags as answers).
function Ribbon-Rect {
  $bar = [KitUi]::Kids($frame) | Where-Object { [KitUi]::Cls($_) -like 'AfxControlBar*' -and [KitUi]::Caption($_) -eq 'Ribbon' -and [KitUi]::IsWindowVisible($_) } | Select-Object -First 1
  if ($bar) { [KitUi]::Rect($bar) } else { $null }
}
# The command line's rectangle: the untitled WPF window of AutoCAD's that holds a CommandLineControl (AutoCAD 2026, floating or docked)
$script:cmdLine = [IntPtr]::Zero; $script:cmdLineLooked = $false
function CommandLine-Rect {
  if ($script:cmdLine -eq [IntPtr]::Zero -or -not [KitUi]::IsWindow($script:cmdLine) -or -not [KitUi]::IsWindowVisible($script:cmdLine)) {
    if ($script:cmdLine -eq [IntPtr]::Zero -and $script:cmdLineLooked) { return $null }   # looked once this run and found none (hidden with Ctrl+9)
    $script:cmdLine = [IntPtr]::Zero; $script:cmdLineLooked = $true
    # floating: an untitled top-level WPF window owned by the main window; docked: a child of it. Small ones only (not the ribbon's)
    foreach ($h in @([KitUi]::Tops($apid) | Where-Object { [KitUi]::GetWindow($_, 4) -eq $frame }) + @([KitUi]::Kids($frame))) {
      if (-not [KitUi]::IsWindowVisible($h) -or [KitUi]::Cls($h) -notlike 'HwndWrapper*' -or [KitUi]::Caption($h)) { continue }
      $wr = [KitUi]::Rect($h); if ($wr.B - $wr.T -gt 300) { continue }
      $e = [KitUi]::Elem($h)
      if ($e -and $e.FindFirst([System.Windows.Automation.TreeScope]::Subtree, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CommandLineControl')))) { $script:cmdLine = $h; break }
    }
  }
  if ($script:cmdLine -ne [IntPtr]::Zero) { [KitUi]::Rect($script:cmdLine) } else { $null }
}
function Park-Mouse {
  if ($cl = CommandLine-Rect) { [KitUi]::Move([int](($cl.L + $cl.R) / 2), [int](($cl.T + $cl.B) / 2)) }
  else { $fr = [KitUi]::Rect($frame); [KitUi]::Move([int](($fr.L + $fr.R) / 2), [Math]::Max($fr.T, 0) + 12) }   # no command line: the title bar (never the drawing)
  Start-Sleep -Milliseconds 300
}
function Mouse-Off-Ribbon {
  $rr = Ribbon-Rect; if (-not $rr) { return }
  $c = [System.Windows.Forms.Cursor]::Position
  if ($c.X -lt $rr.L -or $c.X -ge $rr.R -or $c.Y -lt $rr.T -or $c.Y -ge $rr.B) { return }
  Park-Mouse
}
function Cmd-Text($text) {
  $t = $text -replace '\\n', "`n"
  if (-not ($t.EndsWith("`n") -or $t.EndsWith(' '))) { $t += "`n" }
  $t
}

# ---- steps ---------------------------------------------------------------------------------------------------------------
$stepsFile = Join-Path $script:Home_ 'ui.txt'
$steps = @(if (Test-Path $stepsFile) { Get-Content $stepsFile -Encoding UTF8 } else { @() }) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
$script:total = $steps.Count
$script:stepTimeout = [Math]::Max(1, $StepTimeoutSec)
$script:target = [IntPtr]::Zero; $script:targetTitle = $null
W ("acad pid {0}, frame [{1}]{2}" -f $apid, [KitUi]::Caption($frame), $(if ([KitUi]::GetForegroundWindow() -eq $frame) { ', in front' } else { '' }))
if ($script:total -eq 0) { W 'FAIL 0: no steps (ui.txt is empty)'; Finish 2 }
$n = 0
foreach ($step in $steps) {
  $n++
  if (-not (Current)) { Finish 3 }
  $verb, $arg = $step -split '\s+', 2; $verb = $verb.ToLower(); if ($null -eq $arg) { $arg = '' }
  $msg = $null
  try {
    switch ($verb) {
      'command' {
        if (-not $arg) { Fail $n $step 'command needs the text to send' }
        if (-not [KitUi]::IsWindowEnabled($frame)) { Fail $n $step ('a modal dialog is open; a command typed now would wait behind it: ' + ((List-Dialogs) -join '; ')) }
        if (-not (Until { Quiescent } ([Math]::Min(5, $script:stepTimeout)))) { Fail $n $step $(if ($script:comErr) { "AutoCAD's state can't be read: $($script:comErr)" } else { 'AutoCAD is busy: a command or prompt is active (finish it, use type to answer it, or press Esc with esc.ps1)' }) }
        Mouse-Off-Ribbon
        if (-not [KitUi]::TypeText($frame, (Cmd-Text $arg))) { Fail $n $step 'AutoCAD did not take the text (its window did not answer)' }
        $msg = if (Wait-Started) { 'started' } else { 'sent (already finished, or not started: idle and read the result)' }
      }
      'type' {
        if (-not $arg) { Fail $n $step 'type needs the text' }
        if (-not [KitUi]::IsWindowEnabled($frame)) { Fail $n $step ('a modal dialog is open; answer it first: ' + ((List-Dialogs) -join '; ')) }
        Mouse-Off-Ribbon
        if (-not [KitUi]::TypeText($frame, (Cmd-Text $arg))) { Fail $n $step 'AutoCAD did not take the text (its window did not answer)' }
        Start-Sleep -Milliseconds 300
        $msg = 'typed'
      }
      'idle' {
        $sec = if ($arg -match '^\d+$') { [int]$arg } else { $script:stepTimeout }
        # free = no modal dialog (the main window is enabled) and AutoCAD quiescent twice in a row; modeless windows may stay open
        $q = Until { if ([KitUi]::IsWindowEnabled($frame) -and (Quiescent)) { Start-Sleep -Milliseconds 300; if (Quiescent) { $true } } } $sec
        if (-not $q) { Fail $n $step $(if ($script:comErr) { "AutoCAD's state can't be read: $($script:comErr)" } else { "AutoCAD is still busy after ${sec}s (a prompt, or: " + ((List-Dialogs) -join '; ') + ')' }) }
        $msg = 'AutoCAD is free'
      }
      'ribbon' { $msg = Do-Ribbon $n $step $arg }
      'dialog' {
        if (-not $arg) { Fail $n $step 'dialog needs a title' }
        $d = Until { Dialogs | Where-Object { Title-Matches $_.Title $arg } | Sort-Object { -not $_.Enabled } | Select-Object -First 1 }
        if (-not $d) { Fail $n $step "no dialog '$arg' opened within $($script:stepTimeout)s" }
        $script:target = $d.H; $script:targetTitle = $d.Title; Settle $d.H
        $msg = "found [$($d.Title)]" + $(if (-not $d.Front) { ' (not in front)' } else { '' }) + $(if ($d.OffScreen) { ' (OFF SCREEN: front moves it)' } else { '' })
      }
      'alert' {
        $d = Until { Dialogs | Where-Object { $_.Enabled -and (Is-Message $_.H) -and (-not $arg -or (Title-Matches $_.Title $arg)) } | Select-Object -First 1 }
        if (-not $d) { Fail $n $step ("no message box" + $(if ($arg) { " '$arg'" } else { '' }) + " within $($script:stepTimeout)s") }
        $script:target = $d.H; $script:targetTitle = $d.Title; Settle $d.H
        $msg = "[$($d.Title)] " + ((Texts $d.H) -join ' / ')
      }
      'read' { $t = Need-Target $n $step; foreach ($l in (Read-Target $t)) { W "  $l" }; $msg = 'read' }
      'dialogs' { foreach ($l in (List-Dialogs)) { W "  $l" }; $msg = 'listed' }
      'expect' {
        $t = Need-Target $n $step
        # the title, texts and values; not the drop-downs' and lists' other items (`expect Doors` must not pass on an unselected item)
        $seen = { @([KitUi]::Caption($t)) + (Texts $t) + @((Read-Target $t) -replace '  items: .*$', '') }
        $text = & $seen
        $ok = Until { $all = (& $seen) -join "`n"; if ($all -match $arg) { $true } } ([Math]::Min(3, $script:stepTimeout))
        if (-not $ok) { Fail $n $step ("no match for /$arg/ in: " + (($text | Select-Object -Unique) -join ' / ')) }
        $msg = 'matched'
      }
      'set' {
        $t = Need-Target $n $step -Act
        if ($arg -notmatch '^(.+?)=(.*)$') { Fail $n $step 'expected set <label>=<value>' }
        $label = $Matches[1].Trim(); $val = $Matches[2]
        if (Uia-Win32 $t) {
          $f = Find-Ctl $t $label @('edit', 'combo', 'list', 'check', 'radio')
          if ($f.Hit) {
            $c = $f.Hit
            if (-not $c.Enabled) { Fail $n $step "'$label' is disabled" }
            $err = switch ($c.Kind) {
              'edit' { [KitUi]::SetEdit($c, $val) }
              'combo' { [KitUi]::SetCombo($c, $val) }
              'list' { [KitUi]::SetList($c, [string[]]@($val -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) }
              'check' { $b = OnOff $val; if ($null -eq $b) { "a check box takes on or off, not '$val'" } else { [KitUi]::SetCheck($c, $b) } }
              'radio' { if ((OnOff $val) -ne $true) { "a radio button takes =on (to turn it off, set another one of its group), not '$val'" } else { [KitUi]::SetRadio($c, [System.Collections.Generic.List[KitCtl]]$f.All) } }
            }
            if ($err) { Fail $n $step $err }
            $msg = "$($c.Kind) '$([KitUi]::Show($c.Label))' = '$([KitUi]::Value($c))'"
            break
          }
        }
        # WPF / WinForms / anything else: UI Automation
        $e = Find-Elem $t $label @('Edit', 'ComboBox', 'List', 'CheckBox', 'RadioButton', 'Spinner', 'Slider')
        if (-not $e) {
          $labels = if (Uia-Win32 $t) { @(([KitUi]::Controls($t)) | Where-Object { $_.Visible -and $_.Kind -in 'edit', 'combo', 'list', 'check', 'radio' } | ForEach-Object { "$($_.Kind) '$([KitUi]::Show($_.Label))'" }) } else { @() }
          Fail $n $step ("no control '$label'" + $(if ($labels) { ' (controls: ' + ($labels -join ', ') + ')' } else { ' (read lists what is there)' }))
        }
        $ty = [KitUi]::TypeName($e)
        switch ($ty) {
          { $_ -in 'CheckBox' } {
            $b = OnOff $val; if ($null -eq $b) { Fail $n $step "a check box takes on or off, not '$val'" }
            $tp = [KitUi]::Pattern($e, [System.Windows.Automation.TogglePattern]::Pattern)
            for ($k = 0; $k -lt 3 -and (([KitUi]::Val($e) -eq 'on') -ne $b); $k++) { $tp.Toggle() }
          }
          { $_ -in 'RadioButton' } {
            if ((OnOff $val) -ne $true) { Fail $n $step "a radio button takes =on (to turn it off, set another one of its group), not '$val'" }
            [KitUi]::Pattern($e, [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
          }
          { $_ -in 'ComboBox', 'List' } {
            $ec = [KitUi]::Pattern($e, [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($ec) { try { $ec.Expand(); Start-Sleep -Milliseconds 300 } catch { } }
            $items = @($val -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $first = $true
            foreach ($it in $items) {
              $ie = [KitUi]::Descendants($e, 1000) | Where-Object { [KitUi]::TypeName($_) -in 'ListItem', 'DataItem' -and [KitUi]::Match([KitUi]::Name($_), $it) -gt 0 } | Select-Object -First 1
              if (-not $ie) {
                if ($ec) { try { $ec.Collapse() } catch { } }
                $tv = [KitUi]::Pattern($e, [System.Windows.Automation.ValuePattern]::Pattern)
                if ($ty -eq 'ComboBox' -and $items.Count -eq 1 -and $tv -and -not $tv.Current.IsReadOnly) { $tv.SetValue($it); $ec = $null; break }   # editable: type it
                Fail $n $step "no item '$it' in '$label'"
              }
              $si = [KitUi]::Pattern($ie, [System.Windows.Automation.SelectionItemPattern]::Pattern)
              if ($first) { $si.Select() } else { $si.AddToSelection() }; $first = $false
            }
            if ($ec) { try { $ec.Collapse() } catch { } }
            $vp = [KitUi]::Pattern($e, [System.Windows.Automation.ValuePattern]::Pattern)
            if (-not $items -and $vp) { $vp.SetValue($val) }
          }
          default {
            $vp = [KitUi]::Pattern($e, [System.Windows.Automation.ValuePattern]::Pattern)
            $rp = if (-not $vp) { [KitUi]::Pattern($e, [System.Windows.Automation.RangeValuePattern]::Pattern) }
            $num = 0.0
            if ($rp -and -not [double]::TryParse($val, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$num)) { Fail $n $step "'$label' ($ty) takes a number, not '$val'" }
            if (-not $vp -and -not $rp) { Fail $n $step "'$label' ($ty) takes no typed value" }
            try { $e.E.SetFocus() } catch { }
            if ($vp) { $vp.SetValue($val) } else { $rp.SetValue($num) }
          }
        }
        $msg = "$($ty.ToLower()) '$label' = '$([KitUi]::Val($e))'"
      }
      'press' {
        $t = Need-Target $n $step -Act
        if (-not $arg) { Fail $n $step 'press needs the button text' }
        if ((Uia-Win32 $t) -and -not ([KitUi]::Kids($t) | Where-Object { [KitUi]::Cls($_) -eq 'DirectUIHWND' })) {
          $f = Find-Ctl $t $arg @('button', 'ownerdrawn')
          if ($f.Hit) { $err = [KitUi]::Press($f.Hit); if ($err) { Fail $n $step $err }; $msg = "pressed [$([KitUi]::Show($f.Hit.Text))]"; break }
        }
        $e = Find-Elem $t $arg @('Button', 'SplitButton', 'Hyperlink', 'MenuItem')
        if (-not $e) {
          $btns = if (Uia-Win32 $t) { @(([KitUi]::Controls($t)) | Where-Object { $_.Visible -and $_.Kind -in 'button', 'ownerdrawn' } | ForEach-Object { [KitUi]::Show($_.Text) }) } else { @() }
          if (-not $btns) { $root = [KitUi]::Elem($t); if ($root) { $btns = @([KitUi]::Descendants($root, 400) | Where-Object { [KitUi]::TypeName($_) -eq 'Button' -and [KitUi]::Shown($_) } | ForEach-Object { [KitUi]::Name($_) } | Where-Object { $_ }) } }
          Fail $n $step ("no button '$arg' (buttons: " + ($btns -join ', ') + ')')
        }
        try { $e.E.SetFocus() } catch { }   # a WPF text box hands its text to the program when it loses the focus
        $done = [KitUi]::InvokeNoWait($e, 1500)
        $msg = "pressed [$([KitUi]::Name($e))]" + $(if (-not $done) { ' (it opened something modal or is still working)' } else { '' })
      }
      'closed' {
        $title = if ($arg) { $arg } else { $script:targetTitle }
        $h = $script:target
        if (-not $arg -and $h -eq [IntPtr]::Zero) { Fail $n $step 'no target: give the title (closed <title>) or start with dialog/alert' }
        $gone = Until {
          if ($arg) { -not (Dialogs | Where-Object { Title-Matches $_.Title $arg }) }
          else { -not [KitUi]::IsWindow($h) -or -not [KitUi]::IsWindowVisible($h) }
        }
        if (-not $gone) { Fail $n $step "[$title] is still open" }
        $msg = "[$title] closed"
      }
      'front' {
        $h = if ($arg) { (Until { Dialogs | Where-Object { Title-Matches $_.Title $arg } | Select-Object -First 1 }).H } elseif (Target) { Target } else { $frame }
        if (-not $h) { Fail $n $step "no dialog '$arg' open" }
        if ([KitUi]::OffScreen($h)) { [KitUi]::MoveOnScreen($h); W "  moved [$([KitUi]::Caption($h))] onto the screen" }
        $ok = [KitUi]::Front($h)
        $msg = "[$([KitUi]::Caption($h))] in front: $ok"
      }
      'keys' {
        $t = Need-Target $n $step -Act
        if ([KitUi]::OffScreen($t)) { [KitUi]::MoveOnScreen($t) }
        # to the front without the Alt tap (a recorder would see AutoCAD's menu mode as a dialog): the quiet way, else a click on its title bar
        if (-not [KitUi]::Front($t, $false)) {
          $r = [KitUi]::Rect($t); $tx = [int](($r.L + $r.R) / 2); $ty = $r.T + 12
          if ([KitUi]::RootAt($tx, $ty) -ne $t) { Fail $n $step "[$([KitUi]::Caption($t))] is not in front and its title bar is covered: no keystrokes sent" }
          [KitUi]::Click($tx, $ty); Start-Sleep -Milliseconds 300
        }
        if ([KitUi]::GetForegroundWindow() -ne $t) { Fail $n $step "could not bring [$([KitUi]::Caption($t))] to the front for keystrokes" }
        [System.Windows.Forms.SendKeys]::SendWait($arg)
        $msg = "keys sent to [$([KitUi]::Caption($t))]"
      }
      'click' {
        if ($arg -notmatch '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') {
          # click <label>: a real mouse click in the middle of a control of the target (what a person does; press sends the message instead)
          if (-not $arg) { Fail $n $step 'expected click <x>,<y> or click <button or control label>' }
          $t = Need-Target $n $step -Act
          if ([KitUi]::OffScreen($t)) { [KitUi]::MoveOnScreen($t) }
          $cr = $null
          if ((Uia-Win32 $t) -and -not ([KitUi]::Kids($t) | Where-Object { [KitUi]::Cls($_) -eq 'DirectUIHWND' })) {
            $f = Find-Ctl $t $arg @('button', 'ownerdrawn', 'check', 'radio')
            if ($f.Hit) {
              if (-not $f.Hit.Enabled) { Fail $n $step "'$arg' is disabled" }
              $wr = [KitUi]::Rect($f.Hit.H); $cr = @{ X = [int](($wr.L + $wr.R) / 2); Y = [int](($wr.T + $wr.B) / 2) }
            }
          }
          if (-not $cr) {
            $e = Find-Elem $t $arg @('Button', 'SplitButton', 'CheckBox', 'RadioButton', 'Hyperlink', 'MenuItem', 'TabItem', 'ListItem')
            if ($e) {
              $en = try { $e.E.Current.IsEnabled } catch { $true }
              if (-not $en) { Fail $n $step "'$arg' is disabled" }
              $cr = @{ X = [int]($e.X + $e.W / 2); Y = [int]($e.Y + $e.H / 2) }
            }
          }
          if (-not $cr) { Fail $n $step "no control '$arg' in [$([KitUi]::Caption($t))] (read lists them)" }
          $root = [KitUi]::RootAt($cr.X, $cr.Y)
          if ($root -ne $t) { [KitUi]::Front($t, $false) | Out-Null; Start-Sleep -Milliseconds 200; $root = [KitUi]::RootAt($cr.X, $cr.Y) }
          if ($root -ne $t) { Fail $n $step "'$arg' is covered by [$([KitUi]::Caption($root))]" }
          $title = [KitUi]::Caption($t)   # before the click: a button that closes the dialog takes its title with it
          [KitUi]::Click($cr.X, $cr.Y); Start-Sleep -Milliseconds 200; Park-Mouse   # not left over the drawing if the command now asks for a point
          $msg = "clicked '$arg' in [$title]"
          break
        }
        $x = [int]$Matches[1]; $y = [int]$Matches[2]; $root = [KitUi]::RootAt($x, $y)
        if ($sp = Security-Open) { Fail $n $step "a security prompt is open ([$($sp.Title)]); a person answers it first" }
        if ([KitUi]::Pid($root) -ne $apid) { Fail $n $step "the point is on another program's window [$([KitUi]::Caption($root))]" }
        [KitUi]::Click($x, $y); Mouse-Off-Ribbon; $msg = "clicked $x,$y on [$([KitUi]::Caption($root))]"
      }
      'move' {
        if ($arg -notmatch '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') { Fail $n $step 'expected move <x>,<y> (screen pixels)' }
        [KitUi]::Move([int]$Matches[1], [int]$Matches[2]); $msg = 'moved'
      }
      'shot' {
        $name = if ($arg -match '^[\w.-]+$') { $arg } else { 'ui-{0:00}' -f $n }
        Save-Screenshot (Join-Path $out "$name.png"); $msg = "out\$name.png"
      }
      'sleep' { if ($arg -notmatch '^\d+$') { Fail $n $step 'sleep takes milliseconds' }; Start-Sleep -Milliseconds ([int]$arg); $msg = 'slept' }
      'timeout' { if ($arg -notmatch '^\d+$') { Fail $n $step 'timeout takes seconds' }; $script:stepTimeout = [Math]::Max(1, [int]$arg); $msg = "steps wait up to $($script:stepTimeout)s" }
      default { Fail $n $step "unknown step '$verb'" }
    }
  } catch {
    Fail $n $step ("error: " + $_.Exception.Message.Split("`n")[0])
  }
  W ("ok   {0} {1}: {2}" -f $n, $step, $msg)
}
W ("PASS {0} steps" -f $script:total)
Finish 0
