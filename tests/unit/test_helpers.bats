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
