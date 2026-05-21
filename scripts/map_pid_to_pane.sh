#!/usr/bin/env bash
# scripts/map_pid_to_pane.sh
# Resolve Claude PIDs to tmux panes by walking the PPID chain.
#
# Usage:
#   echo -e "PID1\nPID2\n..." | map_pid_to_pane.sh <panes_file> <ps_file>
#
# panes_file lines: `<pane_pid> <session>:<window_id>.<pane_id> <cwd>`
# ps_file    lines: `<pid> <ppid>`
#
# Output: tab-separated `<pid>\t<window_id>\t<pane_id>` per resolved PID.

set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <panes_file> <ps_file>" >&2; exit 2; }
PANES="$1"; PSTREE="$2"

# Build single awk pass over three concatenated streams separated by `--`.
{
  cat "$PANES"
  printf -- '--\n'
  cat "$PSTREE"
  printf -- '--\n'
  cat   # the pids from stdin
} | awk '
  BEGIN { phase = 0; max_hops = 64 }
  $1 == "--" { phase++; next }

  # phase 0: pane lines
  phase == 0 {
    # field 1 = pane_pid, field 2 = session:window_id.pane_id
    pane_pid = $1
    target   = $2
    # split target on `:` and `.`
    n = split(target, parts, /[:.]/)
    if (n >= 3) {
      window_id_of_pane[pane_pid] = parts[2]
      pane_id_of_pane[pane_pid]   = parts[3]
      full_target_of_pane[pane_pid] = target
    }
    next
  }

  # phase 1: ps lines (pid ppid)
  phase == 1 {
    ppid_of[$1+0] = $2+0
    next
  }

  # phase 2: target pids
  phase == 2 {
    cur = $1+0
    for (i = 0; i < max_hops; i++) {
      if (cur in window_id_of_pane) {
        printf "%d\t%s\t%s\t%s\n", $1, window_id_of_pane[cur], pane_id_of_pane[cur], full_target_of_pane[cur]
        next
      }
      if (!(cur in ppid_of)) break
      next_pid = ppid_of[cur]
      if (next_pid <= 1 || next_pid == cur) break
      cur = next_pid
    }
  }
'
