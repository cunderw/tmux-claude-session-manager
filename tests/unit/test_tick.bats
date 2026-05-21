#!/usr/bin/env bats

load ../helper.bash

setup() { common_setup; }

# Install a per-test tmux stub that also handles `list-panes` by reading a
# fixture. Writes to $BATS_TEST_TMPDIR (NOT the shared $STUBS dir) so the
# committed default stub stays untouched.
override_list_panes() {
  local override_dir="$BATS_TEST_TMPDIR/override"
  mkdir -p "$override_dir"
  cat > "$override_dir/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${STUB_OUT:-/dev/null}"
case "$1" in
  list-panes)
    cat "$STUB_LIST_PANES_FIXTURE"
    exit 0
    ;;
  show-option|show-options)
    printf '%s' "${STUB_OPT_VALUE:-}"
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$override_dir/tmux"
  PATH="$override_dir:$PATH"
  export PATH
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
