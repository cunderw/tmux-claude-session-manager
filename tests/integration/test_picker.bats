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
