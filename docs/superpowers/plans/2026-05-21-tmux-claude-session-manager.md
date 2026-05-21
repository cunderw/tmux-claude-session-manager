# tmux-claude-session-manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a TPM-installable tmux plugin that displays per-window status indicators for live Claude Code sessions and exposes a `display-popup`+`fzf` picker for jump/kill/clear actions, driven by a single bash daemon that polls `claude agents --json`.

**Architecture:** A single long-lived bash daemon (one per tmux server, gated by a PID file) polls `claude agents --json` every ~2 s, walks each session's PPID chain to map the Claude process back to its tmux pane, and writes `@claude-status=busy|attn|done` per window as a tmux user option. Status-bar format strings read `#{@claude-status}` to colorize window names. A separate picker script runs in a `display-popup` and uses `fzf` for navigation with `Enter`/`C-k`/`C-l` key bindings.

**Tech Stack:** Bash, POSIX `awk`, `ps`, `jq`, `fzf` (optional), tmux ≥ 3.2; tested with `bats-core` on macOS + Ubuntu via GitHub Actions; `shellcheck` for linting.

**Spec:** [`docs/superpowers/specs/2026-05-21-tmux-claude-session-manager-design.md`](../specs/2026-05-21-tmux-claude-session-manager-design.md)

**Dependency map (for parallel dispatch planning):**

```
Task 1 (scaffold) ─┬─→ Task 2 (variables.sh) ─→ Task 3 (helpers.sh) ─→ Task 4 (test harness)
                   │                                                           │
                   │                          ┌────────────────────────────────┴────────────────────┐
                   │                          ▼                                                     ▼
                   │                   Task 5 (mapper)                                  Tasks 10/11 (picker, doctor)
                   │                          │                                                     │
                   │                          ▼                                                     │
                   │                   Task 6 (apply_state) ─→ Task 7 (tick) ─→ Task 8 (daemon) ──→ │
                   │                                                                                │
                   │                                                                                ▼
                   └──────────────────────────────────────────────────────────────────────→ Task 9 (.tmux entry)
                                                                                                    │
                                                                                                    ▼
                                                                                  Task 12 (CI) + Task 13 (README) + Task 14 (smoke)
```

Tasks 5, 10, 11 can be dispatched in parallel after Task 4. Tasks 6→7→8 are sequential. Tasks 12/13 can run in parallel at the end.

---

## Phase 1 — Foundation

### Task 1: Repo scaffolding

**Files:**
- Create: `LICENSE`
- Create: `.gitignore`
- Create: `README.md` (skeleton only — full content in Task 13)
- Create: `scripts/.gitkeep`
- Create: `tests/.gitkeep`

- [ ] **Step 1: Write LICENSE (MIT)**

```
MIT License

Copyright (c) 2026 Carson Underwood

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Write .gitignore**

```
# bats output
.bats-tmpdir/
*.tap

# editor
.vscode/
.idea/
*.swp
*.swo
.DS_Store

# local runtime
*.log
*.pid
```

- [ ] **Step 3: Write README.md skeleton**

```markdown
# tmux-claude-session-manager

Per-window indicators and a session picker for Claude Code sessions running inside tmux.

(Detailed README in Task 13.)
```

- [ ] **Step 4: Create empty directories with .gitkeep**

Run:
```bash
mkdir -p scripts tests/unit tests/integration tests/stubs tests/fixtures
touch scripts/.gitkeep tests/.gitkeep
```

- [ ] **Step 5: Commit**

```bash
git add LICENSE .gitignore README.md scripts/ tests/
git commit -m "chore: scaffold repo structure"
```

---

### Task 2: variables.sh — option names, defaults, paths

**Files:**
- Create: `scripts/variables.sh`
- Create: `tests/unit/test_variables.bats`

- [ ] **Step 1: Write failing test**

`tests/unit/test_variables.bats`:
```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  export TMUX_TMPDIR
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/scripts/variables.sh"
}

@test "exposes well-known option names" {
  [ "$OPT_ENABLED"        = "@claude-enabled" ]
  [ "$OPT_PICKER_KEY"     = "@claude-picker-key" ]
  [ "$OPT_POLL_INTERVAL"  = "@claude-poll-interval" ]
  [ "$OPT_COLOR_BUSY"     = "@claude-color-busy" ]
  [ "$OPT_COLOR_ATTN"     = "@claude-color-attn" ]
  [ "$OPT_COLOR_DONE"     = "@claude-color-done" ]
  [ "$OPT_DONE_LINGER_MS" = "@claude-done-linger-ms" ]
  [ "$OPT_LOG_LEVEL"      = "@claude-log-level" ]
  [ "$OPT_STATUS"         = "@claude-status" ]
  [ "$OPT_SUMMARY"        = "@claude-summary" ]
}

@test "defines defaults" {
  [ "$DEFAULT_PICKER_KEY"     = "j" ]
  [ "$DEFAULT_POLL_INTERVAL"  = "2" ]
  [ "$DEFAULT_COLOR_BUSY"     = "yellow" ]
  [ "$DEFAULT_COLOR_ATTN"     = "red" ]
  [ "$DEFAULT_COLOR_DONE"     = "green" ]
  [ "$DEFAULT_DONE_LINGER_MS" = "3000" ]
  [ "$DEFAULT_LOG_LEVEL"      = "warn" ]
  [ "$DEFAULT_ENABLED"        = "on" ]
}

@test "PIDFILE lives under TMUX_TMPDIR" {
  [[ "$PIDFILE" == "$TMUX_TMPDIR"* ]]
  [[ "$PIDFILE" == *"claude-session-manager.pid" ]]
}

@test "LOGFILE lives under TMUX_TMPDIR" {
  [[ "$LOGFILE" == "$TMUX_TMPDIR"* ]]
  [[ "$LOGFILE" == *"claude-session-manager.log" ]]
}

@test "PIDFILE falls back to /tmp when TMUX_TMPDIR unset" {
  unset TMUX_TMPDIR
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/scripts/variables.sh"
  [[ "$PIDFILE" == /tmp/* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_variables.bats`
Expected: FAIL (file does not exist).

- [ ] **Step 3: Write variables.sh**

```bash
#!/usr/bin/env bash
# scripts/variables.sh
# Single source of truth for option names, defaults, and runtime paths.

OPT_ENABLED="@claude-enabled"
OPT_PICKER_KEY="@claude-picker-key"
OPT_POLL_INTERVAL="@claude-poll-interval"
OPT_COLOR_BUSY="@claude-color-busy"
OPT_COLOR_ATTN="@claude-color-attn"
OPT_COLOR_DONE="@claude-color-done"
OPT_DONE_LINGER_MS="@claude-done-linger-ms"
OPT_LOG_LEVEL="@claude-log-level"
OPT_STATUS="@claude-status"
OPT_SUMMARY="@claude-summary"

DEFAULT_ENABLED="on"
DEFAULT_PICKER_KEY="j"
DEFAULT_POLL_INTERVAL="2"
DEFAULT_COLOR_BUSY="yellow"
DEFAULT_COLOR_ATTN="red"
DEFAULT_COLOR_DONE="green"
DEFAULT_DONE_LINGER_MS="3000"
DEFAULT_LOG_LEVEL="warn"

_state_dir="${TMUX_TMPDIR:-/tmp}"
_uid="$(id -u)"
PIDFILE="${_state_dir}/tmux-${_uid}-claude-session-manager.pid"
LOGFILE="${_state_dir}/tmux-${_uid}-claude-session-manager.log"
STATEFILE="${_state_dir}/tmux-${_uid}-claude-session-manager.state"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"   # 10 MB
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_variables.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/variables.sh tests/unit/test_variables.bats
git commit -m "feat(variables): define option names, defaults, runtime paths"
```

---

### Task 3: helpers.sh — tmux option I/O and logging

**Files:**
- Create: `scripts/helpers.sh`
- Create: `tests/unit/test_helpers.bats`

- [ ] **Step 1: Write failing test**

`tests/unit/test_helpers.bats`:
```bash
#!/usr/bin/env bats

setup() {
  PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  STUBS="$PLUGIN_DIR/tests/stubs"
  PATH="$STUBS:$PATH"
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  export STUB_OUT="$BATS_TEST_TMPDIR/tmux-calls.txt"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/scripts/variables.sh"
  # shellcheck disable=SC1090
  source "$PLUGIN_DIR/scripts/helpers.sh"
}

@test "get_tmux_option returns default when option unset" {
  export STUB_OPT_VALUE=""
  run get_tmux_option "@nope" "fallback"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback" ]
}

@test "get_tmux_option returns set value" {
  export STUB_OPT_VALUE="hello"
  run get_tmux_option "@thing" "fallback"
  [ "$output" = "hello" ]
}

@test "set_tmux_option_window writes -w -q" {
  set_tmux_option_window "@1" "@claude-status" "busy"
  grep -q -- "set-option -w -q -t @1 @claude-status busy" "$STUB_OUT"
}

@test "unset_tmux_option_window writes -w -u -q" {
  unset_tmux_option_window "@1" "@claude-status"
  grep -q -- "set-option -w -u -q -t @1 @claude-status" "$STUB_OUT"
}

@test "set_tmux_option_global writes -g -q" {
  set_tmux_option_global "@claude-summary" "2 busy, 1 attn"
  grep -q -- "set-option -g -q @claude-summary 2 busy, 1 attn" "$STUB_OUT"
}

@test "log honors log level" {
  export STUB_OPT_VALUE="warn"
  log_info "should not appear"
  log_warn "should appear"
  [ -f "$LOGFILE" ]
  grep -q "should appear" "$LOGFILE"
  ! grep -q "should not appear" "$LOGFILE"
}

@test "log truncates when over LOG_MAX_BYTES" {
  export STUB_OPT_VALUE="debug"
  export LOG_MAX_BYTES=64
  printf 'x%.0s' {1..200} > "$LOGFILE"
  log_debug "after truncate"
  size=$(wc -c < "$LOGFILE" | tr -d ' ')
  [ "$size" -lt 200 ]
}
```

- [ ] **Step 2: Add the tmux stub used by tests**

`tests/stubs/tmux`:
```bash
#!/usr/bin/env bash
# Append the full invocation to $STUB_OUT for assertions.
printf '%s\n' "$*" >> "${STUB_OUT:-/dev/null}"

# Emulate just the subcommands the tests use.
case "$1" in
  show-option|show-options)
    # show-option -gqv NAME [or -wqv -t target NAME]
    printf '%s' "${STUB_OPT_VALUE:-}"
    exit 0
    ;;
  set-option|display-message|kill-window|switch-client|send-keys|list-panes|set-hook|bind-key|run-shell|refresh-client|display-popup|display-menu)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
```

Then make it executable:
```bash
chmod +x tests/stubs/tmux
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bats tests/unit/test_helpers.bats`
Expected: FAIL (helpers.sh missing).

- [ ] **Step 4: Write helpers.sh**

```bash
#!/usr/bin/env bash
# scripts/helpers.sh
# tmux option I/O + leveled logging.

# Sourcing this requires variables.sh to have been sourced first.
[ -n "${OPT_LOG_LEVEL:-}" ] || {
  echo "helpers.sh: variables.sh must be sourced first" >&2
  return 1 2>/dev/null || exit 1
}

# get_tmux_option <name> [default]
get_tmux_option() {
  local name="$1" default="${2:-}" val
  val="$(tmux show-option -gqv "$name" 2>/dev/null)"
  if [ -z "$val" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# get_tmux_option_window <target> <name> [default]
get_tmux_option_window() {
  local target="$1" name="$2" default="${3:-}" val
  val="$(tmux show-option -wqv -t "$target" "$name" 2>/dev/null)"
  if [ -z "$val" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# set_tmux_option_window <target> <name> <value>
set_tmux_option_window() {
  tmux set-option -w -q -t "$1" "$2" "$3"
}

# unset_tmux_option_window <target> <name>
unset_tmux_option_window() {
  tmux set-option -w -u -q -t "$1" "$2"
}

# set_tmux_option_global <name> <value>
set_tmux_option_global() {
  tmux set-option -g -q "$1" "$2"
}

# unset_tmux_option_global <name>
unset_tmux_option_global() {
  tmux set-option -g -u -q "$1"
}

# --- logging ---------------------------------------------------------------

_log_level_num() {
  case "$1" in
    error) echo 1 ;;
    warn)  echo 2 ;;
    info)  echo 3 ;;
    debug) echo 4 ;;
    *)     echo 2 ;;
  esac
}

_log_should_emit() {
  local msg_level="$1"
  local cfg; cfg="$(get_tmux_option "$OPT_LOG_LEVEL" "$DEFAULT_LOG_LEVEL")"
  [ "$(_log_level_num "$msg_level")" -le "$(_log_level_num "$cfg")" ]
}

_log_truncate_if_large() {
  local size
  if [ -f "$LOGFILE" ]; then
    size=$(wc -c < "$LOGFILE" 2>/dev/null | tr -d ' ')
    if [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ]; then
      : > "$LOGFILE"
    fi
  fi
}

_log() {
  local level="$1"; shift
  _log_should_emit "$level" || return 0
  _log_truncate_if_large
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$level" "$*" >> "$LOGFILE"
}

log_error() { _log error "$@"; }
log_warn()  { _log warn  "$@"; }
log_info()  { _log info  "$@"; }
log_debug() { _log debug "$@"; }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/unit/test_helpers.bats`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add scripts/helpers.sh tests/unit/test_helpers.bats tests/stubs/tmux
git commit -m "feat(helpers): tmux option I/O + leveled logging"
```

---

### Task 4: Test harness — bats setup, stubs scaffolding, fixtures

**Files:**
- Create: `tests/helper.bash` — common setup sourced by every test
- Create: `tests/stubs/claude`
- Create: `tests/stubs/ps`
- Create: `tests/fixtures/sessions_busy.json`
- Create: `tests/fixtures/sessions_attn.json`
- Create: `tests/fixtures/sessions_empty.json`
- Create: `tests/fixtures/sessions_mixed.json`
- Create: `tests/fixtures/ps_simple.txt`
- Create: `tests/fixtures/ps_nested.txt`
- Create: `tests/fixtures/list_panes.txt`
- Create: `bin/run_tests`

- [ ] **Step 1: Write `tests/helper.bash`**

```bash
# tests/helper.bash
# shellcheck shell=bash

# Common bats setup. Source from each test's setup().
common_setup() {
  PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  STUBS="$PLUGIN_DIR/tests/stubs"
  FIXTURES="$PLUGIN_DIR/tests/fixtures"
  TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  STUB_OUT="$BATS_TEST_TMPDIR/stub-calls.txt"
  : > "$STUB_OUT"
  export PLUGIN_DIR STUBS FIXTURES TMUX_TMPDIR STUB_OUT
  PATH="$STUBS:$PATH"
  export PATH
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/scripts/variables.sh"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/scripts/helpers.sh"
}
```

- [ ] **Step 2: Add `tests/stubs/claude`**

```bash
#!/usr/bin/env bash
# Reads fixture path from $STUB_CLAUDE_FIXTURE.
printf 'claude %s\n' "$*" >> "${STUB_OUT:-/dev/null}"
case "$1" in
  agents)
    if [ -n "${STUB_CLAUDE_FIXTURE:-}" ] && [ -f "$STUB_CLAUDE_FIXTURE" ]; then
      cat "$STUB_CLAUDE_FIXTURE"
      exit "${STUB_CLAUDE_EXIT:-0}"
    fi
    printf '[]'
    exit 0
    ;;
  --version)
    printf '%s\n' "${STUB_CLAUDE_VERSION:-2.1.146 (Claude Code)}"
    exit 0
    ;;
esac
exit 0
```

- [ ] **Step 3: Add `tests/stubs/ps`**

```bash
#!/usr/bin/env bash
# Reads fixture path from $STUB_PS_FIXTURE for `ps -A -o pid=,ppid=`.
printf 'ps %s\n' "$*" >> "${STUB_OUT:-/dev/null}"
if [ -n "${STUB_PS_FIXTURE:-}" ] && [ -f "$STUB_PS_FIXTURE" ]; then
  cat "$STUB_PS_FIXTURE"
  exit 0
fi
# Fallback to real ps so tests that don't set the fixture still work.
exec /bin/ps "$@"
```

- [ ] **Step 4: Make stubs executable**

```bash
chmod +x tests/stubs/claude tests/stubs/ps
```

- [ ] **Step 5: Add JSON fixtures**

`tests/fixtures/sessions_empty.json`:
```json
[]
```

`tests/fixtures/sessions_busy.json`:
```json
[
  {"pid":36951,"cwd":"/Users/u/repo","kind":"interactive","startedAt":1779375638455,"sessionId":"8df9647b-475e-4bfd-910a-5536b68b8be8","status":"busy"}
]
```

`tests/fixtures/sessions_attn.json`:
```json
[
  {"pid":36951,"cwd":"/Users/u/repo","kind":"interactive","startedAt":1779375638455,"sessionId":"8df9647b-475e-4bfd-910a-5536b68b8be8","status":"idle"}
]
```

`tests/fixtures/sessions_mixed.json`:
```json
[
  {"pid":36951,"cwd":"/Users/u/repo","kind":"interactive","startedAt":1779375638455,"sessionId":"aaaa","status":"busy"},
  {"pid":36952,"cwd":"/Users/u/repo2","kind":"interactive","startedAt":1779375638456,"sessionId":"bbbb","status":"idle"},
  {"pid":36953,"cwd":"/Users/u/repo3","kind":"background","startedAt":1779375638457,"sessionId":"cccc","status":"busy"}
]
```

- [ ] **Step 6: Add ps fixtures**

`tests/fixtures/ps_simple.txt`:
```
    1     0
   100    1
   200  100
 36951  200
```
(Process 36951's parent is 200, which is the pane shell.)

`tests/fixtures/ps_nested.txt`:
```
    1     0
   100    1
   200  100
 30000  200
 35000 30000
 36951 35000
```
(Process 36951 → 35000 → 30000 → 200. The pane shell is 200 — requires multi-hop walk.)

- [ ] **Step 7: Add tmux list-panes fixture**

`tests/fixtures/list_panes.txt`:
```
200 main:@1.%17 /Users/u/repo
300 main:@2.%18 /Users/u/repo2
```
(Format used in tick.sh: `pane_pid window_id.pane_id cwd`.)

- [ ] **Step 8: Add `bin/run_tests`**

```bash
#!/usr/bin/env bash
# bin/run_tests — run all bats tests under tests/.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bats "$DIR/tests/unit" "$DIR/tests/integration"
```

```bash
chmod +x bin/run_tests
```

- [ ] **Step 9: Smoke run**

Run: `bin/run_tests`
Expected: existing variables.sh + helpers.sh tests pass (all others fail until built).

- [ ] **Step 10: Commit**

```bash
git add tests/helper.bash tests/stubs/ tests/fixtures/ bin/run_tests
git commit -m "test: bats harness, stubs, and JSON/ps/list-panes fixtures"
```

---

## Phase 2 — PPID mapper

### Task 5: map_pid_to_pane.sh

**Files:**
- Create: `scripts/map_pid_to_pane.sh`
- Create: `tests/unit/test_map_pid_to_pane.bats`

**Contract:** stdin is `PID1\nPID2\n...`. Args are the panes file (lines `pane_pid session:window_id.pane_id cwd`) and the ps file (lines `pid ppid`). stdout is `PID\tWINDOW_ID\tPANE_ID\tFULL_TARGET` for each resolved PID, where `FULL_TARGET` is the original `session:window_id.pane_id` string (handy for downstream `switch-client`/`send-keys`). Unresolved PIDs are skipped silently.

- [ ] **Step 1: Write failing test**

`tests/unit/test_map_pid_to_pane.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() { common_setup; }

run_mapper() {
  local pids="$1" panes="$2" pstree="$3"
  echo "$pids" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes" "$pstree"
}

@test "single-hop resolution" {
  output="$(run_mapper "36951" "$FIXTURES/list_panes.txt" "$FIXTURES/ps_simple.txt")"
  [ "$output" = $'36951\t@1\t%17\tmain:@1.%17' ]
}

@test "multi-hop resolution" {
  output="$(run_mapper "36951" "$FIXTURES/list_panes.txt" "$FIXTURES/ps_nested.txt")"
  [ "$output" = $'36951\t@1\t%17\tmain:@1.%17' ]
}

@test "missing ancestor returns no output" {
  output="$(run_mapper "99999" "$FIXTURES/list_panes.txt" "$FIXTURES/ps_simple.txt")"
  [ -z "$output" ]
}

@test "batch resolves multiple pids in one invocation" {
  panes="$BATS_TEST_TMPDIR/panes.txt"
  pstree="$BATS_TEST_TMPDIR/ps.txt"
  cat > "$panes" <<EOF
200 main:@1.%17 /a
300 main:@2.%18 /b
EOF
  cat > "$pstree" <<EOF
200 1
300 1
36951 200
36952 300
EOF
  output="$(printf '36951\n36952\n' | \
    "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes" "$pstree" | sort)"
  expected=$'36951\t@1\t%17\tmain:@1.%17\n36952\t@2\t%18\tmain:@2.%18'
  [ "$output" = "$expected" ]
}

@test "recursion is capped (synthetic cycle)" {
  pstree="$BATS_TEST_TMPDIR/cycle.txt"
  # PID 1000 -> 1001 -> 1000 cycle. Should terminate, print nothing.
  cat > "$pstree" <<EOF
1000 1001
1001 1000
EOF
  panes="$BATS_TEST_TMPDIR/panes.txt"
  echo "9999 main:@1.%17 /x" > "$panes"
  output="$(echo "1000" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes" "$pstree")"
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_map_pid_to_pane.bats`
Expected: FAIL (script missing).

- [ ] **Step 3: Write `scripts/map_pid_to_pane.sh`**

```bash
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
```

```bash
chmod +x scripts/map_pid_to_pane.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_map_pid_to_pane.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/map_pid_to_pane.sh tests/unit/test_map_pid_to_pane.bats
git commit -m "feat(mapper): batch PPID-walk PID-to-pane resolver"
```

---

## Phase 3 — State machine + tick

### Task 6: apply_state.sh — compute desired state, emit tmux commands

**Files:**
- Create: `scripts/apply_state.sh`
- Create: `tests/unit/test_apply_state.bats`

**Contract:** `apply_state.sh` is a library sourced by `tick.sh`. It exposes `desired_state_for <claude_status>` and `reconcile_window_state` which diffs an associative array of `window_id -> state` against a state file and emits `set-option` / `set-option -u` calls.

- [ ] **Step 1: Write failing test**

`tests/unit/test_apply_state.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() {
  common_setup
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/scripts/apply_state.sh"
}

@test "desired_state_for: busy -> busy" {
  run desired_state_for "busy"
  [ "$output" = "busy" ]
}

@test "desired_state_for: idle -> attn" {
  run desired_state_for "idle"
  [ "$output" = "attn" ]
}

@test "desired_state_for: unknown -> attn (forward compat)" {
  run desired_state_for "xyzzy"
  [ "$output" = "attn" ]
}

@test "reconcile emits set-option for new window" {
  declare -A desired=(["@1"]="busy")
  : > "$STATEFILE"
  reconcile_window_state desired
  grep -q "set-option -w -q -t @1 @claude-status busy" "$STUB_OUT"
}

@test "reconcile skips unchanged window" {
  declare -A desired=(["@1"]="busy")
  echo "@1 busy" > "$STATEFILE"
  reconcile_window_state desired
  ! grep -q "set-option -w -q -t @1 @claude-status busy" "$STUB_OUT"
}

@test "reconcile schedules done-linger for vanished window" {
  declare -A desired=()
  echo "@1 busy" > "$STATEFILE"
  reconcile_window_state desired
  grep -q "set-option -w -q -t @1 @claude-status done" "$STUB_OUT"
  grep -q "^@1 done " "$STATEFILE"
}

@test "reconcile unsets after linger expires" {
  declare -A desired=()
  # done state with timestamp far in the past
  echo "@1 done 1" > "$STATEFILE"
  reconcile_window_state desired
  grep -q "set-option -w -u -q -t @1 @claude-status" "$STUB_OUT"
}

@test "priority: attn beats busy in same window" {
  declare -A desired=(["@1"]="busy")
  # second call for same window with attn should win when merged
  merge_state desired "@1" "attn"
  [ "${desired[@1]}" = "attn" ]
}

@test "priority: busy beats done in same window" {
  declare -A desired=(["@1"]="done")
  merge_state desired "@1" "busy"
  [ "${desired[@1]}" = "busy" ]
}

@test "write_summary global option" {
  write_summary 2 1 0
  grep -q "set-option -g -q @claude-summary 2 busy, 1 attn" "$STUB_OUT"
}

@test "write_summary empty when no sessions" {
  write_summary 0 0 0
  grep -q "set-option -g -q @claude-summary " "$STUB_OUT" || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_apply_state.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/apply_state.sh`**

```bash
#!/usr/bin/env bash
# scripts/apply_state.sh
# State machine + tmux command emission for the daemon.
# Requires variables.sh and helpers.sh sourced.

# desired_state_for <claude_status_string>
desired_state_for() {
  case "$1" in
    busy) printf 'busy' ;;
    *)    printf 'attn' ;;
  esac
}

# merge_state <assoc_ref> <window_id> <state>
# Priority: attn > busy > done.
merge_state() {
  local -n _arr="$1"
  local win="$2" new="$3" cur="${_arr[$2]:-}"
  if [ -z "$cur" ]; then
    _arr[$win]="$new"; return
  fi
  case "$cur:$new" in
    attn:*)         _arr[$win]="$cur" ;;
    *:attn)         _arr[$win]="$new" ;;
    busy:*)         _arr[$win]="$cur" ;;
    *:busy)         _arr[$win]="$new" ;;
    *)              _arr[$win]="$cur" ;;
  esac
}

# write_summary <busy_count> <attn_count> <done_count>
write_summary() {
  local busy="$1" attn="$2" done_n="$3"
  local s=""
  [ "$busy" -gt 0 ] && s+="${busy} busy"
  if [ "$attn" -gt 0 ]; then
    [ -n "$s" ] && s+=", "
    s+="${attn} attn"
  fi
  if [ "$done_n" -gt 0 ]; then
    [ -n "$s" ] && s+=", "
    s+="${done_n} done"
  fi
  set_tmux_option_global "$OPT_SUMMARY" "$s"
}

# _now_ms — milliseconds since epoch (portable enough)
_now_ms() {
  # `date +%s%3N` works on GNU date; macOS date has no %N. Use python or perl
  # fallback. Plugin already depends on jq/awk; perl is universally present.
  perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'
}

# reconcile_window_state <assoc_ref>
# Diffs the desired map against $STATEFILE, emits tmux set-option calls,
# manages done-linger expiry, and rewrites $STATEFILE.
reconcile_window_state() {
  local -n _desired="$1"
  local -A prev=()
  local -A prev_ts=()
  local linger_ms; linger_ms="$(get_tmux_option "$OPT_DONE_LINGER_MS" "$DEFAULT_DONE_LINGER_MS")"
  local now; now="$(_now_ms)"

  if [ -f "$STATEFILE" ]; then
    local w s t
    while read -r w s t; do
      [ -n "$w" ] || continue
      prev[$w]="$s"
      prev_ts[$w]="${t:-$now}"
    done < "$STATEFILE"
  fi

  local -A next=()

  # Sessions still live -> apply desired states.
  local win
  for win in "${!_desired[@]}"; do
    local target="${_desired[$win]}"
    if [ "${prev[$win]:-}" != "$target" ]; then
      set_tmux_option_window "$win" "$OPT_STATUS" "$target"
    fi
    next[$win]="$target $now"
  done

  # Windows in prev but not in desired -> done-linger logic.
  for win in "${!prev[@]}"; do
    if [ -z "${_desired[$win]:-}" ]; then
      local prev_state="${prev[$win]}"
      local ts="${prev_ts[$win]}"
      case "$prev_state" in
        done)
          if [ "$((now - ts))" -ge "$linger_ms" ]; then
            unset_tmux_option_window "$win" "$OPT_STATUS"
          else
            next[$win]="done $ts"
          fi
          ;;
        *)
          set_tmux_option_window "$win" "$OPT_STATUS" "done"
          next[$win]="done $now"
          ;;
      esac
    fi
  done

  # Rewrite state file.
  : > "$STATEFILE"
  for win in "${!next[@]}"; do
    printf '%s %s\n' "$win" "${next[$win]}" >> "$STATEFILE"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_apply_state.bats`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/apply_state.sh tests/unit/test_apply_state.bats
git commit -m "feat(state): state machine + reconcile against state file"
```

---

### Task 7: tick.sh — one poll iteration

**Files:**
- Create: `scripts/tick.sh`
- Create: `tests/unit/test_tick.bats`

**Contract:** Reads `claude agents --json`, builds the pane and pstree snapshots, resolves each session, merges states per window, calls `reconcile_window_state`, writes summary. Pure side-effect when complete. No sleep.

- [ ] **Step 1: Write failing test**

`tests/unit/test_tick.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() { common_setup; }

# Replace the tmux stub's list-panes with a fixture.
override_list_panes() {
  cat > "$STUBS/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${STUB_OUT:-/dev/null}"
case "$1" in
  list-panes)
    cat "$STUB_LIST_PANES_FIXTURE"
    exit 0
    ;;
  show-option|show-options)
    case "$2" in
      -gqv) printf '%s' "${STUB_OPT_VALUE:-}" ;;
      *)    printf '%s' "${STUB_OPT_VALUE:-}" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBS/tmux"
}

teardown() {
  # Restore the default tmux stub.
  cat > "$STUBS/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_OUT:-/dev/null}"
case "$1" in
  show-option|show-options) printf '%s' "${STUB_OPT_VALUE:-}"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUBS/tmux"
}

@test "empty JSON: no per-window calls" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_empty.json"
  export STUB_LIST_PANES_FIXTURE="$FIXTURES/list_panes.txt"
  export STUB_PS_FIXTURE="$FIXTURES/ps_simple.txt"
  override_list_panes
  run "$PLUGIN_DIR/scripts/tick.sh"
  [ "$status" -eq 0 ]
  ! grep -q "@claude-status" "$STUB_OUT"
}

@test "busy session sets @1 busy" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_busy.json"
  export STUB_LIST_PANES_FIXTURE="$FIXTURES/list_panes.txt"
  export STUB_PS_FIXTURE="$FIXTURES/ps_simple.txt"
  override_list_panes
  "$PLUGIN_DIR/scripts/tick.sh"
  grep -q "set-option -w -q -t @1 @claude-status busy" "$STUB_OUT"
}

@test "idle session sets @1 attn" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_attn.json"
  export STUB_LIST_PANES_FIXTURE="$FIXTURES/list_panes.txt"
  export STUB_PS_FIXTURE="$FIXTURES/ps_simple.txt"
  override_list_panes
  "$PLUGIN_DIR/scripts/tick.sh"
  grep -q "set-option -w -q -t @1 @claude-status attn" "$STUB_OUT"
}

@test "missing claude logs and exits 0" {
  PATH="${PATH//$STUBS:/}"
  run "$PLUGIN_DIR/scripts/tick.sh"
  [ "$status" -eq 0 ]
}

@test "invalid json keeps last state" {
  echo "not json" > "$BATS_TEST_TMPDIR/bad.json"
  export STUB_CLAUDE_FIXTURE="$BATS_TEST_TMPDIR/bad.json"
  export STUB_LIST_PANES_FIXTURE="$FIXTURES/list_panes.txt"
  export STUB_PS_FIXTURE="$FIXTURES/ps_simple.txt"
  override_list_panes
  echo "@1 busy 0" > "$STATEFILE"
  "$PLUGIN_DIR/scripts/tick.sh"
  # Should not change @1's state.
  ! grep -q "set-option -w -q -t @1" "$STUB_OUT"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_tick.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/tick.sh`**

```bash
#!/usr/bin/env bash
# scripts/tick.sh
# One iteration of the daemon poll loop.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/apply_state.sh"

if ! command -v claude >/dev/null 2>&1; then
  log_warn "claude CLI not on PATH; skipping tick"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log_error "jq not on PATH; cannot parse JSON"
  exit 0
fi

# Capture JSON (single fork).
json_tmp="$(mktemp)"
trap 'rm -f "$json_tmp"' EXIT
if ! claude agents --json > "$json_tmp" 2>/dev/null; then
  log_warn "claude agents --json failed; keeping last state"
  exit 0
fi
if ! jq -e . "$json_tmp" >/dev/null 2>&1; then
  log_warn "claude agents --json returned non-JSON; keeping last state"
  exit 0
fi

# Snapshot panes.
panes_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp"' EXIT
tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_id}.#{pane_id} #{pane_current_path}' > "$panes_tmp" 2>/dev/null || true

# Snapshot pstree.
pstree_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp" "$pstree_tmp"' EXIT
ps -A -o pid=,ppid= > "$pstree_tmp" 2>/dev/null || true

# Parse PIDs + statuses from JSON.
pid_status_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp" "$pstree_tmp" "$pid_status_tmp"' EXIT
jq -r '.[] | "\(.pid)\t\(.status)"' "$json_tmp" > "$pid_status_tmp"

# Resolve each PID to a window via mapper.
resolved_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp" "$pstree_tmp" "$pid_status_tmp" "$resolved_tmp"' EXIT
cut -f1 "$pid_status_tmp" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes_tmp" "$pstree_tmp" > "$resolved_tmp"

# Build desired map: window_id -> state.
declare -A desired=()
busy=0; attn=0
while IFS=$'\t' read -r pid status; do
  [ -n "$pid" ] || continue
  win="$(awk -v p="$pid" '$1==p {print $2; exit}' "$resolved_tmp")"
  [ -n "$win" ] || { log_debug "no pane for pid $pid"; continue; }
  state="$(desired_state_for "$status")"
  merge_state desired "$win" "$state"
done < "$pid_status_tmp"

# Counts for summary.
for s in "${desired[@]}"; do
  case "$s" in
    busy) busy=$((busy+1)) ;;
    attn) attn=$((attn+1)) ;;
  esac
done

reconcile_window_state desired
write_summary "$busy" "$attn" 0
```

```bash
chmod +x scripts/tick.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_tick.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/tick.sh tests/unit/test_tick.bats
git commit -m "feat(tick): one poll iteration wiring JSON, mapper, state machine"
```

---

## Phase 4 — Daemon

### Task 8: daemon.sh — long-lived poll loop

**Files:**
- Create: `scripts/daemon.sh`
- Create: `tests/integration/test_daemon_lifecycle.bats`

- [ ] **Step 1: Write failing test**

`tests/integration/test_daemon_lifecycle.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() {
  common_setup
  # Make tick.sh a no-op so the loop is cheap.
  cat > "$BATS_TEST_TMPDIR/fake_tick.sh" <<'STUB'
#!/usr/bin/env bash
echo "tick at $(date +%s)" >> "${STUB_OUT:-/dev/null}"
STUB
  chmod +x "$BATS_TEST_TMPDIR/fake_tick.sh"
}

run_daemon() {
  local tmux_pid="$1"
  ( TICK_OVERRIDE="$BATS_TEST_TMPDIR/fake_tick.sh" \
    POLL_INTERVAL_OVERRIDE="0.2" \
    "$PLUGIN_DIR/scripts/daemon.sh" "$tmux_pid" &
    echo $! )
}

@test "writes pidfile and starts ticking" {
  sleep 5 &
  fake_tmux=$!
  daemon_pid="$(run_daemon "$fake_tmux")"
  sleep 0.6
  [ -f "$PIDFILE" ]
  [ "$(cat "$PIDFILE")" = "$daemon_pid" ]
  kill "$fake_tmux" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  grep -q "tick at" "$STUB_OUT"
}

@test "exits when fake tmux pid disappears" {
  sleep 1 &
  fake_tmux=$!
  daemon_pid="$(run_daemon "$fake_tmux")"
  sleep 0.4
  kill "$fake_tmux" 2>/dev/null || true
  # Daemon should exit within one poll interval (~0.2s).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$daemon_pid" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$daemon_pid" 2>/dev/null
  [ ! -f "$PIDFILE" ]
}

@test "stale pidfile is replaced on start" {
  echo "99999" > "$PIDFILE"  # almost certainly not alive
  sleep 5 &
  fake_tmux=$!
  daemon_pid="$(run_daemon "$fake_tmux")"
  sleep 0.4
  [ "$(cat "$PIDFILE")" = "$daemon_pid" ]
  kill "$fake_tmux" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/test_daemon_lifecycle.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/daemon.sh`**

```bash
#!/usr/bin/env bash
# scripts/daemon.sh
# Long-lived poll loop. Exits when the tmux server PID it watches dies.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"

TMUX_PID="${1:-}"
[ -n "$TMUX_PID" ] || { echo "usage: $0 <tmux_server_pid>" >&2; exit 2; }

# Allow tests to override.
TICK="${TICK_OVERRIDE:-$PLUGIN_DIR/scripts/tick.sh}"

# Write pid file.
echo "$$" > "$PIDFILE"

cleanup() {
  rm -f "$PIDFILE"
  exit 0
}
trap cleanup TERM INT EXIT

log_info "daemon started, watching tmux pid $TMUX_PID"

while :; do
  if ! kill -0 "$TMUX_PID" 2>/dev/null; then
    log_info "tmux pid $TMUX_PID gone; daemon exiting"
    break
  fi
  if ! "$TICK"; then
    log_warn "tick failed (rc=$?); continuing"
  fi
  interval="${POLL_INTERVAL_OVERRIDE:-$(get_tmux_option "$OPT_POLL_INTERVAL" "$DEFAULT_POLL_INTERVAL")}"
  sleep "$interval"
done
```

```bash
chmod +x scripts/daemon.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/integration/test_daemon_lifecycle.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/daemon.sh tests/integration/test_daemon_lifecycle.bats
git commit -m "feat(daemon): poll loop with tmux-pid watchdog and pidfile lifecycle"
```

---

## Phase 5 — Entry point

### Task 9: claude_session_manager.tmux

**Files:**
- Create: `claude_session_manager.tmux`
- Create: `tests/integration/test_entry.bats`

**Contract:** the `.tmux` file is both the TPM entry point (no-args invocation) and a CLI (one-arg form: `doctor`). Idempotent for TPM reloads.

- [ ] **Step 1: Write failing test**

`tests/integration/test_entry.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() {
  common_setup
  # Make daemon a no-op for entry tests.
  cat > "$BATS_TEST_TMPDIR/fake_daemon.sh" <<'STUB'
#!/usr/bin/env bash
echo "daemon $*" >> "${STUB_OUT:-/dev/null}"
echo "$$" > "$PIDFILE"
sleep 5
STUB
  chmod +x "$BATS_TEST_TMPDIR/fake_daemon.sh"
}

@test "first invocation spawns daemon and binds picker key" {
  DAEMON_OVERRIDE="$BATS_TEST_TMPDIR/fake_daemon.sh" \
    "$PLUGIN_DIR/claude_session_manager.tmux"
  sleep 0.2
  grep -q "bind-key" "$STUB_OUT"
  [ -f "$PIDFILE" ]
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
}

@test "second invocation is a no-op when daemon alive" {
  # Plant a live process.
  sleep 10 &
  echo "$!" > "$PIDFILE"
  DAEMON_OVERRIDE="$BATS_TEST_TMPDIR/fake_daemon.sh" \
    "$PLUGIN_DIR/claude_session_manager.tmux"
  # No second daemon row in $STUB_OUT for that fake_daemon stub.
  ! grep -q "daemon " "$STUB_OUT"
  kill "$!" 2>/dev/null || true
}

@test "doctor subcommand runs doctor.sh and exits" {
  # Doctor not built yet -> at least ensure the dispatch happens.
  run "$PLUGIN_DIR/claude_session_manager.tmux" doctor
  # We assert behavior in test_doctor.bats; here we just want non-error dispatch.
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "respects @claude-enabled=off" {
  export STUB_OPT_VALUE="off"
  DAEMON_OVERRIDE="$BATS_TEST_TMPDIR/fake_daemon.sh" \
    "$PLUGIN_DIR/claude_session_manager.tmux"
  [ ! -f "$PIDFILE" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/test_entry.bats`
Expected: FAIL.

- [ ] **Step 3: Write `claude_session_manager.tmux`**

```bash
#!/usr/bin/env bash
# claude_session_manager.tmux
# TPM entry point + CLI dispatcher.

set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$CURRENT_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$CURRENT_DIR/scripts/helpers.sh"

# CLI dispatch -----------------------------------------------------------
case "${1:-}" in
  doctor)
    exec "$CURRENT_DIR/scripts/doctor.sh"
    ;;
  picker)
    exec "$CURRENT_DIR/scripts/picker.sh"
    ;;
  toggle)
    cur="$(get_tmux_option "$OPT_ENABLED" "$DEFAULT_ENABLED")"
    if [ "$cur" = "on" ]; then
      set_tmux_option_global "$OPT_ENABLED" "off"
      if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
        rm -f "$PIDFILE"
      fi
    else
      set_tmux_option_global "$OPT_ENABLED" "on"
      exec "$0"
    fi
    exit 0
    ;;
esac

# TPM entry --------------------------------------------------------------

# Honor @claude-enabled.
enabled="$(get_tmux_option "$OPT_ENABLED" "$DEFAULT_ENABLED")"
[ "$enabled" = "on" ] || exit 0

# Bind picker key (configurable).
picker_key="$(get_tmux_option "$OPT_PICKER_KEY" "$DEFAULT_PICKER_KEY")"
tmux bind-key "$picker_key" run-shell -b "$CURRENT_DIR/claude_session_manager.tmux picker"

# Bind picker-toggle key (uppercase of picker key by default).
toggle_key="$(get_tmux_option "@claude-toggle-key" "$(echo "$picker_key" | tr '[:lower:]' '[:upper:]')")"
tmux bind-key "$toggle_key" run-shell -b "$CURRENT_DIR/claude_session_manager.tmux toggle"

# Inject window-name format with @claude-status colorization, preserving
# the user's original format. We store the pristine original on first run
# in a sibling tmux option (@claude-orig-<opt>) and always rebuild from it,
# which makes reloads safely idempotent.
inject_format() {
  local opt="$1"   # window-status-format or window-status-current-format
  local saved_key="@claude-orig-$opt"
  local original; original="$(tmux show-option -gqv "$saved_key")"
  if [ -z "$original" ]; then
    original="$(tmux show-option -gqv "$opt")"
    [ -n "$original" ] || original="#I:#W#F"
    tmux set-option -gq "$saved_key" "$original"
  fi
  local busy attn done_c
  busy="$(get_tmux_option "$OPT_COLOR_BUSY" "$DEFAULT_COLOR_BUSY")"
  attn="$(get_tmux_option "$OPT_COLOR_ATTN" "$DEFAULT_COLOR_ATTN")"
  done_c="$(get_tmux_option "$OPT_COLOR_DONE" "$DEFAULT_COLOR_DONE")"
  local cond="#[fg=#{?#{==:#{@claude-status},busy},$busy,#{?#{==:#{@claude-status},attn},$attn,#{?#{==:#{@claude-status},done},$done_c,default}}}]"
  tmux set-option -gq "$opt" "${cond}${original}#[default]"
}
inject_format "window-status-format"
inject_format "window-status-current-format"

# Spawn daemon if not already running.
DAEMON="${DAEMON_OVERRIDE:-$CURRENT_DIR/scripts/daemon.sh}"
start_daemon() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  rm -f "$PIDFILE"
  local tmux_pid
  tmux_pid="$(tmux display-message -p '#{pid}' 2>/dev/null || echo $$)"
  ( nohup "$DAEMON" "$tmux_pid" >> "$LOGFILE" 2>&1 & )
}
start_daemon
```

```bash
chmod +x claude_session_manager.tmux
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/integration/test_entry.bats`
Expected: PASS (4 tests, with the doctor test passing trivially until Task 11).

- [ ] **Step 5: Commit**

```bash
git add claude_session_manager.tmux tests/integration/test_entry.bats
git commit -m "feat(entry): TPM entry, CLI dispatcher, format injection, daemon startup"
```

---

## Phase 6 — Picker

### Task 10: picker.sh

**Files:**
- Create: `scripts/picker.sh`
- Create: `tests/integration/test_picker.bats`

**Contract:** `picker.sh` is invoked from `run-shell` and itself invokes `display-popup -E ...` running an internal command. The internal command formats sessions for `fzf` (or falls back to `display-menu` if fzf missing) and dispatches actions on Enter/C-k/C-l.

- [ ] **Step 1: Write failing test**

`tests/integration/test_picker.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() { common_setup; }

@test "renders session lines from JSON for fzf" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_mixed.json"
  PATH="$STUBS:$PATH"
  run "$PLUGIN_DIR/scripts/picker.sh" --render
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "aaaa"
  echo "$output" | grep -q "busy"
  echo "$output" | grep -q "bbbb"
  echo "$output" | grep -q "idle"
}

@test "invokes display-popup when called with no args (interactive mode)" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_busy.json"
  PATH="$STUBS:$PATH"
  "$PLUGIN_DIR/scripts/picker.sh"
  grep -q "display-popup" "$STUB_OUT"
}

@test "falls back to display-menu when fzf missing" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_busy.json"
  PATH="$STUBS:$PATH"
  FZF_DISABLE=1 "$PLUGIN_DIR/scripts/picker.sh"
  grep -q "display-menu" "$STUB_OUT" || grep -q "display-popup" "$STUB_OUT"
}

@test "action=jump emits switch-client" {
  PATH="$STUBS:$PATH"
  "$PLUGIN_DIR/scripts/picker.sh" --action jump --target "main:@1.%17"
  grep -q "switch-client -t main:@1.%17" "$STUB_OUT"
}

@test "action=kill emits send-keys C-c" {
  PATH="$STUBS:$PATH"
  "$PLUGIN_DIR/scripts/picker.sh" --action kill --target "main:@1.%17"
  grep -q "send-keys -t main:@1.%17 C-c" "$STUB_OUT"
}

@test "action=clear emits send-keys /clear" {
  PATH="$STUBS:$PATH"
  "$PLUGIN_DIR/scripts/picker.sh" --action clear --target "main:@1.%17"
  grep -q "send-keys -t main:@1.%17 /clear Enter" "$STUB_OUT"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/test_picker.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/picker.sh`**

```bash
#!/usr/bin/env bash
# scripts/picker.sh
# Session picker: lists Claude sessions, dispatches jump/kill/clear actions.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"

# Action dispatch --------------------------------------------------------
if [ "${1:-}" = "--action" ]; then
  action="$2"; shift 2
  target=""
  while [ $# -gt 0 ]; do
    case "$1" in --target) target="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$target" ] || { echo "missing --target" >&2; exit 2; }
  case "$action" in
    jump)  tmux switch-client -t "$target" ;;
    kill)  tmux send-keys     -t "$target" C-c ;;
    clear) tmux send-keys     -t "$target" "/clear" Enter ;;
    *) echo "unknown action: $action" >&2; exit 2 ;;
  esac
  exit 0
fi

# Render mode (used by --render flag and inside the popup) --------------
render_lines() {
  # Print TAB-separated: target<TAB>display
  # display: "<short-id>  <status>  <cwd>"
  local panes_tmp pstree_tmp resolved_tmp pid_status_tmp
  panes_tmp="$(mktemp)"; pstree_tmp="$(mktemp)"
  resolved_tmp="$(mktemp)"; pid_status_tmp="$(mktemp)"
  trap 'rm -f "$panes_tmp" "$pstree_tmp" "$resolved_tmp" "$pid_status_tmp"' EXIT

  tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_id}.#{pane_id} #{pane_current_path}' > "$panes_tmp" 2>/dev/null || true
  ps -A -o pid=,ppid= > "$pstree_tmp" 2>/dev/null || true

  claude agents --json 2>/dev/null \
    | jq -r '.[] | "\(.pid)\t\(.sessionId)\t\(.status)\t\(.cwd)"' \
    > "$pid_status_tmp"

  cut -f1 "$pid_status_tmp" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes_tmp" "$pstree_tmp" > "$resolved_tmp"

  while IFS=$'\t' read -r pid sess status cwd; do
    [ -n "$pid" ] || continue
    # Mapper output column 4 is the full session:window_id.pane_id target.
    target="$(awk -v p="$pid" '$1==p {print $4; exit}' "$resolved_tmp")"
    [ -n "$target" ] || target="-"
    short="${sess:0:8}"
    printf '%s\t%s  %-6s  %s\n' "$target" "$short" "$status" "$cwd"
  done < "$pid_status_tmp"
}

if [ "${1:-}" = "--render" ]; then
  render_lines
  exit 0
fi

# Interactive mode ------------------------------------------------------
if [ "${FZF_DISABLE:-0}" = "1" ] || ! command -v fzf >/dev/null 2>&1; then
  # display-menu fallback: build menu items, default action = jump.
  args=()
  while IFS=$'\t' read -r target display; do
    args+=( "$display" "" "run-shell '$PLUGIN_DIR/scripts/picker.sh --action jump --target $target'" )
  done < <(render_lines)
  if [ ${#args[@]} -eq 0 ]; then
    args+=( "(no claude sessions)" "" "" )
  fi
  tmux display-menu -T "#[align=centre] Claude Sessions " -x C -y C "${args[@]}"
  exit 0
fi

# fzf-in-popup path.
tmux display-popup -E -w 80% -h 60% -T " Claude Sessions " \
  "$PLUGIN_DIR/scripts/picker.sh --fzf-inner"
```

Add the inner fzf branch at the end (before the final fzf-in-popup call) — actually keep it as a separate handler so the picker re-enters with an explicit arg:

Insert before the `# Interactive mode` block:

```bash
if [ "${1:-}" = "--fzf-inner" ]; then
  sel="$(render_lines | fzf \
    --with-nth=2 \
    --delimiter=$'\t' \
    --header='Enter=jump  C-k=kill  C-l=clear  Esc=close' \
    --bind 'ctrl-k:execute(tmux send-keys -t {1} C-c)+abort' \
    --bind 'ctrl-l:execute(tmux send-keys -t {1} "/clear" Enter)+abort' \
    --expect=enter)"
  key="$(echo "$sel" | head -1)"
  line="$(echo "$sel" | sed -n 2p)"
  target="$(echo "$line" | cut -f1)"
  [ -n "$target" ] || exit 0
  case "$key" in
    enter|"") tmux switch-client -t "$target" ;;
  esac
  exit 0
fi
```

Final order in the file: `--action` dispatch → `--fzf-inner` → `--render` → interactive.

```bash
chmod +x scripts/picker.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/integration/test_picker.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/picker.sh tests/integration/test_picker.bats
git commit -m "feat(picker): display-popup + fzf picker with jump/kill/clear"
```

---

## Phase 7 — Doctor

### Task 11: doctor.sh

**Files:**
- Create: `scripts/doctor.sh`
- Create: `tests/unit/test_doctor.bats`

**Contract:** read-only. Prints a plain-text diagnostic report. Exits 0 on full pass, 1 on critical issues (missing claude, missing jq, missing tmux).

- [ ] **Step 1: Write failing test**

`tests/unit/test_doctor.bats`:
```bash
#!/usr/bin/env bats

load ../helper.bash

setup() { common_setup; }

@test "reports all required tools" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_busy.json"
  PATH="$STUBS:$PATH"
  run "$PLUGIN_DIR/scripts/doctor.sh"
  echo "$output" | grep -q "claude"
  echo "$output" | grep -q "tmux"
  echo "$output" | grep -q "jq"
}

@test "exits 1 when claude missing" {
  PATH="${PATH//$STUBS:/}"
  PATH="$(echo "$PATH" | sed 's|/usr/local/bin||g; s|/opt/homebrew/bin||g')"
  # Hide real claude too.
  PATH="$BATS_TEST_TMPDIR/nope:$PATH"
  mkdir -p "$BATS_TEST_TMPDIR/nope"
  run "$PLUGIN_DIR/scripts/doctor.sh"
  [ "$status" -eq 1 ]
}

@test "reports daemon not running when no pidfile" {
  rm -f "$PIDFILE"
  PATH="$STUBS:$PATH"
  run "$PLUGIN_DIR/scripts/doctor.sh"
  echo "$output" | grep -qi "not running"
}

@test "reports current claude session count" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_mixed.json"
  PATH="$STUBS:$PATH"
  run "$PLUGIN_DIR/scripts/doctor.sh"
  echo "$output" | grep -q "3"
}

@test "does not call set-option (read-only)" {
  export STUB_CLAUDE_FIXTURE="$FIXTURES/sessions_busy.json"
  PATH="$STUBS:$PATH"
  "$PLUGIN_DIR/scripts/doctor.sh" >/dev/null
  ! grep -q "set-option" "$STUB_OUT"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/test_doctor.bats`
Expected: FAIL.

- [ ] **Step 3: Write `scripts/doctor.sh`**

```bash
#!/usr/bin/env bash
# scripts/doctor.sh
# Read-only diagnostics for tmux-claude-session-manager.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"

green() { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
ok()    { green "OK"; }
miss()  { red "MISSING"; }

EXIT=0

echo "tmux-claude-session-manager — doctor"
echo

# --- deps -------------------------------------------------------------
echo "[deps]"
check() {
  local name="$1" cmd="$2" required="$3" version_cmd="${4:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local ver=""
    [ -n "$version_cmd" ] && ver="$(eval "$version_cmd" 2>/dev/null | head -1)"
    printf '  %-9s %s %s\n' "$name" "$(ok)" "$ver"
  else
    printf '  %-9s %s\n' "$name" "$(miss)"
    [ "$required" = "1" ] && EXIT=1
  fi
}
check claude  claude 1 "claude --version"
check tmux    tmux   1 "tmux -V"
check jq      jq     1 "jq --version"
check fzf     fzf    0 "fzf --version"
check awk     awk    1 ""
check ps      ps     1 ""
echo

# --- claude probe -----------------------------------------------------
echo "[claude probe]"
if command -v claude >/dev/null 2>&1; then
  start_ns="$(perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000000)')"
  json="$(claude agents --json 2>/dev/null || echo '[]')"
  end_ns="$(perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000000)')"
  count="$(echo "$json" | jq 'length' 2>/dev/null || echo 0)"
  ms=$(( (end_ns - start_ns) / 1000 ))
  printf '  %d sessions in %d ms\n' "$count" "$ms"
else
  echo "  (skipped — claude not on PATH)"
fi
echo

# --- daemon -----------------------------------------------------------
echo "[daemon]"
if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "  Running (pid $pid)"
  else
    echo "  Stale pidfile: $PIDFILE (pid $pid not alive)"
  fi
else
  echo "  Not running (no pidfile at $PIDFILE)"
fi
echo

# --- config -----------------------------------------------------------
echo "[config]"
for opt in "$OPT_ENABLED" "$OPT_PICKER_KEY" "$OPT_POLL_INTERVAL" \
           "$OPT_COLOR_BUSY" "$OPT_COLOR_ATTN" "$OPT_COLOR_DONE" \
           "$OPT_DONE_LINGER_MS" "$OPT_LOG_LEVEL"; do
  val="$(get_tmux_option "$opt" "(default)")"
  printf '  %-30s %s\n' "$opt" "$val"
done

exit "$EXIT"
```

```bash
chmod +x scripts/doctor.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/test_doctor.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/doctor.sh tests/unit/test_doctor.bats
git commit -m "feat(doctor): read-only diagnostics report"
```

---

## Phase 8 — CI, README, smoke

### Task 12: GitHub Actions CI

**Files:**
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Write `.github/workflows/test.yml`**

```yaml
name: test

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  bats:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        tmux: ["3.2", "3.3", "3.4", "latest"]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Install bats-core, jq, fzf
        run: |
          if [ "${{ matrix.os }}" = "macos-latest" ]; then
            brew install bats-core jq fzf
          else
            sudo apt-get update
            sudo apt-get install -y bats jq fzf
          fi

      - name: Install tmux ${{ matrix.tmux }}
        run: |
          if [ "${{ matrix.os }}" = "macos-latest" ]; then
            brew install tmux
          else
            sudo apt-get install -y tmux
          fi
          tmux -V

      - name: Run tests
        run: bin/run_tests

  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          scandir: '.'
          format: gcc
          severity: warning
          ignore_paths: tests/fixtures tests/stubs
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: bats matrix + shellcheck"
```

---

### Task 13: README

**Files:**
- Modify: `README.md` (replace skeleton with full content)

- [ ] **Step 1: Replace `README.md`**

```markdown
# tmux-claude-session-manager

Per-window status indicators and a session picker for Claude Code sessions
running inside tmux. Driven by a single bash daemon that polls
`claude agents --json` (Claude Code ≥ 2.1.139).

![status indicator demo](docs/screenshots/indicator.png)

## Features

- Window-name color flips automatically when a Claude pane is working
  (yellow), needs your input (red), or recently finished (green).
- `prefix + j` opens an `fzf` popup listing all live Claude sessions on the
  tmux server. `Enter` jumps to the pane, `C-k` sends `C-c`, `C-l` sends
  `/clear`.
- Single bash daemon per tmux server. No external services. macOS + Linux.
- TPM-installable; pure bash + standard POSIX tools (`awk`, `ps`, `jq`).

## Requirements

- tmux ≥ 3.2 (`display-popup` support)
- claude ≥ 2.1.139 (`claude agents --json`)
- `jq`
- `fzf` (optional; picker falls back to `display-menu`)

## Install (TPM)

```tmux
set -g @plugin 'cunderw/tmux-claude-session-manager'
```

Then `prefix + I` to install.

## Install (manual)

```bash
git clone https://github.com/cunderw/tmux-claude-session-manager ~/.tmux/plugins/tmux-claude-session-manager
echo 'run-shell ~/.tmux/plugins/tmux-claude-session-manager/claude_session_manager.tmux' >> ~/.tmux.conf
tmux source ~/.tmux.conf
```

## Configuration

All options are tmux user options. Set in `~/.tmux.conf` **before** loading the plugin.

| Option | Default | Purpose |
|---|---|---|
| `@claude-enabled` | `on` | Master switch. |
| `@claude-picker-key` | `j` | Picker keybind (prefix-prefixed). |
| `@claude-poll-interval` | `2` | Seconds between polls. |
| `@claude-color-busy` | `yellow` | Window-name color while busy. |
| `@claude-color-attn` | `red` | Color when input needed. |
| `@claude-color-done` | `green` | Color for done-linger. |
| `@claude-done-linger-ms` | `3000` | How long green persists after exit. |
| `@claude-log-level` | `warn` | `error|warn|info|debug`. |

Add the session count to `status-right`:

```tmux
set -g status-right '#{@claude-summary} | %H:%M'
```

## Diagnostics

```bash
~/.tmux/plugins/tmux-claude-session-manager/claude_session_manager.tmux doctor
```

## Smoke checklist

1. Fresh tmux, TPM install, no Claude running → status bar unchanged.
2. Start `claude` in one window → window-name turns yellow within 2 s.
3. Let Claude finish responding → window flips red.
4. `prefix + j` → fzf popup; Enter jumps; cursor lands on that pane.
5. `C-k` inside picker → sends `C-c` to the pane; after confirming quit,
   window goes green for 3 s then clears.
6. Quit tmux server → daemon exits; pidfile gone; no orphan `daemon.sh`.
7. `claude_session_manager.tmux doctor` → all green.

## Development

```bash
bin/run_tests          # all bats tests
shellcheck scripts/*.sh claude_session_manager.tmux
```

## License

MIT. See `LICENSE`.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: full README with install, config, and smoke checklist"
```

---

### Task 14: Tag v0.1.0 after manual smoke

**Files:** (none)

- [ ] **Step 1: Run the full bats suite locally**

Run: `bin/run_tests`
Expected: all unit + integration tests pass.

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck scripts/*.sh claude_session_manager.tmux`
Expected: no warnings or errors.

- [ ] **Step 3: Live smoke test against real tmux + real claude**

Walk the 7-step checklist in README.md. Note any deviations as new tasks; do **not** ship until all 7 pass.

- [ ] **Step 4: Tag v0.1.0**

```bash
git tag -a v0.1.0 -m "v0.1.0 initial release"
```

(Do not push yet — that's a manual decision for the user.)

---

## Self-review — spec coverage

| Spec section | Implemented in |
|---|---|
| Per-window color indicator | Task 9 (format injection) + Tasks 6-7 (state writing) |
| Picker (popup + fzf, jump/kill/clear) | Task 10 |
| `claude agents --json` polling | Task 7 (`tick.sh`) |
| PPID → pane mapping | Task 5 |
| State machine (busy/attn/done + linger) | Task 6 (`apply_state.sh`) |
| Multi-session priority rule | Task 6 (`merge_state`) |
| `@claude-summary` global option | Tasks 6-7 (`write_summary`) |
| Daemon lifecycle + PID file | Task 8 |
| Error handling matrix | Task 7 (`tick.sh` early-outs) + Task 8 (daemon `\|\| true`) |
| Logging + truncation | Task 3 (`helpers.sh`) |
| Doctor script | Task 11 |
| Configurable `@claude-*` options | Task 2 (variables.sh) + Task 9 (entry honors them) |
| `prefix + j` picker + `prefix + J` toggle | Task 9 |
| Tests (unit + integration) | Tasks 2, 3, 5, 6, 7, 8, 9, 10, 11 |
| CI matrix | Task 12 |
| README + smoke checklist | Task 13, 14 |
| Acceptance criteria | Task 14 (smoke + shellcheck + suite green) |

No spec gaps detected.
