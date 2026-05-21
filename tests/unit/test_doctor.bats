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
