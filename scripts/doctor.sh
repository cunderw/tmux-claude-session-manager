#!/usr/bin/env bash
# scripts/doctor.sh
# Read-only diagnostics for tmux-claude-session-manager.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/variables.sh"
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/helpers.sh"

green() { printf '\033[32m%s\033[0m' "$1"; }
yellow() { printf '\033[33m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
ok()    { green "OK"; }
miss()  { red "MISSING"; }

EXIT=0

echo "tmux-claude-session-manager — doctor"
echo

# --- deps -------------------------------------------------------------
echo "[deps]"
check() {
  local name="$1" cmd="$2" required="$3" version_cmd="${4:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local ver=""
    [ -n "$version_cmd" ] && ver="$(eval "$version_cmd" 2>/dev/null | head -1)"
    printf '  %-9s %s %s\n' "$name" "$(ok)" "$ver"
  else
    printf '  %-9s %s\n' "$name" "$(miss)"
    [ "$required" = "1" ] && EXIT=1
  fi
}
check claude  claude 1 "claude --version"
check tmux    tmux   1 "tmux -V"
check jq      jq     1 "jq --version"
check fzf     fzf    0 "fzf --version"
check awk     awk    1 ""
check ps      ps     1 ""
echo

# --- claude probe -----------------------------------------------------
echo "[claude probe]"
if command -v claude >/dev/null 2>&1; then
  start_ns="$(perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000000)')"
  json="$(claude agents --json 2>/dev/null || echo '[]')"
  end_ns="$(perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000000)')"
  count="$(echo "$json" | jq 'length' 2>/dev/null || echo 0)"
  ms=$(( (end_ns - start_ns) / 1000 ))
  printf '  %d sessions in %d ms\n' "$count" "$ms"
else
  echo "  (skipped — claude not on PATH)"
fi
echo

# --- daemon -----------------------------------------------------------
echo "[daemon]"
if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "  Running (pid $pid)"
  else
    echo "  Stale pidfile: $PIDFILE (pid $pid not alive)"
  fi
else
  echo "  Not running (no pidfile at $PIDFILE)"
fi
echo

# --- config -----------------------------------------------------------
echo "[config]"
for opt in "$OPT_ENABLED" "$OPT_PICKER_KEY" "$OPT_POLL_INTERVAL" \
           "$OPT_COLOR_BUSY" "$OPT_COLOR_ATTN" "$OPT_COLOR_DONE" \
           "$OPT_DONE_LINGER_MS" "$OPT_LOG_LEVEL"; do
  val="$(get_tmux_option "$opt" "(default)")"
  printf '  %-30s %s\n' "$opt" "$val"
done

exit "$EXIT"
