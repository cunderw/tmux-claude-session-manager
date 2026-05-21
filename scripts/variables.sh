#!/usr/bin/env bash
# scripts/variables.sh
# Single source of truth for option names, defaults, and runtime paths.
# Constants here are sourced and read by other scripts (helpers, daemon,
# tick, apply_state, picker, doctor, entry). Shellcheck can't see across
# files, so disable SC2034 for this declarations-only file.
# shellcheck disable=SC2034

OPT_ENABLED="@claude-enabled"
OPT_PICKER_KEY="@claude-picker-key"
OPT_POLL_INTERVAL="@claude-poll-interval"
OPT_COLOR_BUSY="@claude-color-busy"
OPT_COLOR_ATTN="@claude-color-attn"
OPT_COLOR_DONE="@claude-color-done"
OPT_DONE_LINGER_MS="@claude-done-linger-ms"
OPT_LOG_LEVEL="@claude-log-level"
OPT_STATUS="@claude-status"
OPT_SUMMARY="@claude-summary"

DEFAULT_ENABLED="on"
DEFAULT_PICKER_KEY="j"
DEFAULT_POLL_INTERVAL="2"
DEFAULT_COLOR_BUSY="yellow"
DEFAULT_COLOR_ATTN="red"
DEFAULT_COLOR_DONE="green"
DEFAULT_DONE_LINGER_MS="3000"
DEFAULT_LOG_LEVEL="warn"

_state_dir="${TMUX_TMPDIR:-/tmp}"
_uid="$(id -u)"
PIDFILE="${_state_dir}/tmux-${_uid}-claude-session-manager.pid"
LOGFILE="${_state_dir}/tmux-${_uid}-claude-session-manager.log"
STATEFILE="${_state_dir}/tmux-${_uid}-claude-session-manager.state"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"   # 10 MB
