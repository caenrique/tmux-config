# sessions/

Scripts powering the tmux session and worktree picker.

| File | Triggered by | Purpose |
|------|-------------|---------|
| `common.sh` | (sourced) | Shared utilities, scoring, project discovery, git-worktree helpers |
| `sessions.sh` | `C-S-s` | Unified session + project picker with full worktree management |
| `fetch_reload.sh` | (internal) | Background `git fetch --all` + fzf spinner/reload helper |

---

## Flow diagram

```

                                  ┌───────────────────────────────────────────────────────────────────┐
                                  │  Enter ───────▶  ⚡ → switch-client                               │
                                  │             ──▶  📂 → create session + switch                     │
                                  │             ──▶  ✨ → name prompt → create at ~                   │
                                  ├───────────────────────────────────────────────────────────────────┤
                                  │  ctrl-w ──────▶  ┌─────────────────────────────────────────────┐  │
                                  │                  │                 pick_branch                 │  │
                                  │                  │  local branches + remote-only               │  │
                                  │                  │  ctrl-f ──▶ fetch_reload.sh  ↺ reload       │  │
           ┌─────────────────┐    │                  └─────────────────────────────────────────────┘  │
           │   fzf popup     │    │  new:<name>         ──▶ add_worktree -b ──┐                       │
           │  ─────────────  │    │  existing:<branch>  ──▶ add_worktree ─────┴──▶ switch             │
C-S-s ───▶ │  ⚡ sessions    │───▶├───────────────────────────────────────────────────────────────────┤
           │  📂 projects    │    │  ctrl-d ──────▶  ⚡: kill session ──▶ linked WT? ──yes──▶ rm WT   │
           │  ✨ sentinel    │    │                                                 └──no──▶ done     │
           └─────────────────┘    │             ──▶  📂: linked WT? ──yes──▶ rm WT                    │
                                  │                                └──no──▶ ⚠ not a WT                │
                                  ├───────────────────────────────────────────────────────────────────┤
                                  │  ctrl-x ──────▶  ⚡: kill only → row becomes 📂                   │
                                  ├───────────────────────────────────────────────────────────────────┤
                                  │  ctrl-r ──────▶  linked WT? ──yes──▶ rename_worktree              │
                                  │                            │       (branch + dir + repair)        │
                                  │                            ├─ no (⚡) ──▶ tmux rename-session     │
                                  │                            └─ no (📂) ──▶ ⚠ not a WT              │
                                  └───────────────────────────────────────────────────────────────────┘
```

---

## sessions.sh

Opens a full-screen fzf popup with a unified, ranked list:

- **Running sessions** — highlighted green, sorted by recency. The previously active session is always pinned at the top.
- **Unopen projects** — git repos under `~/Projects/` and `$XDG_CONFIG_HOME`, plus any `MANUAL_SESSIONS` entries, sorted by recency below.

### Key bindings

| Key | On a session row | On a project row | On the sentinel |
|-----|------------------|------------------|-----------------|
| `Enter` | Switch to session | Create session and switch | Prompt for name → create session at `~` |
| `Ctrl-W` | Open branch picker → create/checkout worktree | Same | — |
| `Ctrl-D` | Kill session + delete linked worktree (background, no prompt) | Delete linked worktree; for orphaned dirs (parent has another git repo) shows an fzf confirm prompt; ⚠ message otherwise | — |
| `Ctrl-X` | Kill session; entry moves to project section | — | — |
| `Ctrl-R` | Rename worktree (branch+dir) if linked; rename session otherwise | Rename linked worktree; ⚠ message if not a worktree | — |
| `Ctrl-BS` / `Esc` | Close picker | Close picker | Close picker |

`Ctrl-X` uses `execute-silent + reload` — runs silently while the popup stays open. `Ctrl-D` and `Ctrl-R` use `execute + reload` (need terminal access: `Ctrl-D` may show an orphaned-dir fzf confirm prompt; `Ctrl-R` shows the inline rename prompt).

### How in-place actions work

`manage_sessions` writes the initial list to a temp file once at startup. Each mutating binding calls back into `sessions.sh --action <name>` as a subprocess, which modifies the temp file atomically, then fzf reloads from it:

```
ctrl-x  →  execute-silent(sessions.sh --action ctrl-x …)
        +  reload(cat tmpfile)
        +  pos({n})            ← restore cursor to same position

ctrl-d  →  execute(sessions.sh --action ctrl-d …)   ← may show orphaned-dir confirm
        +  reload(cat tmpfile)
        +  pos({n})
```

`{n}` is fzf's built-in current-line index; `pos({n})` repositions the cursor after the reload so it appears as if the list updated in place.

The list is a 3-field TSV consumed by fzf with `--with-nth 3` (only the display column is shown):

```
s <TAB> stripped_session_id <TAB> <green>⚡ session_name<reset>   ← running session
p <TAB> path                <TAB> 📂 display_name                 ← project w/o session
n <TAB>                     <TAB> ✨ new session                  ← sentinel (always last)
```

`manage_sessions` runs a `while true` loop so that cancelling the branch picker (`ctrl-bs` inside `pick_branch`) returns to the sessions list rather than closing the popup entirely.

### Manual sessions

Add entries to `MANUAL_SESSIONS` at the top of `sessions.sh`:

```bash
MANUAL_SESSIONS=(
  "Notes:$HOME/Notes"   # display name : working directory
  "default:$HOME"
)
```

### Session ranking

Every pick increments a score in `~/.local/share/tmux-sessions/scores.tsv`. Scores decay with a 7-day half-life so recently used entries float to the top:

```
new_score = stored_score × e^(−ln2 × elapsed_seconds / 604800) + 1
```

An additional **path-prefix boost** (`shared_prefix_length / 50`) gives higher rank to entries whose path shares more of the current pane's working directory — so worktrees of the same repo float above unrelated projects.

### Invocation modes

| Invocation | Purpose |
|------------|---------|
| _(no args)_ | Normal: run `manage_sessions` |
| `--action <name> <type> <id> <tmpfile>` | Mutation: called by fzf bindings to modify the tmpfile in place, then exit |
| `--display-name <session_path> <session_name>` | Status bar helper: derives a display name from the session path via `format_session_name`; falls back to the stored name for manually-named sessions whose path doesn't round-trip through dot→underscore conversion |

---

## fetch_reload.sh

Background fetch helper invoked by `pick_branch` (in `common.sh`) when the user presses `ctrl-f` inside the branch picker.

**Arguments:** `repo_path  tmpfile  fzf_port  header_base`

**What it does:**

1. Forks everything to a background subshell immediately (`& disown`) so `execute-silent` returns at once and the picker stays interactive.
2. Starts a spinner goroutine that sends `change-header(… ⠋ fetching...)` frames to fzf's `--listen` port every 120 ms.
3. Runs `git fetch --all --quiet` against the repo.
4. Regenerates the branch list into `tmpfile` via `_gen_branch_picker_entries`.
5. Kills the spinner, then sends `change-header(…)+reload(cat tmpfile)` to fzf — atomically restoring the header and reloading the list with any newly discovered remote branches.

---

## common.sh

Utilities shared by all pickers.

### String helpers

- `strip_ansi(str)` — remove ANSI colour escape sequences
- `sanitize_name(str)` — trim whitespace and replace spaces with dashes; used to normalise user-entered branch and session names

### Session naming — `format_session_name`

Derives a short tmux session name from a path:

1. Strip `~/Projects/ghe.siriusxm.com/`
2. Strip `~/Projects/`
3. Replace `/Users/cesar.enrique` → `~`

### Session targeting — `get_session_id`, `switch_or_create_session`

All tmux operations use session IDs (`$N`) rather than names to avoid tmux misinterpreting `/` inside names as the `session:window` separator.

### Scoring — `update_score`, `sort_by_score`

`update_score(name)` decays the stored score then adds 1.

`sort_by_score([boost_path])` reads `name<TAB>key<TAB>path` lines from stdin, scores each entry by its decayed recency value plus an optional path-prefix boost, and writes them sorted highest-first.

### Project discovery — `list_git_projects`

Scans `~/Projects/` and `$XDG_CONFIG_HOME` with `fd`, looking for `.git` directories up to 6 levels deep. Outputs one `name<TAB>path` line per repo.

### Git worktree helpers

| Function | Purpose |
|----------|---------|
| `list_branches(repo)` | Local branches first, then remote-only (prefixed `origin/`) |
| `list_worktrees(repo)` | One `path<TAB>branch` line per worktree |
| `add_worktree(repo, container, branch, new_name)` | Create or locate a worktree; returns its path |
| `rename_worktree(main_wt, container, wt_path)` | Rename branch, move directory, repair git linkage, re-session |
| `pick_branch(repo)` | Interactive fzf branch picker; `ctrl-f` spawns `fetch_reload.sh` for background fetch + spinner; returns `new:<name>` or `existing:<branch>` |
| `get_default_branch(repo)` | Reads `refs/remotes/origin/HEAD` for the default branch name |

### Repo layout convention

```
~/Projects/my-org/my-repo/
    main/          ← main worktree (container = my-repo/)
    feat-login/    ← git worktree add
    fix-bug/       ← git worktree add
```

Each subdirectory under the *container* is an independent worktree. Worktree directories are named after their branch with `/` replaced by `-`.
