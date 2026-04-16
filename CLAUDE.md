# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Reload Config

After editing `tmux.conf`, reload it inside a running tmux session:

```
prefix + r
```

Or from the shell:

```sh
tmux source-file ~/.config/tmux/tmux.conf
```

## Architecture

This is a personal tmux configuration with three main components:

**`tmux.conf`** — Main tmux configuration. Covers:
- Terminal: Ghostty (`xterm-ghostty`) with RGB, italics, strikethrough, and undercurl support
- Status bar: session name centered, date/time on the right
- Vi-mode copy with `pbcopy` integration
- Key bindings (all prefix-free unless noted):
  - `C-Tab` / `C-BTab` — next/previous window
  - `C-S-j/k/l/h` — split pane (down/up/right/left)
  - `C-S-x` — kill pane, `C-S-o` — kill all other panes
  - `C-S-r` — switch to last session
  - `C-S-s` — open session picker (`sessions/sessions.sh`)
  - `C-S-w` — open worktree manager (`sessions/worktree.sh`)
  - `prefix + r` — reload config
- Plugins: tpm, tmux-sensible, smart-splits.nvim (for Neovim pane navigation integration)

**`sessions/`** — Session and worktree management scripts. See `sessions/README.md` for full documentation.
- `common.sh` — shared utilities sourced by the other two scripts: `format_session_name`, `get_session_id`, `switch_or_create_session`, `update_score`, `sort_by_score`
- `sessions.sh` (`C-S-s`) — fzf session picker; discovers git repos via `fd`, ranks them by recency (7-day half-life decay), supports manually configured entries (`MANUAL_SESSIONS` array with `name:path` format)
- `worktree.sh` (`C-S-w`) — fzf worktree manager; lists worktrees for the current project with `Enter` (switch), `Ctrl-D` (delete), `Ctrl-R` (rename) actions and a `[+ new worktree]` entry

Repos are expected to follow a container/worktree layout: `~/Projects/org/repo/main/` and `~/Projects/org/repo/branch/` as siblings.

**`plugins/`** — Git-submodule-style local copies of tpm and tmux-sensible. Managed via tpm (`prefix + I` to install, `prefix + U` to update, `prefix + alt + u` to clean).
