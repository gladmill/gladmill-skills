# scripts

Work folder: `ACAD_DEV_HOME` (default `%USERPROFILE%\acad-dev`); output in `<home>\out\`. Run PowerShell scripts as
`powershell -NoProfile -ExecutionPolicy Bypass -File <script>`. Scripts that need the desktop run directly when you are in an
interactive session (local mode) and through a one-shot interactive scheduled task from SSH/session 0 (remote mode).

| Script | What it does |
|---|---|
| `acad-dev.sh <cmd>` | Remote mode wrapper for Mac/Linux/WSL (needs `ACAD_DEV_SSH_HOST`): `install`, `start`, `wait`, `stop`, `run`, `query`, `shot`, `screen`, `esc`, `cancel`, `fetch`. Run without arguments for help. |
| `common.ps1` | Shared helpers: work folder, `Test-Interactive`, `Find-Acad` (registry, 2024-2026, or `ACAD_DEV_EXE`), `Invoke-InSession`, `Save-Screenshot`. |
| `start-acad.ps1 [-Exe] [-Product] [-Profile] [-Trust] [-TimeoutSec]` | Starts AutoCAD in the interactive session and waits until it is ready. `ACAD_DEV_EXE`, `ACAD_DEV_PRODUCT`, `ACAD_DEV_PROFILE` (`/p`) override; `acad-dev.sh start` passes its own `--exe`/`--product`/`--profile` or local `ACAD_DEV_*`. `-Trust` / `ACAD_DEV_TRUSTED`: folders added to `TRUSTEDPATHS` once ready (via `trust-paths.ps1`). |
| `wait-acad.ps1 [-TimeoutSec 240]` | Returns `ready after Ns` (exit 0) when AutoCAD answers over COM and is quiescent; exit 1 on timeout with the last state. |
| `acad-ready.ps1` | Task-side probe used by `wait-acad.ps1`: writes `ready`, `busy` or `none: <reason>` to `out\ready.txt`. |
| `stop-acad.ps1 [-DiscardChanges] [-Force]` | Quits AutoCAD. Default refuses (prints `REFUSED`) if any drawing has unsaved changes; `-DiscardChanges` closes them without saving first; `-Force` kills a hung AutoCAD. |
| `run-in-session.ps1 -Cmds "..." [-Query q.ps1] [-WaitSec n] [-TimeoutSec n] [-Staged]` | Sends commands (`\|` separated, `\n` = Enter; use forward slashes in paths; the timeout defaults to commands x (WaitSec+1) + 60 s) and optionally runs a COM query first; prints the command-line log tail; screenshot in `out\screen.png`. |
| `acad-cmd.ps1` | The worker `run-in-session.ps1` starts in the session. Reads `cmds.txt` / `query.ps1` from the work folder. |
| `run-task.ps1 <script> [-Title t]` | Runs `esc.ps1`, `shot.ps1` or `wincancel.ps1` where a desktop exists. |
| `esc.ps1` | Brings AutoCAD to the front and presses Esc twice (no COM): leaves a prompt. Prints `foreground: False` (`acad-dev.sh esc` exits 3) if it could only post Esc. |
| `shot.ps1` | Screenshot without COM to `out\shot.png`. |
| `wincancel.ps1 [-Title t] [-Close]` | Posts IDCANCEL (or WM_CLOSE with `-Close`, for WPF dialogs) to a window with that exact title; lists visible windows; screenshot. |
| `run-hidden.vbs <command...>` | Runs a command with no console window (used by every scheduled task). |
| `trial-watch.ps1`, `install-trial-watch.ps1` | Optional: logon task `AcadDevTrialWatch` that closes AutoCAD's trial start-up window for 5 minutes after AutoCAD starts. Never signs in. Remove: `schtasks /delete /tn AcadDevTrialWatch /f` and stop its powershell. |
| `queries/q-newdoc.ps1` | Query: open a new drawing (run it in a call of its own). |
| `queries/q-ents.ps1` | Query: model-space entity counts by type, some system variables, open drawings. |
| `queries/q-closeall.ps1` | Query: close all drawings, refusing if any has unsaved changes. |
| `queries/q-discardall.ps1` | Query: close all drawings without saving (test drawings only). |

Settings: `ACAD_DEV_HOME`, `ACAD_DEV_SSH_HOST` (remote), `ACAD_DEV_EXE`, `ACAD_DEV_PRODUCT`, `ACAD_DEV_PROFILE`, `ACAD_DEV_TRUSTED`, `ACAD_DEV_FORCE_TASK=1` (force the scheduled-task path).
In remote mode set `ACAD_DEV_HOME` as a user environment variable on the Windows machine (`setx ACAD_DEV_HOME D:\acad-dev`).
