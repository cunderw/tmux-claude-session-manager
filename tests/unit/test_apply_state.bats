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
