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
