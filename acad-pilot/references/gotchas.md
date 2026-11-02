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
- Real input (`SetCursorPos` + `mouse_event`, `keybd_event`, SendKeys) from the interactive one-shot task does reach the desktop
  (tested on AutoCAD 2026 in a VM). Posted mouse messages reach Win32 and WinForms buttons but don't press WPF buttons.

## What blocks AutoCAD (blocker guard)
- Run `blockers.ps1` | `acad-dev.sh blockers` first when anything stalls: it lists AutoCAD's dialogs and message boxes, Autodesk
  licensing helper windows and other windows in front, whether the main frame is disabled (a modal window), and the command line
  state (`CMDACTIVE` bits: 1 command, 2 transparent, 4 script, 8 dialog, 32 AutoLISP; `CMDNAMES`). Exit 6 = something blocks.
- Typical blockers: an add-in's own message box (a .NET `MessageBox.Show()` without an owner can block AutoCAD's UI thread without
  disabling the main frame, so the report lists it as `open (not blocking)`: if COM is rejected anyway, look at it first), a WPF/WinForms results window, "Component Updates Required", a
  licence / sign-in / trial screen, an unsigned-file security prompt, a "save changes?" prompt, a DCL dialog left open.
- A command waiting at the command line (no window) shows as `CMDACTIVE` 1 with `NO BLOCKERS`: that is a prompt, use `esc`.
- COM answers "no answer within 8 s" in the report when AutoCAD is computing or a call waits at a prompt/dialog; that is not an error of the report.
- AutoCAD's Drawing Recovery window (shown when AutoCAD restarts after a crash with unsaved drawings; a run can't use the drawing until
  it is closed) is closed by the guard on its own (built-in rule, WM_CLOSE, which a dialog treats as Cancel; `acad-cmd.ps1` also runs
  the guard while attaching). Closing it should leave the recovered files where AutoCAD keeps them (untested here); reopen them by
  hand (`DRAWINGRECOVERY`) if you need them. A `blockers.txt` line `^Drawing Recovery :: any :: report` keeps it open.
- A Windows Update "restart to install" prompt belongs to another process and can't be dismissed from the automation session. The
  report notes it (never touches it); dismiss it by hand, or on a VM you own run `harden-automation-vm.ps1` once (opt-in: turns off
  automatic installs and restarts and pauses updates).
- The guard never answers security prompts, licence / sign-in / trial screens or "save changes?" prompts (built-in denylist, wins
  over `blockers.txt`). It does not touch other programs' windows either. Only windows the user wrote into `blockers.txt` (and Drawing Recovery) are
  dismissed, and never by pressing Save, Yes, No, Discard, Trust, Load, Accept or Sign in.
- Windows in a different session or on another desktop (a locked screen, a secure desktop prompt such as UAC) cannot be seen or
  closed from here: the report then shows no window, the screenshot shows a black or locked screen.
- An invisible window (hidden, or on a virtual desktop that is cloaked) is not listed.

## COM
- COM calls hang or are rejected (`RPC_E_CALL_REJECTED`, 0x80010001) while AutoCAD waits at a prompt or shows a modal dialog,
  or while it is still starting. At a prompt a call usually just waits (hangs until the prompt is answered); in `run`/`query`
  a call rejected as busy is retried first (see the AutoCAD Electrical note below), so at a dialog it fails only after that wait. Never leave a command half-answered. `esc.ps1` gets out of a prompt; `shot.ps1` shows the screen.
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
- To start AutoCAD Electrical, pass `/product ACADE` **and** its profile `/p "<<ACADE>>"` (`start --product ACADE --profile
  '<<ACADE>>'`), the switches its desktop shortcut uses. `$acad.Name` still reads "AutoCAD" under Electrical: look for the
  Electrical ribbon tabs (Project, Schematic, Panel) in a screenshot instead.
- AutoCAD Electrical 2026 asks at start for the 64-bit **Microsoft 365 Access Runtime** ("Component Updates Required", for the
  Catalog Browser). Installing it (Microsoft's Click-to-Run `AccessRuntimeRetail` x64) stops the dialog.
- AutoCAD Electrical rejects COM calls (`RPC_E_CALL_REJECTED`) while it is only busy, not waiting at a prompt: partway through
  a long batch, and reliably right after closing drawings. `run`/`query` handle this: `acad-cmd.ps1` registers an OLE message
  filter (`Register-ComRetry` in `common.ps1`) that retries a rejected call every 100 ms for up to `ACAD_DEV_COM_RETRY_SEC`
  seconds (default 30, at most 600; 0 turns it off), and `trust-paths.ps1` (`start -Trust`) does the same. A setting it can't
  use, or a filter it can't register, shows as a `com retry off` / `ignored` line in the result. The retry applies to the
  query and commands, not to the attach and the first reads before them.
- After a `TIMEOUT` the worker may still be running in the session (the task is deleted, its process is not), and it can
  write into the next run's result. Wait out the retry window, or check with a screenshot, before the next `run`.
- The ribbon, palettes and other UI appear a moment after the drawing opens; a COM query can run before they exist.

## Ribbon, dialogs and alerts (`ui`)
- The ribbon is visible to UI Automation from outside AutoCAD: tabs are buttons under the id `mMainTabs`; a button is an element
  with the id `<command id>_RibbonItemControl` named by its label; a split button's command part is `<id>_FlyoutButtonExecute`; a
  panel's title bar (`<panel id>_PanelTitleBar`) opens its slide-out, a separate popup under the main window.
- UI Automation's Toggle on a ribbon button only flips how it looks; it does **not** run the command. `ui` clicks it with the real mouse.
- Text typed right after a ribbon click can be lost: the button's macro starts with `^C^C`, which cancels what is pending. `ui`
  waits until AutoCAD has started the command before the next step.
- DCL dialogs have the window class `adesk_dlg*` (not `#32770`), with ordinary child controls: `Static` labels before `Edit`,
  `ComboBox` (popup_list) and `ListBox`; toggles are check boxes, radio buttons plain `BS_RADIOBUTTON`s that DCL manages. An edit
  box's `action_tile` runs only when the box reports losing the focus (`EN_KILLFOCUS`), which `ui`'s `set` sends.
- A LISP `alert` is a `#32770` "AutoCAD Message" box. While a modal dialog is open AutoCAD's main window is disabled.
- Starting a command with COM `SendCommand` from a process that then exits, while the command shows a DCL dialog, leaves that
  dialog ignoring its buttons (they act only after real mouse input). `ui` starts commands with `WM_COPYDATA` to the main window
  instead, which returns at once and leaves nothing waiting.
- While the mouse rests on the ribbon (a tool tip open), AutoCAD silently drops text typed with `WM_COPYDATA`. `ui` parks the mouse on
  the command line after a ribbon click and before typing: not over the drawing, where each jump of the cursor moves the rubber band of
  a prompt waiting for a point or distance (Retrace's recorder logged those as answers).
- Bringing a window to the front with an Alt tap puts AutoCAD into menu mode for a moment; Retrace's recorder logged that as a modal
  window titled like AutoCAD's main window. `ui`'s `keys` and `click <label>` don't tap Alt (they click the title bar if they must).
- Retrace's recorder sees how a dialog closed only from real input: close dialogs with `click OK` / `keys {ENTER}` when recording.
- `SECURELOAD` asks about `.lsp` files too, not only dlls: load LISP from a `TRUSTEDPATHS` folder or a person answers.

## Misc
- In commands sent with `run`, `\n` is Enter, so `C:\new\plan.dwg` breaks at `\n`. Write paths with forward slashes (`C:/new/plan.dwg`). A literal `|` cannot be sent: it separates commands.
- Screenshots use the primary screen at its current size; a locked or disconnected RDP session gives a black or failing capture.
  Keep the Windows session unlocked and connected.
- Close test drawings with `Close($false)` (no save). A "save changes?" dialog is a modal dialog that blocks COM.
- Do not run two scripts that use the same task name at once (`AcadDevCmd`, `AcadDevReady`, ...): run them one after the other.

- Posted Esc key messages (`PostMessage WM_KEYDOWN`) are ignored while AutoCAD waits at a command prompt. `esc.ps1` brings AutoCAD to the foreground and sends real keystrokes (SendKeys), which works. A hidden scheduled task (remote mode) may not take the foreground (Windows' foreground lock), so it taps Alt first, which lifts the lock. If AutoCAD still cannot be brought to the front it posts Esc to AutoCAD's focused control and says `foreground: False` (`acad-dev.sh esc` exits 3): check with a query or a screenshot before going on.
- A floating palette (External References, Properties...) can hold the keyboard focus. Keys sent while it is in front stay in the palette, so the command line keeps waiting. `esc.ps1` therefore counts only the frame, or a dialog (`#32770`) the frame owns, as "AutoCAD in front". When a palette is in front, it brings the frame forward first. (Seen 2026-10-17: Esc reported success, but OPEN still waited until the palette was closed.)
- Even in the interactive session, `Process.MainWindowHandle` of acad.exe can be an untitled WPF helper window, not AutoCAD's frame;
  keystrokes sent there are lost. Find the frame among the process's visible, unowned top-level windows by its MFC frame class
  (`AfxMDIFrame140u` on AutoCAD 2026; titles vary: `Autodesk AutoCAD 2026 - [x.dwg]`, `AutoCAD Electrical 2026 - UNREGISTERED VERSION - [x.dwg]`), as `esc.ps1` does.
- **One driver at a time.** All calls share the work folder (`cmds.txt`, `query.ps1`, `out\`) and the scheduled-task names. Two sessions or agents driving the same AutoCAD at once overwrite each other's files and tasks, and calls time out. Run one at a time.
- Do not type AutoLISP to read a variable (`(getvar "FILEDIA")` left on the command line without Enter blocks the next command); use a COM query: `$doc.GetVariable('FILEDIA')`.

## SDI mode
`SDI` = 0 multiple drawings; 1 single (user setting); 2, 3 single, forced by a loaded app (read-only). Treat any non-zero as SDI. Seen on AutoCAD Electrical 2026 with `SDI=1`:
- AutoCAD always has exactly one drawing open, and starts with `Drawing1` (no Start tab). `stop-acad`, `run` and `start -Trust` work as usual.
- `Documents.Add()` throws `0x80210071` "Method not available in SDI mode". `ActiveDocument.New('')` replaces the drawing with a blank one (about 1.3 s, `Documents.Count` stays 1).
- `Documents.Open(path)` and `New('')` replace the current drawing and, if it has unsaved changes, block on a modal "Save changes?" dialog (the COM call hangs). Don't call them on an unsaved drawing.
- `Close()` / `Close($false)` on the only drawing **quits AutoCAD**, with no prompt even when unsaved. Avoid sending the `CLOSE` command in SDI mode too (not tested; expect it to quit AutoCAD); `NEW` / `OPEN` replace the drawing and prompt to save if unsaved.
- To discard unsaved changes without quitting: `SaveAs` to a temp file, `New('')`, delete the temp file (and its `.bak`). The original file on disk is untouched (`queries/q-discardall.ps1`). Tested on drawings outside an AutoCAD Electrical project; a project drawing's save hooks may prompt.
- `q-newdoc`, `q-closeall` and `q-discardall` do the right thing in both modes (`Get-AcadSdi` in `common.ps1`). With no drawing open `SDI` can't be read; that only happens in MDI, so it counts as 0.
