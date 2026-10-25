# AutoCAD Pilot for Claude Code

A skill that lets Claude Code drive AutoCAD for you: start AutoCAD, type commands into it, read the command line,
query the drawing, take screenshots, and get past stuck prompts and dialogs, all without you copy-pasting between
Claude and AutoCAD.

What is in the box:
- A Claude Code skill (`acad-pilot`) with the workflow, the traps to avoid, and COM query recipes.
- PowerShell scripts (and an SSH wrapper) that do the driving: start, stop, ready, send commands, COM queries,
  screenshots, Esc, and window cancel.
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
| `ACAD_DEV_EXE` | Full path to `acad.exe` if the registry lookup finds the wrong one. |
| `ACAD_DEV_PRODUCT` | `/product` switch (e.g. `ACAD`) if a vertical product starts instead of plain AutoCAD. |
| `ACAD_DEV_TRUSTED` | Folders to add to AutoCAD's trusted locations (`TRUSTEDPATHS`) at start, `;`-separated; end one with `\...` to include subfolders. Same as `acad-dev.sh start --trust "..."`. Plugins you load from there skip the "unsigned executable" dialog. You choose these folders: anything that can write to them gets code loaded into AutoCAD. |

## Optional: trial start-up window
`scripts/install-trial-watch.ps1` adds a logon task that closes AutoCAD's trial splash window for 5 minutes after
AutoCAD starts. It never signs in. Remove it with `schtasks /delete /tn AcadDevTrialWatch /f`.

## Troubleshooting
- `RPC_E_CALL_REJECTED` or a command that never returns: AutoCAD is waiting at a prompt or a dialog. Ask Claude to take a screenshot,
  then send Esc or cancel the dialog (it knows how). Details: `acad-pilot/references/gotchas.md`.
- AutoCAD "never becomes ready" after a fresh install: sign in and close the start-up/trial window by hand once.
- The wrong product starts: set `ACAD_DEV_PRODUCT=ACAD` or `ACAD_DEV_EXE`.
- Remote mode: scheduled task fails or screenshots are black: the Windows session is locked or disconnected. Unlock it.
- `ssh` asks for a password: set up key login; the scripts run with `BatchMode`.
- Scripts blocked: they are started with `-ExecutionPolicy Bypass`; if your organization blocks that, ask your IT.

## Safety
The skill sends commands to your AutoCAD and can close drawings without saving and end the AutoCAD process (only when asked, or
for test drawings). Use it on test drawings, keep backups, and read what Claude plans before approving.

## Support
support@gladmill.com

AutoCAD is a trademark of Autodesk, Inc. Claude is a trademark of Anthropic. Not affiliated with either.
