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
  # No daemon row in $STUB_OUT for that fake_daemon stub.
  ! grep -q "daemon " "$STUB_OUT"
  kill "$!" 2>/dev/null || true
}

@test "doctor subcommand runs doctor.sh and exits" {
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
