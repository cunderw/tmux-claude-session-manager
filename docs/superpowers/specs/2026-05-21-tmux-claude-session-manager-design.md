# tmux-claude-session-manager — Design

- **Date:** 2026-05-21
- **Status:** Draft, pending implementation plan
- **Owner:** carson.underwood@wwt.com
- **Repo:** `/Users/underwoc/Dev/cunderw/tmux-claude-session-manager`

## Problem

When running multiple Claude Code sessions across tmux windows it is hard to
tell, at a glance, which session is working, which is waiting for input, and
which has finished. Today this requires switching to each window and reading
its pane. A tmux-native indicator system plus a quick session picker would
remove the friction.

Claude Code 2.1.139+ exposes `claude agents --json`, a stable, scriptable
listing of live sessions. This makes a pure-tmux plugin solution viable
without instrumenting Claude itself.

## Goals

- Per-window status indicator (color of the window-name in the tmux status
  bar) that updates within ~2 seconds of a state change.
- A picker (popup + fzf) listing all live Claude sessions on the tmux server,
  with secondary actions for jump / kill / send `/clear`.
- TPM-installable, single-instance per tmux server, runs on macOS and Linux,
  bash + standard POSIX tools only.
- A `doctor` subcommand for diagnosing setup issues.

## Non-goals

- Cross-host / multi-server aggregation. One tmux server per daemon.
- Persistence across tmux server restarts. State is rebuilt from
  `claude agents --json` on startup.
- Modifying Claude's behavior or wrapping the CLI. We only read its JSON.
- Nerd Font glyphs or rich rendering. v1 is color-only window-name highlight.
- Pane-content scraping to detect permission prompts. v1 trusts the JSON
  `status` field; pane scraping is a future enhancement if the field proves
  insufficient.

## Architecture

```
                                                  +--------------------+
                                                  |  claude agents     |
                                                  |  --json            |
                                                  |  (CLI, ~250-340ms) |
                                                  +---------+----------+
                                                            |
                                                            | poll every ~2s
                                                            v
+----------------+   spawn-once   +-----------------------------------------------------+
|  *.tmux entry  |--------------->|        daemon.sh (long-lived bash loop)             |
|  (TPM entry)   |  pidfile lock  |  - reads JSON                                        |
+----------------+                |  - builds {pane_pid -> pane_id} from list-panes      |
       |                          |  - walks PPID chain per claude pid -> pane           |
       | bind keys, set           |  - maps status -> busy|attn|done                     |
       | format vars              |  - tmux set-option -wq -t <window> @claude-status X  |
       v                          |  - tmux set-option -gq @claude-summary "..."         |
+---------------------+           +---------------------+--------------------------------+
| status-bar reads:   |                                 |
|   #{@claude-status} | <-- per-window state -----------+
|   #{@claude-summary}| <-- session-count summary ------+
+---------------------+
       |
       | user hits @claude-picker-key (default: prefix + j)
       v
+---------------------+
| display-popup + fzf |
|  Enter -> switch    |
|  C-k   -> kill      |
|  C-l   -> /clear    |
+---------------------+
```

**Key invariants:**

- Only the daemon writes `@claude-status` / `@claude-summary`. All other
  scripts and format strings only read them.
- The daemon is single-instance per tmux server. A PID file in
  `$TMUX_TMPDIR` (default `/tmp/tmux-$UID`) gates startup.
- The daemon exits within one poll interval when the tmux server PID dies,
  via `kill -0` probing.
- No `#(shell)` substitutions in the hot path. Format strings stay pure
  tmux to avoid blocking the status line on slow shells.

## File layout

```
tmux-claude-session-manager/
├── claude_session_manager.tmux          # TPM entry point (executable)
│                                        # - sources helpers
│                                        # - sets default @claude-* options
│                                        # - binds picker key
│                                        # - injects status format vars
│                                        # - starts daemon (run-shell -b)
│                                        # - also serves as CLI: `... doctor`
│
├── scripts/
│   ├── helpers.sh                       # get/set_tmux_option, log
│   ├── variables.sh                     # @claude-* option names + defaults
│   ├── daemon.sh                        # long-lived poll loop
│   ├── tick.sh                          # one iteration of the poll loop
│   ├── map_pid_to_pane.sh               # batch awk-based PPID walker
│   ├── apply_state.sh                   # tmux set-option calls; clears stale
│   ├── picker.sh                        # fzf list + key bindings
│   └── doctor.sh                        # diagnostics
│
├── tests/
│   ├── unit/
│   │   ├── test_map_pid_to_pane.bats
│   │   ├── test_state_machine.bats
│   │   └── test_tick.bats
│   ├── integration/
│   │   ├── test_daemon_lifecycle.bats
│   │   └── test_picker.bats
│   ├── stubs/                            # stub binaries for claude/ps/tmux
│   └── fixtures/                         # sample JSON + ps + list-panes outputs
│
├── README.md                             # install (TPM + manual), config, screenshots
├── LICENSE                               # MIT
└── .github/workflows/test.yml            # bats-core CI on macOS + Ubuntu
```

## Configuration (tmux options)

| Option | Default | Description |
|---|---|---|
| `@claude-enabled` | `on` | Master switch. `off` makes the plugin a no-op. |
| `@claude-picker-key` | `j` | Picker keybind (prefix-prefixed). |
| `@claude-poll-interval` | `2` | Seconds between `claude agents --json` polls. |
| `@claude-color-busy` | `yellow` | Window-name color while a session is busy. |
| `@claude-color-attn` | `red` | Window-name color when any session needs input. |
| `@claude-color-done` | `green` | Window-name color during done-linger. |
| `@claude-done-linger-ms` | `3000` | How long the done state persists after a session exits. |
| `@claude-log-level` | `warn` | `error|warn|info|debug`. |

## Data flow (one poll iteration in `tick.sh`)

1. `JSON   = claude agents --json` (one fork, ~250-340 ms).
2. `PANES  = tmux list-panes -a -F '#{pane_pid} #{session_name}:#{window_id}.#{pane_id}'`.
3. `PSTREE = ps -A -o pid=,ppid=`.
4. For each session in JSON:
   - Resolve `session.pid` to a `window_id` via `map_pid_to_pane` (one awk
     pass for the whole batch).
   - Compute `desired_state` for the session.
5. Diff against previous tick:
   - New appearances + state transitions → `tmux set-option -wq -t @<window_id> @claude-status <state>`.
   - Sessions that disappeared from JSON → enter "done linger" (see state
     machine).
   - Unchanged → no tmux call (debounce).
6. `sleep $poll_interval`, loop.

## State machine

Per-session state:

```
                         claude --json says "busy"
            +---------------------+
            v                     |
        +-------+              +-------+
        | busy  | --not busy-->| attn  |
        +-------+              +-------+
            ^                     |
            |--claude --json says-+
            |  "busy" again
            |
   (any) ---|
            |
            v   session disappears from JSON
        +-------+   linger=3s    +---------+
        |  done | --------------> (unset)
        +-------+                 (no color)
```

Mapping:

- `busy` ⇢ `@claude-status=busy` ⇢ yellow window-name color.
- Any other live status (`idle`, `completed`, anything non-`busy`) ⇢
  `@claude-status=attn` ⇢ red. Forward-compat: any unknown status string is
  treated as `attn`, on the assumption that anything not "Claude is
  working" deserves the user's eye.
- Session removed from JSON (process exited) ⇢ `@claude-status=done` for
  `@claude-done-linger-ms`, then `set-option -wu` (unset) ⇢ window
  returns to default color.

**Multiple Claude sessions in one window:** the indicator is window-keyed.
Take the highest-priority state across all sessions mapped to that window,
where priority is `attn > busy > done`. If any session needs you, the
window flags red.

**Status-bar summary variable (`@claude-summary`):** the daemon writes a
single global option such as `2 busy, 1 attn` (empty when no sessions).
Users opt in by adding `#{@claude-summary}` to their `status-right`.

## Lifecycle

### Startup

```bash
PIDFILE="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)-claude-session-manager.pid"

start_daemon() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    return 0   # already running
  fi
  rm -f "$PIDFILE"
  TMUX_PID="$(tmux display-message -p '#{pid}')"
  ( nohup "$CURRENT_DIR/scripts/daemon.sh" "$TMUX_PID" \
      >> "${TMUX_TMPDIR:-/tmp}/tmux-claude-session-manager.log" 2>&1 & echo $! > "$PIDFILE" )
}
[ "$(get_tmux_option @claude-enabled on)" = "on" ] && start_daemon
```

- Single instance per tmux server: PID file keyed on UID + `TMUX_TMPDIR`
  (per-server).
- TPM reload (`prefix + I`) re-runs `.tmux`; `start_daemon` is a no-op if
  already running.

### Daemon loop

`daemon.sh` sources `variables.sh` so `$PIDFILE` resolves to the same path
used by the startup function (avoiding a second argument and keeping the
contract in one place):

```bash
source "$CURRENT_DIR/scripts/variables.sh"   # defines PIDFILE, LOGFILE, etc.

TMUX_PID="$1"
trap 'rm -f "$PIDFILE"; exit 0' TERM INT EXIT

while :; do
  kill -0 "$TMUX_PID" 2>/dev/null || break
  "$CURRENT_DIR/scripts/tick.sh" || true
  sleep "$(get_tmux_option @claude-poll-interval 2)"
done
```

- Daemon exits within one poll interval after the tmux server dies. No
  orphans.
- `EXIT` trap removes the PID file so a new tmux server can start cleanly.
- `tick.sh` failures are caught (`|| true`); the loop survives bad ticks.

### Error handling

| Failure | Detection | Behavior |
|---|---|---|
| `claude` not in PATH | `command -v claude` | Log once per daemon lifetime, skip ticks. |
| `claude agents --json` non-zero or non-JSON | `jq -e .` | Warn, skip tick, keep last known state. |
| `claude` version < 2.1.139 | startup probe | Log error, daemon exits, plugin is a no-op. |
| PPID walk fails (docker/ssh PID-ns) | walker prints nothing | Skip that session; don't set/unset its window. |
| Window option set on a vanished window | tmux returns non-zero | Silently ignored — benign race with window close. |

### Logging

- File at `${TMUX_TMPDIR}/tmux-claude-session-manager.log`.
- Format: `<iso-timestamp> <level> <message>`.
- Soft cap at 10 MB: the daemon truncates when exceeded. No rotation.

### Manual controls

- `prefix + j` — open picker.
- `prefix + J` — toggle `@claude-enabled`; daemon stops or starts.

All other actions live inside the picker.

## Doctor script

`scripts/doctor.sh`, invoked via `claude_session_manager.tmux doctor` or
from the picker with `?`. Read-only; no `set-option` calls. Reports:

- **deps:** `claude`, `tmux`, `jq` (required), `fzf` (optional), `ps`/`awk`.
- **claude probe:** runs `claude agents --json`, reports timing and one
  sample session.
- **tmux server:** TMUX_PID, TMUX_TMPDIR, status-interval, display-popup
  support.
- **daemon:** PID file path, running status, last-tick age, recent errors,
  log size.
- **mapping:** for each session in JSON, the resolved tmux pane (or the
  reason it failed: docker / ssh namespace, etc).
- **window state:** every window with `@claude-status` set and the value.
- **config:** the current values of all `@claude-*` options.
- **suggestions:** if `status-interval > @claude-poll-interval`, suggest
  lowering it; if `#{@claude-summary}` isn't in `status-right`, suggest
  adding it.

## Testing

### bats-core

The pure-bash convention for tmux plugins; works on macOS + Linux without
node/npm.

### Unit tests (`tests/unit/`)

- `test_map_pid_to_pane.bats`
  - Single PPID hop, multi-hop ancestry, missing ancestor
    (docker/ssh case), recursion cap, batched resolution.
- `test_state_machine.bats`
  - `busy` → busy; non-busy live → attn; vanished → done for linger; linger
    expiry → unset; multi-session priority rule.
- `test_tick.bats`
  - Stubs `claude`, `ps`, `tmux` and asserts emitted commands.
  - Asserts no calls when nothing changed.

Stubs live in `tests/stubs/` (prepended to `PATH` in test setup). Each stub
reads fixture content from `$STUB_FIXTURE`.

### Integration tests (`tests/integration/`)

- `test_daemon_lifecycle.bats`
  - First `.tmux` invocation starts daemon and writes pidfile.
  - Second is a no-op.
  - Stale pidfile (process gone) is cleaned and daemon starts.
  - Daemon exits within poll interval when fake tmux PID disappears.
  - TPM reload does not double-spawn.
- `test_picker.bats`
  - `display-popup` fallback to `display-menu` when fzf missing.
  - Enter → `switch-client`. C-k → `send-keys C-c`. C-l → `send-keys
    "/clear" Enter`.

Integration tests spin up a real tmux server on `tmux -L test-socket`
inside a temp `TMUX_TMPDIR`, then assert on `tmux show-options` state.

### CI

`.github/workflows/test.yml`:

- Matrix: `ubuntu-latest` × `macos-latest` × tmux `3.2` / `3.3` / `3.4` /
  `latest`.
- Installs bats, jq, fzf, tmux at pinned versions.
- Stubs `claude` (binary not in CI) for unit + integration.
- Lints with `shellcheck`.

### Manual smoke checklist

Run before each release; documented in `README.md`:

1. Fresh tmux, TPM install, no Claude running → status bar unchanged.
2. Start `claude` in one window → window-name turns yellow within 2 s.
3. Let Claude finish responding → window flips red.
4. `prefix + j` → fzf popup; Enter jumps; cursor lands on that pane.
5. `C-k` inside picker → sends `C-c` to the pane (initiates Claude's quit
   flow). After the user confirms quit in their pane, the session
   disappears from `claude agents --json`, the window goes green for 3 s,
   then clears.
6. Quit tmux server → daemon exits; pidfile gone; no orphan `daemon.sh` in
   `ps aux`.
7. `claude_session_manager.tmux doctor` → all green.

### Intentionally untested

- Exact bytes of fzf's UI.
- Real Claude status transitions (mocked in JSON; real-world drift is
  covered by manual smoke).
- Pixel-accurate colors. We assert the option value; rendering is tmux's
  problem.

## Open questions / future work

- **Confirm full `status` value set.** Only `busy` has been observed live;
  release notes imply `idle` and `completed`/`done` exist. The forward-compat
  rule covers us, but a known list would let us refine UX (e.g. blink on
  `idle`).
- **Pane-content scraping for permission prompts.** If `status` alone
  proves insufficient (e.g. Claude is `busy` but blocked on a tool-approval
  prompt that needs the user), add an opt-in `capture-pane` scan for known
  prompt markers.
- **Persistent session history.** Currently state is in-memory only. A
  `~/.local/state/tmux-claude-session-manager/recent.json` could power a
  "recent sessions" view for `claude --resume`.
- **Cross-server aggregation.** Out of scope for v1; revisit if users
  request it.

## Acceptance criteria

A v1 release ships when:

- TPM install on macOS + Ubuntu works with default config.
- All bats tests pass on both OSes in CI across pinned tmux versions.
- The 7-step manual smoke passes against a real `claude` ≥ 2.1.139.
- `doctor` returns a green report against the smoke environment.
- README documents install, all `@claude-*` options, the keybinds, and the
  smoke checklist.
