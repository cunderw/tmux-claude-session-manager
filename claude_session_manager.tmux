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

enabled="$(get_tmux_option "$OPT_ENABLED" "$DEFAULT_ENABLED")"
[ "$enabled" = "on" ] || exit 0

# Bind picker key.
picker_key="$(get_tmux_option "$OPT_PICKER_KEY" "$DEFAULT_PICKER_KEY")"
tmux bind-key "$picker_key" run-shell -b "$CURRENT_DIR/claude_session_manager.tmux picker"

# Bind toggle key (uppercase of picker key by default).
toggle_key="$(get_tmux_option "@claude-toggle-key" "$(echo "$picker_key" | tr '[:lower:]' '[:upper:]')")"
tmux bind-key "$toggle_key" run-shell -b "$CURRENT_DIR/claude_session_manager.tmux toggle"

# Inject window-name format with @claude-status indicator, preserving
# the user's original format. We store the pristine original on first run
# in a sibling tmux option (@claude-orig-<opt>) and always rebuild from it,
# which makes reloads safely idempotent.
#
# Placement: by default the indicator is injected immediately AFTER the
# `#W` window-name token in the saved original. That puts the colored
# glyph inside the segment's styled background (works cleanly with
# powerline-style themes like powerkit/tokyo-night that color every
# segment). Override with `@claude-indicator-position`:
#   - after-name  (default): inject after `#W`
#   - prepend             : inject at the very start of the format
# If `#W` isn't present in the original, falls back to `prepend`.
inject_format() {
  local opt="$1"   # window-status-format or window-status-current-format
  local saved_key="@claude-orig-$opt"
  local original; original="$(tmux show-option -gqv "$saved_key")"
  if [ -z "$original" ]; then
    original="$(tmux show-option -gqv "$opt")"
    [ -n "$original" ] || original="#I:#W#F"
    tmux set-option -gq "$saved_key" "$original"
  fi
  local busy attn done_c glyph position
  busy="$(get_tmux_option "$OPT_COLOR_BUSY" "$DEFAULT_COLOR_BUSY")"
  attn="$(get_tmux_option "$OPT_COLOR_ATTN" "$DEFAULT_COLOR_ATTN")"
  done_c="$(get_tmux_option "$OPT_COLOR_DONE" "$DEFAULT_COLOR_DONE")"
  glyph="$(get_tmux_option "@claude-indicator-glyph" "●")"
  position="$(get_tmux_option "@claude-indicator-position" "after-name")"
  local color="#{?#{==:#{@claude-status},busy},$busy,#{?#{==:#{@claude-status},attn},$attn,#{?#{==:#{@claude-status},done},$done_c,default}}}"

  if [ "$position" = "after-name" ] && [[ "$original" == *"#W"* ]]; then
    # `#[fg=default]` restores foreground after the dot so the trailing space
    # / norange in most themes doesn't bleed our color.
    local indicator_inside="#{?#{@claude-status}, #[fg=${color}]${glyph}#[fg=default],}"
    tmux set-option -gq "$opt" "${original//\#W/#W${indicator_inside}}"
  else
    local indicator="#{?#{@claude-status},#[fg=${color}]${glyph}#[default] ,}"
    tmux set-option -gq "$opt" "${indicator}${original}"
  fi
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
