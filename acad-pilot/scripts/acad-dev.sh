#!/usr/bin/env bash
# Remote mode helper: drives AutoCAD on a Windows machine over SSH from the machine Claude Code runs on (Mac/Linux/WSL/Git Bash).
# Needs: ssh + scp, key-based login (BatchMode), iconv + base64, and `powershell` (Windows PowerShell 5.1) on the box.
# The remote shell can be cmd.exe (the Windows OpenSSH default) or PowerShell: every remote call is a -EncodedCommand.
#   ACAD_DEV_SSH_HOST   required: the ssh host (an alias from ~/.ssh/config, or user@host)
#   ACAD_DEV_HOME       optional: work folder ON THE WINDOWS BOX (default %USERPROFILE%\acad-dev). Set it there as a user env var too.
# Usage: acad-dev.sh <command> [args]
#   install                     copy the scripts to the box (run once, and after updating the kit)
#   start [timeoutSec] [--trust "C:\a\...;C:\b"]   start AutoCAD in the interactive session and wait until it is ready;
#                               --trust (or ACAD_DEV_TRUSTED) adds those folders to TRUSTEDPATHS (saved in the AutoCAD profile)
#   wait [timeoutSec]           wait until AutoCAD answers over COM and is quiescent
#   stop [--discard|--force]    quit AutoCAD (refuses if a drawing has unsaved changes; --discard throws them away, --force kills a hung AutoCAD)
#   run "<cmds>" [--query f.ps1] [--wait n] [--timeout s]   send commands ('|' separates, \n = Enter), optional COM query; prints the log tail
#   query <f.ps1>               run a COM query only (no commands)
#   shot [local.png]            screenshot of the desktop, copied back (default ./acad-shot.png)
#   screen [local.png]          the screenshot taken by the last `run` (out/screen.png)
#   esc                         press Esc in AutoCAD (foreground + SendKeys; gets out of a prompt). Exit 3: AutoCAD could not
#                               be brought to the front and Esc was only posted; check with query or shot
#   cancel "<window title>" [--close]   post IDCANCEL (or WM_CLOSE) to a window by exact title; prints visible windows
#   fetch <remote path rel. to home> [local]   copy a file back from the box
set -uo pipefail
HOST="${ACAD_DEV_SSH_HOST:-}"
[ -n "$HOST" ] || { echo "set ACAD_DEV_SSH_HOST (ssh host of the Windows machine)" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"
SSHO=(-o BatchMode=yes -o ConnectTimeout=10)
# Every remote call is `powershell -EncodedCommand <base64 of UTF-16LE>`, so it works whatever the SSH default shell is
# (Windows OpenSSH defaults to cmd.exe; PowerShell and others work too) and needs no quoting.
rps() {
  local enc
  enc="$(printf '%s' "\$ProgressPreference='SilentlyContinue'; $1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n')"
  ssh "${SSHO[@]}" "$HOST" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -InputFormat None -OutputFormat Text -EncodedCommand $enc"
}
# the home folder on the box, with forward slashes (scp accepts C:/...)
winhome() {
  rps 'if ($env:ACAD_DEV_HOME) { $env:ACAD_DEV_HOME } else { Join-Path $env:USERPROFILE "acad-dev" }' | tr -d '\r' | tr '\\' '/'
}
H="$(winhome)" || { echo "cannot reach $HOST over ssh" >&2; exit 2; }
[ -n "$H" ] || { echo "cannot reach $HOST over ssh" >&2; exit 2; }
HW="${H//\//\\}"
# psa <script> [args]: run an installed script; its exit code is passed through
psa() { local s="$1"; shift; rps "& '$HW\\scripts\\$s' $*; if (\$LASTEXITCODE) { exit \$LASTEXITCODE } elseif (-not \$?) { exit 1 }"; }
# fresh <remote file rel. to home>: delete the previous output before a task, so a stale file is never mistaken for a new one
fresh() { rps "Remove-Item '$HW\\$1' -Force -ErrorAction SilentlyContinue"; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  install)
    rps "New-Item -ItemType Directory -Force '$HW\\scripts\\queries','$HW\\out' | Out-Null; exit 0" >/dev/null
    scp -q "$here"/*.ps1 "$here"/*.vbs "$HOST:$H/scripts/" && scp -q "$here"/queries/*.ps1 "$HOST:$H/scripts/queries/" \
      && echo "installed to $HW\\scripts" || { echo "scp failed" >&2; exit 2; } ;;
  start)
    tmo=240; trust="${ACAD_DEV_TRUSTED:-}"
    while [ $# -gt 0 ]; do case "$1" in --trust) [ $# -ge 2 ] || { echo "--trust needs a value" >&2; exit 2; }; trust="$2"; shift ;; *) tmo="$1" ;; esac; shift; done
    [[ "$trust" == *"'"* ]] && { echo "--trust: no single quotes in paths" >&2; exit 2; }
    if [ -n "$trust" ]; then psa start-acad.ps1 -TimeoutSec "$tmo" -Trust "'$trust'"; else psa start-acad.ps1 -TimeoutSec "$tmo"; fi ;;
  wait) psa wait-acad.ps1 -TimeoutSec "${1:-240}" ;;
  stop) case "${1:-}" in --force) psa stop-acad.ps1 -Force ;; --discard) psa stop-acad.ps1 -DiscardChanges ;; *) psa stop-acad.ps1 ;; esac ;;
  run|query)
    cmds=""; q=""; wait=3; tmo=
    if [ "$cmd" = "run" ]; then cmds="${1:-}"; shift; fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --query) q="$2"; shift ;;
        --wait) wait="$2"; shift ;;
        --timeout) tmo="$2"; shift ;;
        *) [ "$cmd" = "query" ] && q="$1" ;;
      esac; shift
    done
    tmp="$(mktemp)"; printf '%s' "$cmds" > "$tmp"
    scp -q "$tmp" "$HOST:$H/cmds.txt" || { rm -f "$tmp"; echo "scp failed" >&2; exit 2; }; rm -f "$tmp"
    extra=""
    if [ -n "$q" ]; then scp -q "$q" "$HOST:$H/query.ps1" || { echo "scp failed" >&2; exit 2; }; extra="-HasQuery"; fi
    [ -n "$tmo" ] && extra="$extra -TimeoutSec $tmo"
    psa run-in-session.ps1 -Staged -WaitSec "$wait" $extra ;;   # exits 1 with a TIMEOUT line if the worker never finished
  shot)
    out="${1:-./acad-shot.png}"; fresh out/shot.png; rm -f "$out"
    psa run-task.ps1 shot.ps1
    scp -q "$HOST:$H/out/shot.png" "$out" 2>/dev/null && echo "saved $out" || { echo "no new screenshot was produced (task failed or timed out)" >&2; exit 1; } ;;
  screen)
    scp -q "$HOST:$H/out/screen.png" "${1:-./acad-screen.png}" && echo "saved ${1:-./acad-screen.png}" ;;
  esc)
    fresh out/esc.txt; psa run-task.ps1 esc.ps1
    r="$(rps "if (Test-Path '$HW\\out\\esc.txt') { Get-Content '$HW\\out\\esc.txt' } else { exit 1 }")" || { echo "esc produced no result (task failed or timed out)" >&2; exit 1; }
    echo "$r"; case "$r" in *"foreground: True"*) ;; *"foreground: False"*) exit 3 ;; *) exit 1 ;; esac ;;   # 3 = Esc only posted; check with query/shot
  cancel)
    title="${1:?window title}"; shift
    tmp="$(mktemp)"; printf '%s' "$title" > "$tmp"; scp -q "$tmp" "$HOST:$H/title.txt"; rm -f "$tmp"
    if [ "${1:-}" = "--close" ]; then rps "Set-Content '$HW\\closeflag.txt' 1" >/dev/null; fi
    fresh out/result.txt; fresh out/done.txt; psa run-task.ps1 wincancel.ps1
    rps "if ((Test-Path '$HW\\out\\done.txt') -and (Test-Path '$HW\\out\\result.txt')) { Get-Content '$HW\\out\\result.txt' } else { exit 1 }" || { echo "cancel produced no fresh result (task failed or timed out)" >&2; exit 1; } ;;
  fetch) scp -q "$HOST:$H/${1:?remote path}" "${2:-.}" ;;
  *) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
