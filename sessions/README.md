# sessions/

Scripts that power the tmux session and worktree pickers.

## Files

| File | Triggered by | Purpose |
|------|-------------|---------|
| `common.sh` | (sourced) | Shared constants and utility functions |
| `sessions.sh` | `C-S-s` | Session picker with recency ranking |
| `worktree.sh` | `C-S-w` | Git worktree manager |

---

## sessions.sh

Opens a bottom fzf popup listing tmux-ready locations: git repos under
`~/Projects/` and `$XDG_CONFIG_HOME`, plus any manually configured entries.
Picking one switches to an existing tmux session or creates a new one.

### Manual sessions

Defined at the top of `sessions.sh` as `"name:path"` pairs:

```bash
MANUAL_SESSIONS=(
  "Notes:$HOME/Notes"   # session name : working directory
  "default:$HOME"
)
```

`name` becomes both the fzf label and the tmux session name.  
`path` sets the session's working directory.

### Session ranking

Every pick increments a score stored in `~/.local/share/tmux-sessions/scores.tsv`.
Scores decay with a 7-day half-life so recently used sessions float to the top:

```
score_at_time_t = stored_score × e^(−ln2 × elapsed_seconds / 604800)
```

Each selection adds 1 to the decayed current score. The TSV columns are:
`session_name`, `score`, `unix_timestamp`.

---

## worktree.sh

Opens a bottom fzf popup listing all git worktrees for the current project.
If the active pane is not inside a git repo, a project picker runs first.

### Repo layout convention

Repos are expected to follow the container/worktree structure:

```
~/Projects/my-org/my-repo/
    main/          ← main branch checkout
    feat-login/    ← git worktree add
    fix-bug/       ← git worktree add
```

`my-repo/` is the *container*. Each subdirectory is a separate worktree.

### Key bindings inside the worktree picker

| Key | Action |
|-----|--------|
| `Enter` | Switch to (or create) a tmux session for the worktree |
| `Ctrl-D` | Delete the worktree and kill its tmux session |
| `Ctrl-R` | Rename the branch, directory, and session |

Selecting `[+ new worktree]` opens a branch picker.  Local branches and
remote-only branches (prefixed `origin/`) are listed.  Choosing
`[+ new branch]` prompts for a name and branches from the repo's default
remote branch.

---

## common.sh

### format_session_name

Derives a short tmux session name from a filesystem path:

1. Strip `~/Projects/ghe.siriusxm.com/` (work GHE prefix)
2. Strip `~/Projects/` (personal projects prefix)
3. Abbreviate `/Users/cesar.enrique` → `~`
4. Replace `.` → `_` (e.g. `github.com` → `github_com`)

### switch_or_create_session

Takes a working directory and an optional explicit session name.  Uses session
IDs (not names) for all tmux targeting to avoid tmux misinterpreting `/` inside
session names as the `session:window` separator.

### update_score / sort_by_score

`update_score(name)` decays the stored score then adds 1.  
`sort_by_score` reads `session_name\tcwd` lines from stdin, scores each by its
decayed value, and outputs them sorted highest-first.
