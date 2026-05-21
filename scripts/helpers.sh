#!/usr/bin/env bash
# scripts/helpers.sh
# tmux option I/O + leveled logging.

# Sourcing this requires variables.sh to have been sourced first.
[ -n "${OPT_LOG_LEVEL:-}" ] || {
  echo "helpers.sh: variables.sh must be sourced first" >&2
  return 1 2>/dev/null || exit 1
}

# get_tmux_option <name> [default]
get_tmux_option() {
  local name="$1" default="${2:-}" val
  val="$(tmux show-option -gqv "$name" 2>/dev/null)"
  if [ -z "$val" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# get_tmux_option_window <target> <name> [default]
get_tmux_option_window() {
  local target="$1" name="$2" default="${3:-}" val
  val="$(tmux show-option -wqv -t "$target" "$name" 2>/dev/null)"
  if [ -z "$val" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

# set_tmux_option_window <target> <name> <value>
set_tmux_option_window() {
  tmux set-option -w -q -t "$1" "$2" "$3"
}

# unset_tmux_option_window <target> <name>
unset_tmux_option_window() {
  tmux set-option -w -u -q -t "$1" "$2"
}

# set_tmux_option_global <name> <value>
set_tmux_option_global() {
  tmux set-option -g -q "$1" "$2"
}

# unset_tmux_option_global <name>
unset_tmux_option_global() {
  tmux set-option -g -u -q "$1"
}

# --- logging ---------------------------------------------------------------

_log_level_num() {
  case "$1" in
    error) echo 1 ;;
    warn)  echo 2 ;;
    info)  echo 3 ;;
    debug) echo 4 ;;
    *)     echo 2 ;;
  esac
}

_log_should_emit() {
  local msg_level="$1"
  local cfg; cfg="$(get_tmux_option "$OPT_LOG_LEVEL" "$DEFAULT_LOG_LEVEL")"
  [ "$(_log_level_num "$msg_level")" -le "$(_log_level_num "$cfg")" ]
}

_log_truncate_if_large() {
  local size
  if [ -f "$LOGFILE" ]; then
    size=$(wc -c < "$LOGFILE" 2>/dev/null | tr -d ' ')
    if [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ]; then
      : > "$LOGFILE"
    fi
  fi
}

_log() {
  local level="$1"; shift
  _log_should_emit "$level" || return 0
  _log_truncate_if_large
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$level" "$*" >> "$LOGFILE"
}

log_error() { _log error "$@"; }
log_warn()  { _log warn  "$@"; }
log_info()  { _log info  "$@"; }
log_debug() { _log debug "$@"; }
