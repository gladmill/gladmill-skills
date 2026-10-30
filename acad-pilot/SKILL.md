---
name: acad-pilot
description: Drive AutoCAD from Claude Code. Use whenever the task is to start or stop AutoCAD, send it commands, read its command line, query a drawing over COM, take a screenshot, get past a stuck prompt or modal dialog, or check drawing state after a command. Works on the Windows machine itself (local) or over SSH (remote). Supports AutoCAD 2024, 2025 and 2026.
---

# acad-pilot: drive AutoCAD from Claude Code

You can start AutoCAD, type commands into it, read what it answered, inspect the drawing, take screenshots, and
get past stuck dialogs. All through PowerShell scripts in `scripts/` (relative to this skill's folder).
Supports AutoCAD 2024, 2025 and 2026.

Details: [references/gotchas.md](references/gotchas.md) (read before debugging anything odd),
[references/com-recipes.md](references/com-recipes.md) (query recipes).
Script table: [scripts/README.md](scripts/README.md).

## Pick the mode first

| | Local | Remote |
|---|---|---|
| Claude Code runs on | the Windows machine with AutoCAD, in the user's logged-in session | another machine (Mac/Linux/Windows); SSH to the Windows box |
| You call | `powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\<x>.ps1` | `bash <skill>/scripts/acad-dev.sh <command>` with `ACAD_DEV_SSH_HOST` set |
| How it reaches AutoCAD | directly (the scripts detect an interactive session) | one-shot interactive scheduled task: SSH lands in session 0, which has no desktop |

Decide: if `$env:SESSIONNAME` or `whoami` shows you are on the Windows box with a desktop, use local; if
`ACAD_DEV_SSH_HOST` is set, use remote. If neither, ask the user once. Work folder: `ACAD_DEV_HOME`
(default `%USERPROFILE%\acad-dev`); results land in `<home>\out\`.

Remote only, once: `bash scripts/acad-dev.sh install` copies the scripts to the box. Re-run after updating the skill.
Remote home and scripts folder paths must not contain spaces.

## Core loop

Every example below shows local (PowerShell, from the `scripts` folder) then remote (`acad-dev.sh`).

1. **Start and wait until ready**
   - `.\start-acad.ps1` | `acad-dev.sh start` (returns when AutoCAD answers over COM and is quiescent; no-op if running).
     If the user set `ACAD_DEV_TRUSTED` (or asks for `--trust`), start also adds those folders to `TRUSTEDPATHS`. Only the user
     picks trusted folders; never add one on your own to get past the unsigned-file dialog.
   - Already running? `.\wait-acad.ps1` | `acad-dev.sh wait`. Never sleep or watch window titles instead.
   - acad.exe is found via the registry (newest of 2024-2026) or `ACAD_DEV_EXE`. If a vertical product starts (Electrical,
     Mechanical), set `ACAD_DEV_PRODUCT=ACAD`. To start a vertical on purpose, pass its product and profile, as its desktop
     shortcut does: AutoCAD Electrical is `.\start-acad.ps1 -Product ACADE -Profile '<<ACADE>>'` | `acad-dev.sh start --product ACADE
     --profile '<<ACADE>>'` (or `ACAD_DEV_PRODUCT` and `ACAD_DEV_PROFILE`). In remote mode these and `ACAD_DEV_EXE` are read on the machine running `acad-dev.sh`.
   - First start on a trial/new install: a person must sign in once. `install-trial-watch.ps1` (optional) closes the trial
     splash window only; it never signs in or enters licences.
2. **Open a drawing**: run a query that does `$acad.Documents.Add()` in a call of its own
   (`queries\q-newdoc.ps1`). Commands sent in the same call go to the document that was active before the query.
   In SDI mode (`SDI` non-zero; `q-ents` prints it) AutoCAD keeps one drawing: the query replaces it with a blank one
   instead, and refuses if it has unsaved changes. See `references/gotchas.md`, "SDI mode".
3. **Send commands**
   - `.\run-in-session.ps1 -Cmds '_LINE\n0,0\n100,100\n\n' -WaitSec 2` | `acad-dev.sh run '_LINE\n0,0\n100,100\n\n' --wait 2`
   - `|` separates commands (each is a `SendCommand` call), `\n` = Enter. A command is not complete until all its
     prompts are answered: end with the Enters needed (a trailing `\n\n` ends LINE). Prefix with `_` for language-independent names.
   - In paths use forward slashes (`C:/new/plan.dwg`, AutoCAD accepts them): a backslash followed by `n` (`C:\new\plan.dwg`) is
     turned into Enter. A literal `|` cannot be sent (it separates commands).
   - The output is the tail of the command-line log (`Command: _LINE / Specify first point: ...`), plus a screenshot
     at `<home>\out\screen.png`. Read the log to see what AutoCAD actually did, including errors.
4. **Read state with a COM query file, never by typing AutoLISP.** Quotes break on the way and an unterminated
   string leaves AutoCAD waiting for input. Write a `.ps1` where `$acad` and `$doc` are in scope, print results:
   `.\run-in-session.ps1 -Query queries\q-ents.ps1` | `acad-dev.sh query queries/q-ents.ps1` (add commands with `run ... --query f.ps1`; the query runs first).
   Recipes: [references/com-recipes.md](references/com-recipes.md). Queries are read-only unless you mean otherwise.
5. **Screenshot**: `.\run-task.ps1 shot.ps1` then `<home>\out\shot.png` | `acad-dev.sh shot ./shot.png`. Look at it (Read tool)
   when the log does not explain the state. `run` also leaves `out\screen.png` (`acad-dev.sh screen`).
6. **Stuck? (COM hangs, `RPC_E_CALL_REJECTED`, `TIMEOUT`)** AutoCAD is at a prompt or a modal dialog. `run`/`query` already
   retry a call AutoCAD rejects as merely busy (up to `ACAD_DEV_COM_RETRY_SEC`, default 30 s), so a `RPC_E_CALL_REJECTED` from
   them after that wait usually means a dialog, unless the result says `com retry off`. Rejections from `wait`/`start` are
   normal while AutoCAD starts. Screenshot before pressing Esc: Esc cancels a long command that is only busy.
   1. Screenshot (no COM needed). 2. `run-task.ps1 esc.ps1` | `acad-dev.sh esc` (leaves a prompt; exit 3 / `foreground: False` means Esc may not have arrived: query or screenshot again).
   3. A dialog: `run-task.ps1 wincancel.ps1 -Title "<exact title>"` | `acad-dev.sh cancel "<title>"` (lists visible windows too).
   WPF dialogs ignore IDCANCEL: `acad-dev.sh cancel "<title>" --close` (WM_CLOSE). Before attaching, `run`/`query` close AutoCAD's
   Drawing Recovery windows (`clear-blockers.ps1`) and retry a failed attach; if it still fails, the error says what it found (a
   Windows Update "restart to install" prompt can't be dismissed from here: dismiss it by hand, or run `harden-automation-vm.ps1`
   once on a VM you own). 4. Still stuck: `stop-acad.ps1 -Force`
   | `acad-dev.sh stop --force` (kills AutoCAD; unsaved work is lost, so ask the user first if they have real drawings open), then start again. Never leave a command half-answered.
7. **Stop**: `.\stop-acad.ps1` | `acad-dev.sh stop`. It quits only if no drawing has unsaved changes and prints
   `REFUSED: unsaved changes in: ...` otherwise. For test drawings you created this session, and only then, use
   `-DiscardChanges` | `stop --discard`. If a drawing you didn't create has changes, ask the user before discarding anything.
8. **Close drawings**: `queries\q-closeall.ps1` (refuses on unsaved changes, like stop). Test drawings you created:
   `queries\q-discardall.ps1` closes them without saving. In SDI mode both replace the one drawing with a blank
   one instead (closing it would quit AutoCAD), so a drawing stays open.

## Ribbon, dialogs and alerts: the `ui` driver

`run` types commands and waits for each one, so a command that opens a dialog or alert stalls it until it times out. For anything with
UI, use `ui`: one step per line, run in order, each waiting (up to `--step-timeout`, default 20 s) for what it needs and
printing `ok`/`FAIL` with what it saw. `.\ui.ps1 -Steps 'step','step'` (or `-File steps.txt`) | `acad-dev.sh ui 'step' 'step' ...`
(or `--file steps.txt`). Steps:

| Step | Does |
|---|---|
| `command <text>` | starts a command at the Command: prompt and goes on at once (a dialog it opens doesn't block); refused while another command or prompt is active |
| `type <text>` | types on the command line as is: answers the prompt that waits (`type 0,0`, `type \n` for Enter) |
| `ribbon [<tab>/][<panel>/]<button>` | clicks a ribbon button by label or id (`Home/Line`, `Insert/Create Block`; a button in a panel slide-out: `Home/Draw/Donut`) |
| `dialog <title>` | waits for a dialog (`*` wildcards) and makes it the target; `alert [<title>]` does the same for a message box and prints its text |
| `read` | lists the target's controls with their labels and values: do this first on an unfamiliar dialog |
| `set <label>=<value>` | edit box, drop-down, list (`a;b` for several), check box (`on`/`off`), radio button (`=on`) |
| `press <button>` | presses a button (`OK`, `Cancel`, `Check...` or `Check`) with a window message |
| `click <label>` | a real mouse click on a button or control of the target: use it when something watches real input (a test recorder such as Hotpaths or Retrace sees which button closed the dialog) |
| `expect <regex>` | fails unless the target's title, texts or values match |
| `closed [<title>]`, `idle [sec]` | waits until the dialog has closed / until AutoCAD is free (no command, prompt or modal dialog) |
| `dialogs`, `front [<title>]`, `shot [name]`, `keys <sendkeys>`, `click <x>,<y>`, `move <x>,<y>`, `sleep <ms>`, `timeout <sec>` | list dialogs (in front or not, off screen), bring one forward (moves it on screen), screenshot, real keys, click or mouse rest (last resort) |

A LISP command with a DCL dialog, end to end (the sample in `samples/kit-dialog.lsp`; load it first, `(load "C:/path/kit-dialog.lsp")`):
```
acad-dev.sh ui 'command KITDIALOG' 'dialog Kit Sample Dialog' 'read' 'set Name=Bravo' 'set Quantity=5' 'set Include notes=on' \
  'set Large=on' 'set Layer=Doors' 'set Parts=Bolt M8;Washer 8' 'press OK' 'alert' 'expect Saved Bravo' 'press OK' 'idle'
```
- Labels are matched as a person reads them: `Name` matches `&Name:`, `Check` matches `Check...`, and `Save names` matches `Save names (1)` when no other control starts that way. If a step says `no control`, it
  lists what is there; `read` shows everything.
- Dialogs are filled with window messages (Win32, MFC, DCL) or UI Automation (WPF, WinForms): they don't need to be in front,
  and a DCL `action_tile` runs as if a person had typed (an edit box's action when it "loses the focus"). Only `ribbon`, `keys`
  and `click` use the real mouse and keyboard, bringing AutoCAD forward when another window covers it.
- A run can stop with a dialog open; the next `ui` run picks it up (`dialog <title>` and on).
- A dialog with another one open on top (an alert its own button opened) is disabled: answer the top one first (`alert`, `press OK`), then go back with `dialog <title>`.
- On `FAIL` the result lists AutoCAD's open dialogs and leaves `out\ui-fail.png` (`acad-dev.sh fetch out/ui-fail.png ./f.png`).
- Recording a test with `ui`: close dialogs with `click OK` (a recorder doesn't see `press`), and leave the mouse to `ui`: it parks it on the command line, not over the drawing, where a jumping cursor would drag a prompt's rubber band.
- Never answer security prompts ("Security - Unsigned Executable File"): `ui` refuses to; a person decides. A LISP or dll
  outside `TRUSTEDPATHS` shows one when loaded (`SECURELOAD`).
- A message box that isn't expected blocks everything after it: when a step fails waiting, check `dialogs` before anything else.

## Verify a drawing change end to end

Done means observed in AutoCAD, not "the command was sent". Loop:
1. Fresh drawing (`q-newdoc`). 2. Run the commands through `run` with all prompt answers, `-WaitSec` long enough.
3. Read the log tail for errors. 4. Assert on state with a COM query (entity counts/types, layer, variable values).
5. Screenshot for visible changes and look at it. 6. Close the test drawings (`q-discardall`, since they're yours and unsaved).
   Report what you saw, with the numbers.
If a step hangs, go to "Stuck?" above before anything else, and fix the cause (a command waiting for input) rather than adding sleeps.

## Rules

- Prefer scripts over typing; keep every `run` short and every prompt answered. Commands that open dialogs or alerts go through `ui`.
- Test drawings only: close them without saving; ask before touching a drawing the user is working in.
- Do not change security settings, registry or licensing without the user's consent. Never automate a sign-in.
- Report what you ran and what AutoCAD answered; if COM fails after one restart, stop and tell the user.
