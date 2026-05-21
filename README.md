# tmux-claude-session-manager

Per-window status indicators and a session picker for [Claude Code](https://claude.com/claude-code) sessions running inside tmux. A single bash daemon polls `claude agents --json` (Claude Code ≥ 2.1.139) and colors your window-names to show which Claude session is working, which needs your input, and which just finished.

## Features

- Window-name color flips automatically:
  - **yellow** while a Claude pane is working
  - **red** when it needs your input
  - **green** briefly when it finishes
- `prefix + j` opens an `fzf` popup listing all live Claude sessions on the tmux server. `Enter` jumps to the pane, `C-k` sends `C-c`, `C-l` sends `/clear`.
- `prefix + J` toggles the daemon on/off.
- Single bash daemon per tmux server. No external services. macOS + Linux.
- TPM-installable. Pure bash plus standard POSIX tools (`awk`, `ps`, `jq`).

## Requirements

- tmux ≥ 3.2 (for `display-popup`)
- claude ≥ 2.1.139 (for `claude agents --json`)
- `jq`
- `fzf` (optional; picker falls back to `display-menu` when missing)

## Install — TPM

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'cunderw/tmux-claude-session-manager'
```

Then `prefix + I` to install.

## Install — manual

```bash
git clone https://github.com/cunderw/tmux-claude-session-manager \
  ~/.tmux/plugins/tmux-claude-session-manager
echo 'run-shell ~/.tmux/plugins/tmux-claude-session-manager/claude_session_manager.tmux' \
  >> ~/.tmux.conf
tmux source ~/.tmux.conf
```

## Configuration

All options are tmux user options. Set them in `~/.tmux.conf` **before** loading the plugin.

| Option | Default | Purpose |
|---|---|---|
| `@claude-enabled` | `on` | Master switch. |
| `@claude-picker-key` | `j` | Picker keybind (used with prefix). |
| `@claude-toggle-key` | uppercase of picker key | Toggle daemon on/off. |
| `@claude-poll-interval` | `2` | Seconds between polls. |
| `@claude-color-busy` | `yellow` | Window-name color while busy. |
| `@claude-color-attn` | `red` | Color when input needed. |
| `@claude-color-done` | `green` | Color for done-linger. |
| `@claude-done-linger-ms` | `3000` | How long green persists after a session exits. |
| `@claude-log-level` | `warn` | `error \| warn \| info \| debug`. |

Show a session-count summary in `status-right`:

```tmux
set -g status-right '#{@claude-summary} | %H:%M'
```

The summary string looks like `2 busy, 1 attn` or is empty when no sessions exist.

## Diagnostics

Run the doctor for a read-only diagnostic report (deps, claude probe, daemon status, config):

```bash
~/.tmux/plugins/tmux-claude-session-manager/claude_session_manager.tmux doctor
```

Logs live at `$TMUX_TMPDIR/tmux-$UID-claude-session-manager.log` (default `/tmp/tmux-$UID/...`). Rotation is by truncation when the file exceeds 10 MB.

## How it works

1. The plugin's `.tmux` entry script binds the picker keys and starts a single background bash daemon, gated by a PID file in `$TMUX_TMPDIR`.
2. The daemon polls `claude agents --json` every `@claude-poll-interval` seconds.
3. For each session, the daemon walks the PPID chain from the Claude process up to a `pane_pid` reported by `tmux list-panes`, producing a session → window mapping.
4. The daemon writes `@claude-status=busy|attn|done` per window using `tmux set-option -w -q`.
5. The plugin's injected `window-status-format` reads `#{@claude-status}` and applies the configured color.
6. When the tmux server PID disappears, the daemon exits within one poll interval. No orphans.

The format injection saves the user's pristine `window-status-format` to `@claude-orig-window-status-format` on first load and always rebuilds from that, so TPM reloads are idempotent.

## Smoke checklist

Run before each release. (CI covers unit + integration; this verifies real tmux + claude integration.)

1. Fresh tmux, TPM install, no Claude running → status bar unchanged.
2. Start `claude` in one window → window-name turns yellow within 2 s.
3. Let Claude finish responding → window flips red.
4. `prefix + j` → fzf popup; Enter jumps; cursor lands on that pane.
5. `C-k` inside picker → sends `C-c` to the pane. After confirming quit, the window goes green for 3 s, then clears.
6. Quit tmux server → daemon exits; pidfile gone; no orphan `daemon.sh` in `ps aux`.
7. `claude_session_manager.tmux doctor` → all green.

## Development

```bash
bin/run_tests                                  # bats suite (unit + integration)
shellcheck scripts/*.sh claude_session_manager.tmux
```

Requires `bats-core`, `shellcheck`, `jq`, `fzf`, and `tmux` on PATH. On macOS: `brew install bats-core shellcheck jq fzf tmux`.

The design and the original implementation plan are in `docs/superpowers/`.

## License

MIT. See `LICENSE`.
