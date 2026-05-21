#!/usr/bin/env bash
# scripts/tick.sh
# One iteration of the daemon poll loop.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/apply_state.sh"

if ! command -v claude >/dev/null 2>&1; then
  log_warn "claude CLI not on PATH; skipping tick"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log_error "jq not on PATH; cannot parse JSON"
  exit 0
fi

# Capture JSON (single fork).
json_tmp="$(mktemp)"
trap 'rm -f "$json_tmp"' EXIT
if ! claude agents --json > "$json_tmp" 2>/dev/null; then
  log_warn "claude agents --json failed; keeping last state"
  exit 0
fi
if ! jq -e . "$json_tmp" >/dev/null 2>&1; then
  log_warn "claude agents --json returned non-JSON; keeping last state"
  exit 0
fi

# Snapshot panes.
panes_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp"' EXIT
tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_id}.#{pane_id} #{pane_current_path}' > "$panes_tmp" 2>/dev/null || true

# Snapshot pstree.
pstree_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp" "$pstree_tmp"' EXIT
ps -A -o pid=,ppid= > "$pstree_tmp" 2>/dev/null || true

# Parse PIDs + statuses from JSON.
pid_status_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp" "$pstree_tmp" "$pid_status_tmp"' EXIT
jq -r '.[] | "\(.pid)\t\(.status)"' "$json_tmp" > "$pid_status_tmp"

# Resolve each PID to a window via mapper.
resolved_tmp="$(mktemp)"
trap 'rm -f "$json_tmp" "$panes_tmp" "$pstree_tmp" "$pid_status_tmp" "$resolved_tmp"' EXIT
cut -f1 "$pid_status_tmp" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes_tmp" "$pstree_tmp" > "$resolved_tmp"

# Build desired map: window_id -> state.
declare -A desired=()
busy=0; attn=0
while IFS=$'\t' read -r pid status; do
  [ -n "$pid" ] || continue
  win="$(awk -v p="$pid" '$1==p {print $2; exit}' "$resolved_tmp")"
  [ -n "$win" ] || { log_debug "no pane for pid $pid"; continue; }
  state="$(desired_state_for "$status")"
  merge_state desired "$win" "$state"
done < "$pid_status_tmp"

# Counts for summary.
for s in "${desired[@]}"; do
  case "$s" in
    busy) busy=$((busy+1)) ;;
    attn) attn=$((attn+1)) ;;
  esac
done

reconcile_window_state desired
write_summary "$busy" "$attn" 0
