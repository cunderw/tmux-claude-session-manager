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
