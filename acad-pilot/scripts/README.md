# scripts

Work folder: `ACAD_DEV_HOME` (default `%USERPROFILE%\acad-dev`); output in `<home>\out\`. Run PowerShell scripts as
`powershell -NoProfile -ExecutionPolicy Bypass -File <script>`. Scripts that need the desktop run directly when you are in an
interactive session (local mode) and through a one-shot interactive scheduled task from SSH/session 0 (remote mode).

| Script | What it does |
|---|---|
| `acad-dev.sh <cmd>` | Remote mode wrapper for Mac/Linux/WSL (needs `ACAD_DEV_SSH_HOST`): `install`, `start`, `wait`, `stop`, `run`, `query`, `blockers`, `status`, `shot`, `screen`, `esc`, `cancel`, `fetch`. Run without arguments for help. |
| `status.ps1 [-Json] [-NoScan]` | **Run it first when anything looks stuck.** The status board: reads every file in the status folder (`ACAD_STATUS_DIR`, default `%ProgramData%\Gladmill\acad-status`) and prints an overall line plus one line per entry (source, state, age, summary; for `acad` the prompt and the open dialog), says whether acad.exe runs and whether an `acad` entry exists. Quick with the AcadStatus add-in; without it (acad.exe runs, no `acad` entry), and when the status is blocked or busy, it also runs the read-only blocker scan (never `-Apply`; a few seconds; `-NoScan` skips it; skipped when acad.exe is not running). `-Json`: one object `{overall, exitCode, acadRunning, entries[], ignored[], skipped[], notes[], scan}`. Exit 0 idle / nothing, 3 running, 4 waiting-input or needs-person, 5 busy, 6 blocked, 1 error or unknown state, 2 setup error. Remote: `acad-dev.sh status [--json] [--no-scan]`. Format and states: `references/status-board.md`. |
| `status-board.ps1` | Pure functions of the status board (parse a status file, merge, rank, exit code, board text, the document a writer writes). No Win32, no disk. Not loaded by `common.ps1`: `status.ps1`, `run-in-session.ps1`, `ui.ps1`, `wait-acad.ps1`, `start-acad.ps1` and `stop-acad.ps1` dot-source it right after `common.ps1`. |
| `blockers.ps1 [-Apply] [-NoShot] [-TimeoutSec 60]` | **First thing to run when anything stalls.** Reports what blocks AutoCAD (see "Blocker guard" below). Exit 0 nothing blocks, 6 `BLOCKED BY: ...`. Remote: `acad-dev.sh blockers [--apply] [--no-shot]`. |
| `blocker-worker.ps1` | Session-side worker of `blockers.ps1` (windows are only visible in the interactive session): scans, optionally applies the allowlist, writes `out\blockers.txt` and `out\blockers.png`. |
| `blocker-policy.ps1` | Pure functions: allowlist parser, built-in denylist, `Resolve-BlockerAction`, button matching, blocking rule, the guard lock, `Test-ComRejected`. No Win32; tested by `tests/blocker-policy.tests.ps1` in the repo. |
| `common.ps1` | Shared helpers: work folder, `Test-Interactive`, `Find-Acad` (registry, 2024-2026, or `ACAD_DEV_EXE`), `Invoke-InSession` (always bounded by its timeout, also in an interactive session), `Register-ComRetry` (retry COM calls AutoCAD rejects as busy), `Get-BlockerReport` / `Invoke-Guarded` (the blocker guard), `Get-AcadStatusDir` / `Write-AcadStatus` / `Update-AcadStatusHeartbeat` (the kit's line on the status board, one file `acad-pilot-<pid>.json` per process: `Start-AcadStatus`, `Stop-AcadStatus` (state `stopped` with the result), `Set-AcadStatusError`, `Update-AcadStatusHeartbeat`; written by `run-in-session.ps1`, `ui.ps1`, `wait-acad.ps1`, `start-acad.ps1` and `stop-acad.ps1`; `ACAD_STATUS=0` turns it off), `Save-Screenshot`. |
| `start-acad.ps1 [-Exe] [-Product] [-Profile] [-Trust] [-TimeoutSec]` | Starts AutoCAD in the interactive session and waits until it is ready. `ACAD_DEV_EXE`, `ACAD_DEV_PRODUCT`, `ACAD_DEV_PROFILE` (`/p`) override; `acad-dev.sh start` passes its own `--exe`/`--product`/`--profile` or local `ACAD_DEV_*`. `-Trust` / `ACAD_DEV_TRUSTED`: folders added to `TRUSTEDPATHS` once ready (via `trust-paths.ps1`). |
| `trust-paths.ps1` | Session-side: adds the folders in `<home>\trust.txt` to `TRUSTEDPATHS`; result in `out\trust.txt`. |
| `wait-acad.ps1 [-TimeoutSec 240]` | Returns `ready after Ns` (exit 0) when AutoCAD answers over COM and is quiescent. On timeout: exit 6 with `BLOCKED BY: ...` when a window is in the way, else exit 1 with the last state. Always finite (0 or less = 240, at most 3600). While waiting it deals with allowlisted windows (after 20 s, then every 60 s, and once more when time is up) and then waits up to 60 s more. |
| `acad-ready.ps1` | Task-side probe used by `wait-acad.ps1`: writes `ready`, `busy` or `none: <reason>` to `out\ready.txt`. |
| `stop-acad.ps1 [-DiscardChanges] [-Force]` | Quits AutoCAD. Default refuses (prints `REFUSED`) if any drawing has unsaved changes; `-DiscardChanges` closes them without saving first; `-Force` kills a hung AutoCAD. |
| `run-in-session.ps1 -Cmds "..." [-Query q.ps1] [-WaitSec n] [-TimeoutSec n] [-Staged]` | Sends commands (`\|` separated, `\n` = Enter; use forward slashes in paths; the timeout defaults to commands x (WaitSec+1) + 60 s) and optionally runs a COM query first; prints the command-line log tail; screenshot in `out\screen.png`. `-StallSec n` (default 30, 0 = off): a command that has run that long while AutoCAD answers COM as busy is checked by the blocker guard: a window the allowlist names is dealt with and the command carries on; a window it doesn't ends the run with `BLOCKED BY: ...` (exit 6, no Esc pressed); with no window the run stops (later commands not sent), prints `STUCK` and exits 4; `-Esc` then also presses Esc (exit 4 freed, 5 not). A run that times out, or whose `SendCommand` AutoCAD still rejects after the COM retry window, also prints the `BLOCKED BY` report and exits 6 (a rejected `SendCommand` is tried once more after an allowlisted window was dealt with; a query is never repeated on its own). Exit 1 stays for a timeout with nothing visible in the way. |
| `ui.ps1 -Steps 'a','b' \| -File steps.txt [-StepTimeoutSec 20] [-TimeoutSec n] [-Staged]` | Drives AutoCAD's UI step by step (ribbon clicks, commands that open dialogs, DCL / Win32 / WinForms / WPF dialogs, message boxes) and prints `ok`/`FAIL` per step. Runs `ui-run.ps1` in the interactive session. Exit 0 all passed, 1 a step failed (open dialogs listed, `out\ui-fail.png`), 2 bad input or a setup error (no step ran), 3 replaced by a newer `ui` run, 4 timeout (default: the steps' own waits + 60 s), 6 timeout with a window in AutoCAD's way. A failed step also ends with the `BLOCKED BY` report when one is in the way. `ui` never closes windows on its own account (steps wait for windows on purpose). Steps: below. |
| `ui-run.ps1` | The worker `ui.ps1` starts: reads `<home>\ui.txt`, writes `out\ui-result.txt`. |
| `acad-cmd.ps1` | The worker `run-in-session.ps1` starts in the session. Reads `cmds.txt` / `query.ps1` from the work folder. Retries COM calls AutoCAD rejects as busy (`ACAD_DEV_COM_RETRY_SEC`). |
| `run-task.ps1 <script> [-Title t]` | Runs `esc.ps1`, `shot.ps1` or `wincancel.ps1` where a desktop exists. |
| `esc.ps1` | Brings AutoCAD to the front and presses Esc twice (no COM): leaves a prompt. Prints `foreground: False` (`acad-dev.sh esc` exits 3) if it could only post Esc. |
| `shot.ps1` | Screenshot without COM to `out\shot.png`. |
| `wincancel.ps1 [-Title t] [-Close]` | Posts IDCANCEL (or WM_CLOSE with `-Close`, for WPF dialogs) to a window with that exact title; lists visible windows; screenshot. |
| `run-hidden.vbs <command...>` | Runs a command with no console window (used by every scheduled task). |
| `trial-watch.ps1`, `install-trial-watch.ps1` | Optional: logon task `AcadDevTrialWatch` that closes AutoCAD's trial start-up window for 5 minutes after AutoCAD starts. Never signs in. Remove: `schtasks /delete /tn AcadDevTrialWatch /f` and stop its powershell. |
| `harden-automation-vm.ps1` | Opt-in, for a Windows machine you own and use only for automation: turns off automatic Windows Update installs and restarts and pauses updates, so a "restart to install" prompt cannot interrupt a run. Keeps the first run's values on file. |
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

## Blocker guard

`blockers.ps1` / `acad-dev.sh blockers` answers "what is stopping AutoCAD?". It lists the visible dialogs of acad.exe (Win32, MFC,
DCL, WinForms, WPF, message boxes, task dialogs; modal and modeless) with title, class, kind (`dialog`, `messagebox`, `winforms`,
`wpf`), texts, buttons, enabled and whether it is MODAL/BLOCKING. A window counts as blocking only when AutoCAD's main frame is disabled (or the frame cannot be found yet, as at start-up); a licensing / sign-in window also when it is in front of the frame or owned by it. Everything else is listed as `open (not blocking)` and does not turn a stall or timeout into exit 6 (4 / `--esc` / 1 keep their meaning); Autodesk
licensing helper windows; other programs' windows in front of AutoCAD (listed, but they do not block COM); AutoCAD's
`CMDACTIVE` / `CMDNAMES` and `GetAcadState` if COM answers within 8 s; and a screenshot (`out\blockers.png`). The report starts
with `BLOCKED BY:` when something blocks, and the exit code is 6. It is called by `run` (stuck or timed out, or `SendCommand`
still rejected after the COM retry window), `wait` (timeout), and `ui` (timeout; a failed step). Run it yourself first whenever
anything stalls.

**Allowlist** (`blockers.txt` in the work folder, or the file named by `ACAD_DEV_BLOCKERS_FILE`; a sample ships in
`samples/blockers.sample.txt`). One rule per line, fields separated by ` :: `:

```
<title regex> :: <kind> :: <action>
Review Results$ :: wpf :: close
^Export finished$ :: messagebox :: press OK
```

- title regex: .NET regex, case-insensitive, matched anywhere in the title.
- kind: `any`, `dialog`, `messagebox`, `winforms`, `wpf`, or `class=<regex>` on the window class (matched case-sensitively, as written; only the word `class` is case-insensitive). Only dialog-like windows of acad.exe are looked at: Win32/MFC/DCL dialogs, message boxes, titled WinForms and WPF windows.
- action: `close` (WM_CLOSE, then Cancel for a classic dialog), `press <button>` (that button's label, `&` ignored, case-insensitive, in Win32, WinForms and WPF windows alike; if the window has no such button the rule does not apply and later rules are tried), `report` (do nothing; the default for every window no rule names).
- First matching rule wins; `#` comments and blank lines are ignored; a bad line is ignored with a `warning:` line in the report.

Allowlisted actions are applied only with `blockers.ps1 -Apply` (`blockers --apply`) and, automatically, by the guard inside `run`
(a stalled command), `wait` (while waiting) and a rejected `SendCommand`; each logs what it did, then continues (one guard applies actions at a time: a lock file `out\blockers.lock` with the pid, stale after 120 s; a second guard waits up to 10 s, then only reports; each call has its own result file and task name; a rejected `SendCommand` is not resent if its run was stopped or replaced meanwhile): the stalled command
carries on, `wait` waits again, a rejected `SendCommand` is sent once more. Set `ACAD_DEV_BLOCKER_ACTIONS=0` (on the machine
running the scripts; in remote mode on the Windows box) to make the guard report only. `ui` never applies the allowlist (it only closes a Drawing Recovery window before its first step).

**Built-in rule: Drawing Recovery.** AutoCAD's "Drawing Recovery" window, which appears when AutoCAD restarts after a crash with unsaved
drawings and keeps COM from answering, is closed by the guard without any `blockers.txt` line (WM_CLOSE, which a dialog treats as
Cancel: nothing is saved or deleted; reopen the recovered files by hand with `DRAWINGRECOVERY` if you need them). It is applied wherever the
guard applies the allowlist, and up front (a quick title scan, no report) before `run`/`query` attach to AutoCAD and before `ui`'s first step, so `ACAD_DEV_BLOCKER_ACTIONS=0` turns it off too;
a `blockers.txt` line such as `^Drawing Recovery :: any :: report` keeps it open. Only windows of acad.exe are ever touched: a browser or
folder with that title is not. This replaces the former `clear-blockers.ps1`.

**Windows Update prompt.** A "restart to install" prompt (another process) cannot be dismissed from the automation session. The report
lists it as a note and never touches it; dismiss it by hand, or on a VM you own run `harden-automation-vm.ps1` once.

**Denylist (built in, wins over the allowlist, cannot be switched off).** The guard only reports these, never closes or presses
anything in them: AutoCAD security prompts (title `Security ...`, or text about unsigned / untrusted files, `SECURELOAD`,
`TRUSTEDPATHS`, buttons `Load once` / `Always load` / `Do not load`); licence, sign-in, login, subscription, trial, activation
screens (title or text), and every window of the Autodesk licensing helper processes; "save changes?" prompts (text about saving
changes, or a Save button next to Don't save / Discard / No). Windows of other programs are report-only too. Even in an
allowlisted window the guard will not press Save, Yes, No, Don't save, Discard, Trust, Load, Accept, Agree, Sign in, Activate,
Buy or Subscribe. When a denied window is open it shows as `policy: never touched: ...` and a person decides.

**Bounded waits.** Every wait ends: `wait-acad` (clamped 1-3600 s), `run` (timeout from the commands, `--timeout`), `ui` (step
timeout, run timeout), `start` (1 minute for the process, then `wait`), `stop` (30 s / 15 s), scheduled-task polls (their
`-TimeoutSec`), the COM retry window (`ACAD_DEV_COM_RETRY_SEC`, at most 600 s) and every ssh/scp call (connect
timeout and keep-alives). A script run directly in an interactive session is now a child process with the same timeout (its exit code passes through unchanged), so a worker stuck in a call to
AutoCAD is ended instead of hanging for ever; a worker stopped as stuck (`STUCK`/`BLOCKED`) is ended too in local mode, and `--esc` then asks AutoCAD itself whether it came free. `trial-watch.ps1` is a background service loop by design (idle after 5 minutes).

Settings: `ACAD_DEV_BLOCKER_ACTIONS` (0 = the guard never applies the allowlist on its own), `ACAD_DEV_BLOCKERS_FILE` (path of the allowlist), `ACAD_DEV_HOME`, `ACAD_DEV_SSH_HOST` (remote), `ACAD_DEV_EXE`, `ACAD_DEV_PRODUCT`, `ACAD_DEV_PROFILE`, `ACAD_DEV_TRUSTED`, `ACAD_DEV_COM_RETRY_SEC` (seconds a busy-rejected COM call is retried, default 30, 0 = off; set on the Windows machine), `ACAD_DEV_FORCE_TASK=1` (force the scheduled-task path), `ACAD_STATUS_DIR` (the status board folder, default `%ProgramData%\Gladmill\acad-status`), `ACAD_STATUS=0` (the kit writes no status line), `ACAD_STATUS_OWNER` (who started the work, written into the status line), `ACAD_STATUS_DETAIL=0` (no command or step text in the status line; the folder is readable by every local user). In remote mode `acad-dev.sh` passes the four `ACAD_STATUS*` settings that are set on the machine running it to the box on every call.
In remote mode set `ACAD_DEV_HOME` as a user environment variable on the Windows machine (`setx ACAD_DEV_HOME D:\acad-dev`).
