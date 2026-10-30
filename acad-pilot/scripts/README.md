# scripts

Work folder: `ACAD_DEV_HOME` (default `%USERPROFILE%\acad-dev`); output in `<home>\out\`. Run PowerShell scripts as
`powershell -NoProfile -ExecutionPolicy Bypass -File <script>`. Scripts that need the desktop run directly when you are in an
interactive session (local mode) and through a one-shot interactive scheduled task from SSH/session 0 (remote mode).

| Script | What it does |
|---|---|
| `acad-dev.sh <cmd>` | Remote mode wrapper for Mac/Linux/WSL (needs `ACAD_DEV_SSH_HOST`): `install`, `start`, `wait`, `stop`, `run`, `query`, `shot`, `screen`, `esc`, `cancel`, `fetch`. Run without arguments for help. |
| `common.ps1` | Shared helpers: work folder, `Test-Interactive`, `Find-Acad` (registry, 2024-2026, or `ACAD_DEV_EXE`), `Invoke-InSession`, `Register-ComRetry` (retry COM calls AutoCAD rejects as busy), `Save-Screenshot`. |
| `start-acad.ps1 [-Exe] [-Product] [-Profile] [-Trust] [-TimeoutSec]` | Starts AutoCAD in the interactive session and waits until it is ready. `ACAD_DEV_EXE`, `ACAD_DEV_PRODUCT`, `ACAD_DEV_PROFILE` (`/p`) override; `acad-dev.sh start` passes its own `--exe`/`--product`/`--profile` or local `ACAD_DEV_*`. `-Trust` / `ACAD_DEV_TRUSTED`: folders added to `TRUSTEDPATHS` once ready (via `trust-paths.ps1`). |
| `wait-acad.ps1 [-TimeoutSec 240]` | Returns `ready after Ns` (exit 0) when AutoCAD answers over COM and is quiescent; exit 1 on timeout with the last state. |
| `acad-ready.ps1` | Task-side probe used by `wait-acad.ps1`: writes `ready`, `busy` or `none: <reason>` to `out\ready.txt`. |
| `stop-acad.ps1 [-DiscardChanges] [-Force]` | Quits AutoCAD. Default refuses (prints `REFUSED`) if any drawing has unsaved changes; `-DiscardChanges` closes them without saving first; `-Force` kills a hung AutoCAD. |
| `run-in-session.ps1 -Cmds "..." [-Query q.ps1] [-WaitSec n] [-TimeoutSec n] [-Staged]` | Sends commands (`\|` separated, `\n` = Enter; use forward slashes in paths; the timeout defaults to commands x (WaitSec+1) + 60 s) and optionally runs a COM query first; prints the command-line log tail; screenshot in `out\screen.png`. |
| `ui.ps1 -Steps 'a','b' \| -File steps.txt [-StepTimeoutSec 20] [-TimeoutSec n] [-Staged]` | Drives AutoCAD's UI step by step (ribbon clicks, commands that open dialogs, DCL / Win32 / WinForms / WPF dialogs, message boxes) and prints `ok`/`FAIL` per step. Runs `ui-run.ps1` in the interactive session. Exit 0 all passed, 1 a step failed (open dialogs listed, `out\ui-fail.png`), 2 bad input or a setup error (no step ran), 3 replaced by a newer `ui` run, 4 timeout (default: the steps' own waits + 60 s). Steps: below. |
| `ui-run.ps1` | The worker `ui.ps1` starts: reads `<home>\ui.txt`, writes `out\ui-result.txt`. |
| `acad-cmd.ps1` | The worker `run-in-session.ps1` starts in the session. Reads `cmds.txt` / `query.ps1` from the work folder. Retries COM calls AutoCAD rejects as busy (`ACAD_DEV_COM_RETRY_SEC`). |
| `run-task.ps1 <script> [-Title t]` | Runs `esc.ps1`, `shot.ps1` or `wincancel.ps1` where a desktop exists. |
| `esc.ps1` | Brings AutoCAD to the front and presses Esc twice (no COM): leaves a prompt. Prints `foreground: False` (`acad-dev.sh esc` exits 3) if it could only post Esc. |
| `shot.ps1` | Screenshot without COM to `out\shot.png`. |
| `wincancel.ps1 [-Title t] [-Close]` | Posts IDCANCEL (or WM_CLOSE with `-Close`, for WPF dialogs) to a window with that exact title; lists visible windows; screenshot. |
| `run-hidden.vbs <command...>` | Runs a command with no console window (used by every scheduled task). |
| `trial-watch.ps1`, `install-trial-watch.ps1` | Optional: logon task `AcadDevTrialWatch` that closes AutoCAD's trial start-up window for 5 minutes after AutoCAD starts. Never signs in. Remove: `schtasks /delete /tn AcadDevTrialWatch /f` and stop its powershell. |
| `queries/q-newdoc.ps1` | Query: open a new drawing (run it in a call of its own). SDI mode: replaces the drawing, refuses if unsaved. |
| `queries/q-ents.ps1` | Query: model-space entity counts by type, some system variables (incl. `SDI`), open drawings. |
| `queries/q-closeall.ps1` | Query: close all drawings, refusing if any has unsaved changes. SDI mode: replaces the drawing with a blank one (closing it would quit AutoCAD). |
| `queries/q-discardall.ps1` | Query: close all drawings without saving (test drawings only). SDI mode: replaces the drawing with a blank one. |

## ui steps

One per line in `ui.txt` (`#` comments). Each waits for what it needs, up to the step timeout.

| Step | What it does |
|---|---|
| `command <text>` | Types a command at the Command: prompt (WM_COPYDATA to AutoCAD's window; `\n` = Enter, one added at the end) and goes on as soon as AutoCAD has taken it. Refused while a dialog is open or AutoCAD is busy. |
| `type <text>` | The same without the checks: answers the prompt that is waiting (`type 10,10`, `type \n`). |
| `idle [sec]` | Waits until AutoCAD is quiescent (COM `GetAcadState`) with no modal dialog open (modeless windows may stay). |
| `ribbon [<tab>/][<panel>/]<button>` | Clicks a ribbon button (real mouse click at its centre, found with UI Automation by label or id, e.g. `ID_Line`). A split button is clicked on its command part. With a panel, a button not on the panel's face is looked for in its slide-out. Fails if a modal dialog is open or another program's window covers the button after AutoCAD was brought forward. |
| `dialog <title>` | Waits for a visible dialog of AutoCAD's with that title (`*` wildcards) and makes it the target. |
| `alert [<title>]` | Waits for a message box (LISP `alert`, MessageBox, task dialog), prints its text, makes it the target. |
| `read` | Lists the target's controls, labels and values. |
| Labels | Matched as read: `&` and a trailing `:` ignored, `Check` = `Check...`. For controls also a start that only one control has (`Save names` = `Save names (1)`); dialog titles, ribbon tabs and list items match exactly (or with `*` for titles). |
| `set <label>=<value>` | Edit box, drop-down (an item, or text if it is editable), list (`a;b`), check box (`on`/`off`), radio button (`on`). |
| `press <button>` | Presses a button (WM_COMMAND / UI Automation Invoke). |
| `click <label>` | A real mouse click in the middle of a control of the target, brought to the front first (no Alt tap). For recorders that watch real input. |
| `expect <regex>` | Fails unless the target's title, texts or values match. |
| `closed [<title>]` | Waits until the target (or a dialog with that title) has closed. |
| `dialogs` | Lists AutoCAD's dialogs: active or disabled, in front or not, off screen. |
| `front [<title>]` | Brings the target (or AutoCAD) to the front; moves a dialog that is off every monitor onto the screen. As a last resort it taps Alt, which a test recorder logs as a window: don't use it while recording. |
| `keys <sendkeys>`, `click <x>,<y>`, `move <x>,<y>` | Real keystrokes to the target / a real click at a screen point on an AutoCAD window / the mouse rested there (hover): last resort. |
| `shot [name]`, `sleep <ms>`, `timeout <sec>` | Screenshot to `out\<name>.png`, pause, change the step timeout. |

Security prompts (`Security - ...`) can be read but never answered; while one is open, `set`, `press`, `keys` and `click` refuse. `set` and `press` also refuse a dialog that is disabled because another one is open on top of it.

Settings: `ACAD_DEV_HOME`, `ACAD_DEV_SSH_HOST` (remote), `ACAD_DEV_EXE`, `ACAD_DEV_PRODUCT`, `ACAD_DEV_PROFILE`, `ACAD_DEV_TRUSTED`, `ACAD_DEV_FORCE_TASK=1` (force the scheduled-task path).
In remote mode set `ACAD_DEV_HOME` as a user environment variable on the Windows machine (`setx ACAD_DEV_HOME D:\acad-dev`).
