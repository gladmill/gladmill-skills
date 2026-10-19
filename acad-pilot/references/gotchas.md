# Gotchas (learned the hard way)

## Sessions and the desktop
- SSH (and services) run in **session 0, which has no desktop**. Anything that needs AutoCAD or the screen must run in the
  interactive session: a one-shot scheduled task (`schtasks /create ... /sc once /st 00:00 /it /f /rl limited`, `/run`, then `/delete`).
  The scripts do this for you (`Invoke-InSession` in `common.ps1`); local mode runs directly.
- From session 0, `MainWindowTitle` reads empty and `MainWindowHandle` is 0, and AutoCAD's Start tab has no title. Ask readiness over
  COM (`wait-acad.ps1`), not by window titles, CPU thresholds or sleeps (a CPU threshold misjudged warm starts).
- `schtasks /tr` mangles spaces, quotes and parentheses. Pass data through files in the work folder (`cmds.txt`, `query.ps1`,
  `title.txt`), never on the task command line. Keep the scripts folder and `ACAD_DEV_HOME` free of spaces in remote mode.
- A one-shot task can fire again later if left over: always delete it (the scripts do).
- `powershell -WindowStyle Hidden` still flashes a console window (a Windows Terminal window when Terminal is the default console host).
  Tasks here start through `run-hidden.vbs` (wscript has no console). Do **not** start AutoCAD itself through it: it would start hidden;
  `start-acad.ps1` runs a hidden `cmd` whose `start` shows AutoCAD normally.
- Run scripts with `powershell -NoProfile -ExecutionPolicy Bypass -File ...`: script execution may be disabled.
- Over SSH, PowerShell exits 1 when its last command "failed", even with `-ErrorAction SilentlyContinue`: end with `exit 0` when you don't care.
- Simulated mouse clicks (`SetCursorPos`/`mouse_event`) don't reach the session; posted window messages (`PostMessage`) do.

## COM
- COM calls hang or are rejected (`RPC_E_CALL_REJECTED`, 0x80010001) while AutoCAD waits at a prompt or shows a modal dialog,
  or while it is still starting. Never leave a command half-answered. `esc.ps1` gets out of a prompt; `shot.ps1` shows the screen.
  After a restart wait with `wait-acad.ps1` before the first COM call.
- Avoid typing AutoLISP through the chain: quotes break and an unterminated string leaves AutoCAD waiting for input. Read state with a COM query file.
- `SetVariable` needs the variable's type: `[int16]0` for `DYNMODE`, `FILEDIA`; `[int32]` for the longs. A plain PowerShell int fails.
- `SendCommand` runs asynchronously: it queues text for the command line. Use `-WaitSec` long enough, and read the log rather than assuming.
- `Documents.Add()` makes the new drawing active, but commands in the same call still go to the document that was active **before**
  (`$doc` was captured earlier). Open the drawing in a call of its own.
- `GetActiveObject('AutoCAD.Application')` attaches to whichever AutoCAD registered last; with two AutoCADs running, close one.
- The command-line log (`LOGFILEMODE`) is flushed only when closed: the scripts set it to 0 and back to 1 before reading.

## Dialogs and start-up
- A **WPF** dialog ignores IDCANCEL (`wincancel.ps1`); post WM_CLOSE (`-Close`). Classic Win32 dialogs take IDCANCEL.
- A trial/new install shows a start-up window (and a sign-in) that blocks COM. A person signs in once. `trial-watch.ps1` can close
  the trial splash (find what to match in `out\startup-windows.log`); it cannot and must not sign in.
- "Component Updates Required" and similar modal dialogs: screenshot, then `wincancel`.
- A vertical product (Electrical, Mechanical...) is what `acad.exe` starts on such installs; `/product ACAD` may not change that.
  Use `ACAD_DEV_PRODUCT` and check `$acad.Name`/`$acad.Version` in a query.
- The ribbon, palettes and other UI appear a moment after the drawing opens; a COM query can run before they exist.

## Misc
- In commands sent with `run`, `\n` is Enter, so `C:\new\plan.dwg` breaks at `\n`. Write paths with forward slashes (`C:/new/plan.dwg`). A literal `|` cannot be sent: it separates commands.
- Screenshots use the primary screen at its current size; a locked or disconnected RDP session gives a black or failing capture.
  Keep the Windows session unlocked and connected.
- Close test drawings with `Close($false)` (no save). A "save changes?" dialog is a modal dialog that blocks COM.
- Do not run two scripts that use the same task name at once (`AcadDevCmd`, `AcadDevReady`, ...): run them one after the other.

- Posted Esc key messages (`PostMessage WM_KEYDOWN`) are ignored while AutoCAD waits at a command prompt. `esc.ps1` brings AutoCAD to the foreground and sends real keystrokes (SendKeys), which works. A hidden scheduled task (remote mode) may not take the foreground (Windows' foreground lock), so it taps Alt first, which lifts the lock. If AutoCAD still cannot be brought to the front it posts Esc to AutoCAD's focused control and says `foreground: False` (`acad-dev.sh esc` exits 3): check with a query or a screenshot before going on.
- Even in the interactive session, `Process.MainWindowHandle` of acad.exe can be an untitled WPF helper window, not AutoCAD's frame;
  keystrokes sent there are lost. Find the frame by enumerating the process's visible, unowned top-level windows and taking the one
  titled `Autodesk AutoCAD ...` (as `esc.ps1` does).
- **One driver at a time.** All calls share the work folder (`cmds.txt`, `query.ps1`, `out\`) and the scheduled-task names. Two sessions or agents driving the same AutoCAD at once overwrite each other's files and tasks, and calls time out. Run one at a time.
- Do not type AutoLISP to read a variable (`(getvar "FILEDIA")` left on the command line without Enter blocks the next command); use a COM query: `$doc.GetVariable('FILEDIA')`.
