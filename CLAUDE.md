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
  - `ctrl-f` — inside the Branch picker: force-refresh branches from remote (`git fetch --all`)
  - `prefix + r` — reload config
- Plugins: tpm, tmux-sensible, smart-splits.nvim (for Neovim pane navigation integration)

**`sessions/`** — Session and worktree management scripts. See `sessions/README.md` for full documentation.
- `common.sh` — shared utilities: `format_session_name`, `get_session_id`, `switch_or_create_session`, `update_score`, `sort_by_score`, `rename_worktree`, `add_worktree`, `pick_branch`
- `sessions.sh` (`C-S-s`) — unified fzf picker for sessions and projects:
  - `enter` — switch to session / open project
  - `ctrl-w` — create or checkout a worktree for the row's repo (opens branch picker)
  - `ctrl-d` — kill session + delete its linked worktree; on project rows deletes the linked worktree directly
  - `ctrl-x` — kill session only; row becomes a project entry
  - `ctrl-r` — rename: renames the git branch + moves directory for linked worktrees; renames tmux session otherwise
  - `?` — toggle preview pane

Repos are expected to follow a container/worktree layout: `~/Projects/org/repo/main/` and `~/Projects/org/repo/branch/` as siblings.

**`plugins/`** — Git-submodule-style local copies of tpm and tmux-sensible. Managed via tpm (`prefix + I` to install, `prefix + U` to update, `prefix + alt + u` to clean).
