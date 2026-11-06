# AutoCAD Pilot for Claude Code

A skill that lets Claude Code drive AutoCAD for you: start AutoCAD, type commands into it, read the command line,
query the drawing, take screenshots, and get past stuck prompts and dialogs, all without you copy-pasting between
Claude and AutoCAD.

What is in the box:
- A Claude Code skill (`acad-pilot`) with the workflow, the traps to avoid, and COM query recipes.
- PowerShell scripts (and an SSH wrapper) that do the driving: start, stop, ready, send commands, COM queries,
  screenshots, Esc, window cancel, and a blocker guard that tells you what is in AutoCAD's way.
- A UI driver (`ui`) for what commands alone can't reach: it clicks ribbon buttons (including split buttons and panel
  slide-outs), fills and answers dialogs (your LISP's DCL dialogs, AutoCAD's own dialogs, .NET WinForms and WPF dialogs) and
  message boxes (`alert`), checks what they say, and reports each step as ok or FAIL. It finds dialogs whether or not they are
  in front, even behind other windows or off screen. A sample LISP command with a DCL dialog (`samples/kit-dialog.lsp`) shows how.
- Works with AutoCAD 2024, 2025 and 2026 (and verticals such as Electrical, with a setting).

This is the free, open-source part. It is MIT licensed (see LICENSE).

## Requirements
- Windows with AutoCAD 2024 or newer, licensed and signed in once by you.
- Claude Code (any plan that runs skills).
- PowerShell 5.1 (included in Windows). Remote mode also needs an SSH server on the Windows machine (OpenSSH Server) and
  `ssh`/`scp` (plus `iconv` and `base64`, standard on Mac/Linux/WSL/Git Bash) on the machine running Claude Code. The SSH default
  shell on the Windows machine can be either `cmd.exe` (the Windows OpenSSH default) or PowerShell: `acad-dev.sh` sends every
  remote call as `powershell -EncodedCommand`, so it does not depend on the shell.

## Install
Download the latest zip, watch the two demo recordings, or sign up for release news at **https://gladmill.com/pilot/**. Then:

1. Copy the `acad-pilot` folder to `~/.claude/skills/` (all projects) or to `<your project>/.claude/skills/` (one project).
   On Windows `~` is `C:\Users\<you>`.
2. Start Claude Code. Ask: "Use the acad-pilot skill to start AutoCAD and tell me when it is ready."

## First run
Local mode (Claude Code on the Windows machine, in your logged-in session):
- Nothing to configure. Ask Claude: "Start AutoCAD, open a new drawing, draw a line from 0,0 to 100,100 and count the
  objects in model space." Claude starts AutoCAD, sends the commands, reads back the count and shows a screenshot.
- Output and scratch files go to `%USERPROFILE%\acad-dev` (change with the environment variable `ACAD_DEV_HOME`).

Remote mode (Claude Code on a Mac/Linux/other Windows machine, AutoCAD on a Windows box):
1. On the Windows box: install OpenSSH Server, log in to Windows with the account that will run AutoCAD and keep that session
   unlocked and connected (AutoCAD needs a desktop; SSH itself has none, so the skill uses a one-shot scheduled task in your session).
2. Set up key-based SSH login (no password prompt), then on the machine running Claude Code:
   `export ACAD_DEV_SSH_HOST=<ssh host or user@host>`
3. Run once: `bash <skill>/scripts/acad-dev.sh install`. Then ask Claude as above.

## Settings
| Variable | Meaning |
|---|---|
| `ACAD_DEV_HOME` | Work folder on the Windows machine. Default `%USERPROFILE%\acad-dev`. Remote mode: also set it as a user environment variable there. No spaces in remote mode. |
| `ACAD_DEV_SSH_HOST` | Remote mode: the SSH host of the Windows machine. |
| `ACAD_DEV_EXE` | Full path to `acad.exe` if the registry lookup finds the wrong one. Same as `start-acad.ps1 -Exe` / `acad-dev.sh start --exe`. |
| `ACAD_DEV_PRODUCT` | `/product` switch (e.g. `ACAD`) if a vertical product starts instead of plain AutoCAD, or `ACADE` to start AutoCAD Electrical. Same as `start-acad.ps1 -Product` / `acad-dev.sh start --product`. |
| `ACAD_DEV_PROFILE` | `/p` switch: the AutoCAD profile to start with. AutoCAD Electrical needs `<<ACADE>>` with `ACAD_DEV_PRODUCT=ACADE`. Same as `start-acad.ps1 -Profile` / `acad-dev.sh start --profile`. |
| `ACAD_DEV_COM_RETRY_SEC` | How long a COM call AutoCAD rejects as busy (`RPC_E_CALL_REJECTED`) is retried before it fails, in seconds. Default 30, at most 600; 0 turns retrying off. Read on the Windows machine (remote mode: set it there as a user environment variable). |
| `ACAD_DEV_BLOCKERS_FILE` / `ACAD_DEV_BLOCKER_ACTIONS` | The blocker guard's allowlist file (default `blockers.txt` in the work folder) and `0` to stop it dismissing windows on its own. Read on the Windows machine. |
| `ACAD_DEV_TRUSTED` | Folders to add to AutoCAD's trusted locations (`TRUSTEDPATHS`) at start, `;`-separated; end one with `\...` to include subfolders. Same as `acad-dev.sh start --trust "..."`. Plugins you load from there skip the "unsigned executable" dialog. You choose these folders: anything that can write to them gets code loaded into AutoCAD. |
| `ACAD_STATUS_DIR` | The status board folder. Default `%ProgramData%\Gladmill\acad-status`. Set it where the scripts and the other tools run (remote mode: on the Windows machine). |
| `ACAD_STATUS` | `0`: the kit's scripts write no line to the status board. |
| `ACAD_STATUS_OWNER` | Who started the work (shown as `owner` on the board), for example `claude`. |
| `ACAD_STATUS_DETAIL` | `0`: no command or step text in the kit's status line. |

In remote mode `acad-dev.sh` passes `ACAD_STATUS`, `ACAD_STATUS_OWNER`, `ACAD_STATUS_DIR` and `ACAD_STATUS_DETAIL` to the Windows machine when they are set on the machine running it.

## Dialogs, alerts and the ribbon
Ask Claude, for example: "Load my LISP, run MYCMD, fill its dialog with Name=Test and Quantity=3, press OK and tell me what the
alert says." Claude writes the steps for the `ui` driver (`command`, `dialog`, `set`, `press`, `alert`, `expect`,
`ribbon`, `idle`...) and reads back what each one did. The driver never answers AutoCAD's security prompts ("unsigned executable"):
those stay with you. Loading a LISP file from a folder that is not in `TRUSTEDPATHS` shows such a prompt (`SECURELOAD`).

## When something blocks AutoCAD (blocker guard)
Anything that stalls (a command that never returns, a `wait` or `ui` timeout) ends with a report instead of a bare timeout:
`BLOCKED BY: ...` names the window in AutoCAD's way (title, class, its texts and buttons, whether it is modal), the command line
state and a screenshot, and the script exits 6. A `run` also notices a command that has been waiting at a prompt or dialog for
30 seconds (`STUCK`, exit 4). Ask Claude to run `acad-dev.sh blockers` (or `blockers.ps1`) first whenever AutoCAD seems stuck.
- AutoCAD's "Drawing Recovery" window (shown after AutoCAD restarts from a crash) is closed automatically; closing it saves
  nothing and deletes nothing.
- To let the kit dismiss other windows you know are harmless (say, an add-in's results window), copy `samples/blockers.sample.txt`
  to `blockers.txt` in the work folder and edit it. `ACAD_DEV_BLOCKER_ACTIONS=0` (set on the Windows machine) turns every automatic
  dismissal off; the guard then only reports.
- Security prompts, licence / sign-in / trial screens and "save changes?" prompts are never answered by the kit, whatever the
  file says. A Windows Update "restart to install" prompt is only reported.
- Every wait now has a limit, and ssh/scp give up on a dead connection. Details: `scripts/README.md`.

## What is AutoCAD doing? (status board)
Ask Claude to run `acad-dev.sh status` (or `status.ps1`) whenever anything looks stuck. It prints one line per tool that reports to the
shared status folder (`%ProgramData%\Gladmill\acad-status`, or `ACAD_STATUS_DIR`): the kit's own `run`, `ui` and `wait`, and, when installed, the
AcadStatus add-in inside AutoCAD (its pending prompt, the open dialog's title, texts and buttons) and Retrace. The overall state is the most
urgent one (blocked, needs a person, waiting for input, busy, error, running, idle), and the exit code says it too (0 idle, 3 running, 4 waiting,
5 busy, 6 blocked). With the add-in it is quick; without it (or when the status is blocked or busy) it also runs the read-only blocker scan, which takes
a few seconds (`--no-scan` skips it). The status folder is readable by every local user, so the kit writes only the start of the commands (verbs and
targets for `ui`, never typed values); `ACAD_STATUS_DETAIL=0` leaves even that out, and `ACAD_STATUS=0` stops the kit writing its own line. Details and
the file format: `acad-pilot/references/status-board.md`. The AcadStatus add-in is not part of this skill: it ships inside the Retrace release zip (gladmill/retrace-autocad releases, from Retrace 0.5.0). The board works without it.

## Optional: trial start-up window
`scripts/install-trial-watch.ps1` adds a logon task that closes AutoCAD's trial splash window for 5 minutes after
AutoCAD starts. It never signs in. Remove it with `schtasks /delete /tn AcadDevTrialWatch /f`.

## Troubleshooting
- `RPC_E_CALL_REJECTED` or a command that never returns: AutoCAD is usually waiting at a prompt or a dialog. Ask Claude to take a
  screenshot, then send Esc or cancel the dialog (it knows how). AutoCAD Electrical also rejects calls while it is only busy
  (long scripts, closing drawings); `run`/`query` retry those for up to `ACAD_DEV_COM_RETRY_SEC` seconds (default 30). Details: `acad-pilot/references/gotchas.md`.
- A command that opens a dialog or an alert: `run` waits for the command, which waits for the dialog, until it times out. Use `ui`
  instead (`command MYCMD`, then `dialog ...` / `alert` steps); see `acad-pilot/scripts/README.md`.
- `ui` says `FAIL ... no control 'X'`: add a `read` step to see the labels the dialog really has (the result also lists them).
- AutoCAD quits when the drawings are closed, or `Documents.Add()` fails with "Method not available in SDI mode": AutoCAD is in
  single-drawing mode (`SDI` is non-zero). Use the kit's `q-newdoc`, `q-closeall` and `q-discardall` queries (they replace the
  drawing instead) and don't send `CLOSE`. Details: `references/gotchas.md`, "SDI mode".
- AutoCAD "never becomes ready" after a fresh install: sign in and close the start-up/trial window by hand once.
- The wrong product starts: set `ACAD_DEV_PRODUCT=ACAD` or `ACAD_DEV_EXE`. For AutoCAD Electrical: `ACAD_DEV_PRODUCT=ACADE` and `ACAD_DEV_PROFILE='<<ACADE>>'`.
  In remote mode the start settings are read on the machine running Claude Code and passed to the Windows box (the box's own
  variables apply to any left unset). They only apply to a new AutoCAD: stop a running one first.
- Remote mode: scheduled task fails or screenshots are black: the Windows session is locked or disconnected. Unlock it.
- `ssh` asks for a password: set up key login; the scripts run with `BatchMode`.
- Scripts blocked: they are started with `-ExecutionPolicy Bypass`; if your organization blocks that, ask your IT.

## Safety
The skill sends commands to your AutoCAD and can close drawings without saving and end the AutoCAD process (only when asked, or
for test drawings). Use it on test drawings, keep backups, and read what Claude plans before approving.

## Support
support@gladmill.com

AutoCAD is a trademark of Autodesk, Inc. Claude is a trademark of Anthropic. Not affiliated with either.
