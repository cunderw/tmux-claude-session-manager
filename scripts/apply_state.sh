#!/usr/bin/env bash
# scripts/apply_state.sh
# State machine + tmux command emission for the daemon.
# Requires variables.sh and helpers.sh sourced.

# desired_state_for <claude_status_string>
desired_state_for() {
  case "$1" in
    busy) printf 'busy' ;;
    *)    printf 'attn' ;;
  esac
}

# merge_state <assoc_ref> <window_id> <state>
# Priority: attn > busy > done.
merge_state() {
  local -n _arr="$1"
  local win="$2" new="$3" cur="${_arr[$2]:-}"
  if [ -z "$cur" ]; then
    _arr[$win]="$new"; return
  fi
  case "$cur:$new" in
    attn:*)         _arr[$win]="$cur" ;;
    *:attn)         _arr[$win]="$new" ;;
    busy:*)         _arr[$win]="$cur" ;;
    *:busy)         _arr[$win]="$new" ;;
    *)              _arr[$win]="$cur" ;;
  esac
}

# write_summary <busy_count> <attn_count> <done_count>
write_summary() {
  local busy="$1" attn="$2" done_n="$3"
  local s=""
  [ "$busy" -gt 0 ] && s+="${busy} busy"
  if [ "$attn" -gt 0 ]; then
    [ -n "$s" ] && s+=", "
    s+="${attn} attn"
  fi
  if [ "$done_n" -gt 0 ]; then
    [ -n "$s" ] && s+=", "
    s+="${done_n} done"
  fi
  set_tmux_option_global "$OPT_SUMMARY" "$s"
}

# _now_ms — milliseconds since epoch (portable enough)
_now_ms() {
  # `date +%s%3N` works on GNU date; macOS date has no %N. Use python or perl
  # fallback. Plugin already depends on jq/awk; perl is universally present.
  perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)'
}

# reconcile_window_state <assoc_ref>
# Diffs the desired map against $STATEFILE, emits tmux set-option calls,
# manages done-linger expiry, and rewrites $STATEFILE.
reconcile_window_state() {
  local -n _desired="$1"
  local -A prev=()
  local -A prev_ts=()
  local linger_ms; linger_ms="$(get_tmux_option "$OPT_DONE_LINGER_MS" "$DEFAULT_DONE_LINGER_MS")"
  local now; now="$(_now_ms)"

  if [ -f "$STATEFILE" ]; then
    local w s t
    while read -r w s t; do
      [ -n "$w" ] || continue
      prev[$w]="$s"
      prev_ts[$w]="${t:-$now}"
    done < "$STATEFILE"
  fi

  local -A next=()

  # Sessions still live -> apply desired states.
  local win
  for win in "${!_desired[@]}"; do
    local target="${_desired[$win]}"
    if [ "${prev[$win]:-}" != "$target" ]; then
      set_tmux_option_window "$win" "$OPT_STATUS" "$target"
    fi
    next[$win]="$target $now"
  done

  # Windows in prev but not in desired -> done-linger logic.
  for win in "${!prev[@]}"; do
    if [ -z "${_desired[$win]:-}" ]; then
      local prev_state="${prev[$win]}"
      local ts="${prev_ts[$win]}"
      case "$prev_state" in
        done)
          if [ "$((now - ts))" -ge "$linger_ms" ]; then
            unset_tmux_option_window "$win" "$OPT_STATUS"
          else
            next[$win]="done $ts"
          fi
          ;;
        *)
          set_tmux_option_window "$win" "$OPT_STATUS" "done"
          next[$win]="done $now"
          ;;
      esac
    fi
  done

  # Rewrite state file.
  : > "$STATEFILE"
  for win in "${!next[@]}"; do
    printf '%s %s\n' "$win" "${next[$win]}" >> "$STATEFILE"
  done
}
