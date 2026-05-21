#!/usr/bin/env bash
# scripts/picker.sh
# Session picker: lists Claude sessions, dispatches jump/kill/clear actions.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"

# Action dispatch --------------------------------------------------------
if [ "${1:-}" = "--action" ]; then
  action="$2"; shift 2
  target=""
  while [ $# -gt 0 ]; do
    case "$1" in --target) target="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$target" ] || { echo "missing --target" >&2; exit 2; }
  case "$action" in
    jump)  tmux switch-client -t "$target" ;;
    kill)  tmux send-keys     -t "$target" C-c ;;
    clear) tmux send-keys     -t "$target" "/clear" Enter ;;
    *) echo "unknown action: $action" >&2; exit 2 ;;
  esac
  exit 0
fi

# Render mode (used by --render flag and inside the popup) --------------
render_lines() {
  # Print TAB-separated: target<TAB>display
  # display: "<short-id>  <status>  <cwd>"
  local panes_tmp pstree_tmp resolved_tmp pid_status_tmp
  panes_tmp="$(mktemp)"; pstree_tmp="$(mktemp)"
  resolved_tmp="$(mktemp)"; pid_status_tmp="$(mktemp)"
  trap 'rm -f "$panes_tmp" "$pstree_tmp" "$resolved_tmp" "$pid_status_tmp"' EXIT

  tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_id}.#{pane_id} #{pane_current_path}' > "$panes_tmp" 2>/dev/null || true
  ps -A -o pid=,ppid= > "$pstree_tmp" 2>/dev/null || true

  claude agents --json 2>/dev/null \
    | jq -r '.[] | "\(.pid)\t\(.sessionId)\t\(.status)\t\(.cwd)"' \
    > "$pid_status_tmp"

  cut -f1 "$pid_status_tmp" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes_tmp" "$pstree_tmp" > "$resolved_tmp"

  while IFS=$'\t' read -r pid sess status cwd; do
    [ -n "$pid" ] || continue
    # Mapper output column 4 is the full session:window_id.pane_id target.
    target="$(awk -v p="$pid" '$1==p {print $4; exit}' "$resolved_tmp")"
    [ -n "$target" ] || target="-"
    short="${sess:0:8}"
    printf '%s\t%s  %-6s  %s\n' "$target" "$short" "$status" "$cwd"
  done < "$pid_status_tmp"
}

if [ "${1:-}" = "--fzf-inner" ]; then
  sel="$(render_lines | fzf \
    --with-nth=2 \
    --delimiter=$'\t' \
    --header='Enter=jump  C-k=kill  C-l=clear  Esc=close' \
    --bind 'ctrl-k:execute(tmux send-keys -t {1} C-c)+abort' \
    --bind 'ctrl-l:execute(tmux send-keys -t {1} "/clear" Enter)+abort' \
    --expect=enter)"
  key="$(echo "$sel" | head -1)"
  line="$(echo "$sel" | sed -n 2p)"
  target="$(echo "$line" | cut -f1)"
  [ -n "$target" ] || exit 0
  case "$key" in
    enter|"") tmux switch-client -t "$target" ;;
  esac
  exit 0
fi

if [ "${1:-}" = "--render" ]; then
  render_lines
  exit 0
fi

# Interactive mode ------------------------------------------------------
if [ "${FZF_DISABLE:-0}" = "1" ] || ! command -v fzf >/dev/null 2>&1; then
  # display-menu fallback: build menu items, default action = jump.
  args=()
  while IFS=$'\t' read -r target display; do
    args+=( "$display" "" "run-shell '$PLUGIN_DIR/scripts/picker.sh --action jump --target $target'" )
  done < <(render_lines)
  if [ ${#args[@]} -eq 0 ]; then
    args+=( "(no claude sessions)" "" "" )
  fi
  tmux display-menu -T "#[align=centre] Claude Sessions " -x C -y C "${args[@]}"
  exit 0
fi

# fzf-in-popup path.
tmux display-popup -E -w 80% -h 60% -T " Claude Sessions " \
  "$PLUGIN_DIR/scripts/picker.sh --fzf-inner"
