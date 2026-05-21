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
    "$PLUGIN_DIR/scripts/daemon.sh" "$tmux_pid" >/dev/null 2>&1 &
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
