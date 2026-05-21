# CLAUDE.md

Project context for AI coding assistants working in this repo. End-user docs are in `README.md`; this file is for working *on* the plugin.

## What this is

A tmux plugin: a TPM-installable `*.tmux` entry + helper bash scripts that poll `claude agents --json`, map each Claude process back to its tmux pane, and indicate session state on per-window status-bar entries. macOS + Linux.

## Architecture (one paragraph per piece)

- `claude_session_manager.tmux` — TPM entry point **and** CLI dispatcher (`doctor` / `picker` / `toggle` subcommands). Binds keys, injects the window-status format, and spawns the daemon once.
- `scripts/daemon.sh` — single long-lived bash loop. Polls `claude agents --json` every `@claude-poll-interval` seconds. One instance per tmux server, gated by a PID file in `$TMUX_TMPDIR`. Exits within one poll interval when the tmux server PID dies.
- `scripts/tick.sh` — one iteration of the poll loop. Wires JSON → mapper → state machine → tmux options.
- `scripts/map_pid_to_pane.sh` — batch awk-based PPID walker. Input: PIDs on stdin + a panes file + a pstree file. Output: `pid<TAB>window_id<TAB>pane_id<TAB>full_target`.
- `scripts/apply_state.sh` — state machine + reconcile-against-statefile. `desired_state_for`, `merge_state`, `reconcile_window_state`, `write_summary`. Manages the done-linger.
- `scripts/picker.sh` — `display-popup` + `fzf` picker. Falls back to `display-menu` when `fzf` is missing. Action dispatch: `--action jump|kill|clear --target <session:window.pane>`.
- `scripts/doctor.sh` — read-only diagnostics. Must not call `set-option`.
- `scripts/helpers.sh` + `scripts/variables.sh` — option I/O, logging, shared constants.

**The daemon writes per-window options; the window-status format reads them.** Do not put `#(shell)` calls in `window-status-format` — they execute on every status redraw and can stall the status line.

## Conventions

- Pure bash (`#!/usr/bin/env bash`). No Python/Ruby/Go.
- bash 4+ required (`declare -A`, `local -n`). On macOS, `/bin/bash` is 3.2 — users need `brew install bash`. CI installs brew bash explicitly and prepends it to `PATH` before running tests.
- shellcheck warning-clean. `variables.sh` has a file-level `# shellcheck disable=SC2034` because its constants are sourced and used by other scripts that shellcheck can't see.
- `bin/run_tests` runs all bats tests (unit + integration). Stubs live in `tests/stubs/`; fixtures in `tests/fixtures/`; common setup in `tests/helper.bash`.
- One logical change per commit. Conventional-commits messages (`feat`, `fix`, `chore`, `docs`, `test`, `ci`).
- `git add` by exact path. Never `git add .` or `git add -A` — past parallel work has shown how easily that picks up other agents' files.

## Gotchas worth knowing before you change something

- **PPID walk is the only reliable claude→pane mapping.** Don't try `pane_current_command`: claude renames its process to the version string (e.g. `2.1.146`), not `claude`.
- **`$(...)` waits for *all* inherited FDs to close, not just the child.** When a bats helper backgrounds a daemon (`( cmd & echo $! )`), the command substitution hangs until the daemon dies. Redirect the child's stdout/stderr (`>/dev/null 2>&1`) inside the helper. The production launch path already redirects.
- **Test stubs must not modify shared files.** A per-test override of `tests/stubs/tmux` belongs in `$BATS_TEST_TMPDIR/override/tmux` with `PATH="$override_dir:$PATH"`. Never rewrite the committed stub in `setup`/`teardown` — it leaves a dirty working tree on every run and causes subtle drift.
- **Format injection is idempotent via a saved-original option.** First load: stash the pristine `window-status-format` in `@claude-orig-window-status-format`; subsequent injections rebuild from that. Don't try to "strip" prior injections with parameter expansion — fragile and order-dependent.
- **Themed window-status formats (powerkit/tokyo-night/catppuccin) explicitly recolor every segment.** A leading `#[fg=COLOR]` directive gets overridden by the theme's own directives. The indicator uses a glyph (`●`) injected *after* `#W` so it inherits the segment's themed background; configurable via `@claude-indicator-position`.
- **The state machine treats anything non-`busy` as `attn`.** Forward-compat for unknown future claude statuses. Only `busy` is confirmed live; release notes mention `idle` and `completed` but they haven't been observed in `--json` yet.
- **Daemon lifecycle hinges on `kill -0` against the tmux server PID.** The daemon receives that PID as `$1` and probes it each loop. Don't add a fallback that keeps the daemon alive without that signal — orphan daemons are worse than missing indicators.

## When making changes

1. **TDD first.** Add or update a `tests/unit` or `tests/integration` bats test that captures the new behavior. Run it red.
2. Implement the smallest change that turns it green.
3. Run `bin/run_tests` (must be 51+/51+ green) and `shellcheck -S warning scripts/*.sh claude_session_manager.tmux` (must be clean).
4. Commit. Push only when intentional — main is the deployed branch (TPM users get every push via `prefix + U`).

## Files of record

- Design spec: `docs/superpowers/specs/2026-05-21-tmux-claude-session-manager-design.md`
- Implementation plan: `docs/superpowers/plans/2026-05-21-tmux-claude-session-manager.md`
  - Deviations from the plan are documented in the bodies of commits `06c6b6a` (stub isolation), `114166c` (daemon test helper redirect), and `451a659` (indicator placement). Read those before "fixing" the plan to match.
