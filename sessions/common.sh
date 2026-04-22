#!/bin/bash
# Shared utilities sourced by sessions.sh and worktree.sh.
# Also contains all git-worktree helpers so sessions.sh can create
# worktrees without sourcing worktree.sh.

export BAT_THEME="Catppuccin Mocha"

# Catppuccin Mocha palette for fzf.
export FZF_DEFAULT_OPTS="\
--color=bg+:#313244,bg:#1E1E2E,spinner:#F5E0DC,hl:#F38BA8 \
--color=fg:#CDD6F4,header:#6C7086,info:#CBA6F7,pointer:#F5E0DC \
--color=marker:#B4BEFE,fg+:#CDD6F4,prompt:#CBA6F7,hl+:#F38BA8 \
--color=selected-bg:#45475A \
--color=border:#6C7086,label:#CDD6F4"

# Shared fzf style flags (no --tmux; used for inline prompts inside execute).
FZF_INLINE="--reverse --no-scrollbar --no-info --no-separator --no-border"
# Full-height tmux popup with the same chrome.
FZF_POPUP="--tmux bottom,100%,100% --scheme=path $FZF_INLINE"

# Emoji icons used across picker lists.
_ICON_SESSION=" "   # running session
_ICON_PROJECT=" "   # unopen project
_ICON_BRANCH=" "    # local branch / worktree
_ICON_REMOTE=" "    # remote-only branch
_ICON_NEW=" "        # new action sentinels

# TSV file storing per-session pick scores for recency ranking.
SCORE_FILE="$HOME/.local/share/tmux-sessions/scores.tsv"

# ── String utilities ──────────────────────────────────────────────────────────

# Strip ANSI colour escape sequences from a string.
strip_ansi() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }

# Trim leading/trailing whitespace and replace internal spaces with dashes.
# Used to normalise user-entered branch and session names.
sanitize_name() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]/-/g'; }

# Derive a short tmux session name from a filesystem path.
#
# Transformations applied in order:
#   1. Strip work GHE prefix (checked before the generic Projects/ prefix):
#        /Users/cesar.enrique/Projects/ghe.siriusxm.com/ → (removed)
#   2. Strip personal projects prefix:
#        /Users/cesar.enrique/Projects/ → (removed)
#   3. Abbreviate home directory with ~:
#        /Users/cesar.enrique → ~
#
# Dots are kept as-is.  The historical concern was tmux parsing "name.x" as
# "window.pane" in target specs, but all tmux operations here use session IDs
# (e.g. $3) rather than names as targets, so dots are safe.
#
# The [[ == glob ]] form is used for prefix checks (not regex) because it is
# simpler and avoids unintended RE metacharacter matches.
# The ${var#prefix} form strips an exact literal prefix from the value.
# The ${var/pat/rep} form replaces a single occurrence.
format_session_name() {
  local session_name="$1"

  # Strip longest-matching known prefix first.
  if [[ "$1" == /Users/cesar.enrique/Projects/ghe.siriusxm.com/* ]]; then
    session_name="${1#/Users/cesar.enrique/Projects/ghe.siriusxm.com/}"
  elif [[ "$1" == /Users/cesar.enrique/Projects/* ]]; then
    session_name="${1#/Users/cesar.enrique/Projects/}"
  fi

  # Replace the absolute home path with a tilde.
  # Backslashes before / prevent bash from treating them as substitution delimiters.
  echo "${session_name/\/Users\/cesar.enrique/~}"
}

# Return the tmux session ID ($N) for a session with the given exact name.
# Returns an empty string if no matching session exists.
#
# 'tmux has-session -t name' is avoided here because tmux interprets '/' in
# the target as a session:window separator, causing false positives when a
# session named "org" exists and we query "org/repo/branch".
# Using 'tmux ls' with awk exact-match sidesteps that parsing entirely.
#
# tmux silently replaces '.' with '_' when storing session names (to avoid
# ambiguity with the session:window.pane target format).  The lookup must use
# the same substitution so it matches what tmux actually stored.
get_session_id() {
  local session_name="${1//./_}"
  tmux ls -F "#{session_name}"$'\t'"#{session_id}" 2>/dev/null \
    | awk -F'\t' -v n="$session_name" '$1 == n { print $2 }'
}

# Switch to (or create) a tmux session for the given directory.
#
# Args:
#   $1  session_path  — working directory for the new or existing session
#   $2  session_name  — (optional) explicit session name; derived from $1 via
#                       format_session_name when omitted
#
# All targeting uses session IDs rather than names so that '/' inside names is
# never misread as the tmux session:window separator.
switch_or_create_session() {
  local session_path="$1"
  local session_name="${2:-$(format_session_name "$1")}"

  local session_id
  session_id=$(get_session_id "$session_name")

  if [[ -z "$session_id" ]]; then
    # -P -F prints the new session's ID so we can switch by ID immediately.
    session_id=$(tmux new-session -c "$session_path" -s "$session_name" -d \
      -P -F '#{session_id}')
  fi

  tmux switch-client -t "$session_id"
}

# Increment the pick score for a session name, decaying the stored value first.
#
# Score formula:
#   new_score = old_score × e^(−ln2 × elapsed_seconds / half_life) + 1
#
# Half-life is 7 days (604800 s), so a score of 1 from a week ago contributes
# 0.5 today.  ln(2) ≈ 0.693147.
#
# Storage: $SCORE_FILE — tab-separated columns: session_name, score, unix_ts
update_score() {
  local session_name="$1"
  local now half_life
  now=$(date +%s)
  half_life=$((7 * 24 * 3600))

  mkdir -p "$(dirname "$SCORE_FILE")"
  [[ -f "$SCORE_FILE" ]] || touch "$SCORE_FILE"

  local tmp
  tmp=$(mktemp)

  # For the matching row: decay the stored score then add 1.
  # For all other rows: pass through unchanged.
  # If no row matched: append a fresh entry at the end.
  awk -F'\t' -v OFS='\t' \
      -v name="$session_name" -v now="$now" -v hl="$half_life" '
    $1 == name {
      elapsed = now - ($3 + 0)
      if (elapsed < 0) elapsed = 0
      decay = exp(-0.693147 * elapsed / hl)
      print $1, ($2 + 0) * decay + 1, now
      found = 1
      next
    }
    { print }
    END { if (!found) print name, 1, now }
  ' "$SCORE_FILE" > "$tmp" && mv "$tmp" "$SCORE_FILE"
}

# Read "session_name<TAB>rest..." lines from stdin, sort them by current pick
# score (highest first), and write the same format to stdout.
#
# Optional arg: boost_path
#   The filesystem path of the current working directory.  When provided,
#   entries whose third TAB-delimited field is a path get an additive score
#   boost proportional to the length of the longest common prefix they share
#   with boost_path.  A longer match (deeper shared directory hierarchy) gives
#   a larger boost, so same-repo worktrees outrank same-org projects, which
#   outrank completely unrelated paths.  No subprocesses are spawned.
#
# Each stored score is decayed to the present using the same half-life formula
# as update_score before comparison.  Entries absent from the score file sort
# after all scored entries (score treated as 0).
sort_by_score() {
  local boost_path="${1:-}"
  local now half_life
  now=$(date +%s)
  half_life=$((7 * 24 * 3600))

  awk -F'\t' \
      -v score_file="$SCORE_FILE" -v now="$now" -v hl="$half_life" \
      -v boost_path="$boost_path" '
    BEGIN {
      # Load all stored scores, applying decay to bring each value current.
      while ((getline line < score_file) > 0) {
        n = split(line, f, "\t")
        if (n >= 3 && f[1] != "") {
          elapsed = now - (f[3] + 0)
          if (elapsed < 0) elapsed = 0
          scores[f[1]] = (f[2] + 0) * exp(-0.693147 * elapsed / hl)
        }
      }
    }
    {
      score = ($1 in scores) ? scores[$1] : 0
      # Path-prefix boost: add cpl/50 where cpl is the common prefix length
      # between field 3 and boost_path.  50-char match ≈ +1.0 to score.
      if (boost_path != "" && NF >= 3 && $3 != "") {
        n = length(boost_path) < length($3) ? length(boost_path) : length($3)
        cpl = 0
        for (i = 1; i <= n; i++) {
          if (substr($3, i, 1) == substr(boost_path, i, 1)) cpl++
          else break
        }
        score += cpl / 50.0
      }
      # Zero-pad to 20 chars so lexicographic and numeric sort agree.
      printf "%020.6f\t%s\n", score, $0
    }
  ' | sort -t$'\t' -k1 -rn | cut -f2-
}

# ── Project discovery ─────────────────────────────────────────────────────────

# Emit one "session_name<TAB>path" line per git repo found under
# ~/Projects/ and $XDG_CONFIG_HOME.  Manual sessions are NOT included
# here; callers that want them (sessions.sh) append them on top.
#
# fd flags:
#   -H              include hidden dirs (e.g. ~/.config)
#   ^.git$          match items named exactly ".git"
#   -td -tf         match both dir-type and file-type .git (bare repos)
#   --max-depth=6   cap recursion depth
#   --prune         don't descend into matched directories
#   --format {//}   output the parent of the match (repo root, not .git)
#   -E node_modules skip JS dependency trees
list_git_projects() {
  fd \
    -H ^.git$ -td -tf \
    --max-depth=6 \
    --prune \
    --format {//} \
    -E node_modules \
    "$HOME/Projects" "$XDG_CONFIG_HOME" \
  | while IFS= read -r path; do
      printf "%s\t%s\n" "$(format_session_name "$path")" "$path"
    done
}

# ── Git worktree helpers ──────────────────────────────────────────────────────

# Return the name of the default remote branch (e.g. "main" or "master").
# Reads refs/remotes/origin/HEAD, which git sets after 'git remote set-head'.
get_default_branch() {
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|.*/||'
}

# List branches available for a new worktree checkout.
# Outputs local branch names first, then remote-only branches prefixed with
# "origin/" so the user can distinguish them.
list_branches() {
  local repo_path="$1"
  local local_branches remote_branches remote_only

  local_branches=$(git -C "$repo_path" branch --format '%(refname:short)')
  remote_branches=$(git -C "$repo_path" branch -r --format '%(refname:short)' \
    | grep -v 'origin/HEAD')

  remote_only=$(comm -23 \
    <(printf '%s\n' "$remote_branches" | sed 's|^origin/||' | sort) \
    <(printf '%s\n' "$local_branches"  | sort) \
    | sed 's|^|origin/|')

  { printf '%s\n' "$local_branches"; printf '%s\n' "$remote_only"; } \
    | grep -v '^$'
}

# Convert a branch name to a safe directory name.
#   /       → -   (feature/login → feature-login)
#   (space) → -
branch_to_dir() {
  local name="${1//\//-}"
  echo "${name// /-}"
}

# List the worktrees belonging to the same repo as $repo_path.
# Outputs one "path<TAB>branch" line per worktree.
list_worktrees() {
  local repo_path="$1"
  git -C "$repo_path" worktree list --porcelain | awk '
    /^worktree /  { path = $2; branch = "" }
    /^branch /    { branch = $2; sub("refs/heads/", "", branch) }
    /^detached$/  { branch = "(detached)" }
    /^$/ {
      if (path != "") {
        print path "\t" (branch ? branch : "(detached)")
        path = ""
      }
    }
    END {
      if (path != "") print path "\t" (branch ? branch : "(detached)")
    }
  '
}

# Create a git worktree under $container for the given branch or new name.
# All git output is redirected to stderr so stdout stays clean for callers.
# Returns the new (or existing) worktree path on stdout.
add_worktree() {
  local repo_path="$1"
  local container="$2"
  local branch="$3"    # existing branch (may be "origin/foo" for remote-only)
  local new_name="$4"  # new branch name (mutually exclusive with $branch)

  local dir_name worktree_path default_branch

  if [[ -n "$new_name" ]]; then
    dir_name=$(branch_to_dir "$new_name")
    worktree_path="$container/$dir_name"
    default_branch=$(get_default_branch "$repo_path")
    git -C "$repo_path" worktree add \
      -b "$new_name" "$worktree_path" "origin/${default_branch}" >&2 \
      || return 1
  else
    local local_branch="${branch#origin/}"
    # If the branch is already checked out in a worktree, return that path
    # instead of trying (and failing) to create a duplicate.
    local existing_path
    existing_path=$(list_worktrees "$repo_path" \
      | awk -F'\t' -v b="$local_branch" '$2 == b { print $1; exit }')
    if [[ -n "$existing_path" ]]; then
      echo "$existing_path"
      return 0
    fi
    dir_name=$(branch_to_dir "$local_branch")
    worktree_path="$container/$dir_name"
    git -C "$repo_path" worktree add "$worktree_path" "$branch" >&2 || return 1
  fi

  echo "$worktree_path"
}

# Rename a worktree: renames the git branch, moves the directory, repairs the
# worktree linkage, and opens a fresh tmux session at the new path.
#
# Flow:
#   1. Prompt for a new name (fzf input, pre-filled with current branch).
#   2. Rename the branch with 'git branch -m' (works in-place at old path).
#   3. Move the directory with mv.
#   4. Run 'git worktree repair' to update the stale gitdir pointer.
#      After mv, .git/worktrees/<name>/gitdir still points to the old path;
#      repair rewrites it to the new location.
#   5. Kill the old tmux session (if any) and create a new one.
rename_worktree() {
  local repo_path="$1"
  local container="$2"
  local wt_path="$3"

  local old_branch
  old_branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
  if [[ -z "$old_branch" ]]; then
    echo "Cannot rename: worktree is in detached HEAD state" >&2
    return 1
  fi

  local rename_output rename_rc rename_key new_name
  rename_output=$(echo "" | fzf $FZF_INLINE \
    --print-query --no-select-1 \
    --query "$old_branch" \
    --prompt "Rename to: " \
    --header "enter:rename  ctrl-bs:cancel" \
    --expect "ctrl-bs")
  rename_rc=$?
  [[ $rename_rc -eq 130 ]] && return 1
  rename_key=$(printf '%s' "$rename_output" | sed -n '2p')
  [[ "$rename_key" == "ctrl-bs" ]] && return 1
  new_name=$(sanitize_name "$(printf '%s' "$rename_output" | head -1)")
  [[ -z "$new_name" || "$new_name" == "$old_branch" ]] && return 1

  local new_dir new_wt_path
  new_dir=$(branch_to_dir "$new_name")
  new_wt_path="$container/$new_dir"

  if [[ -e "$new_wt_path" ]]; then
    echo "Destination already exists: $new_wt_path" >&2
    return 1
  fi

  # Rename the branch first while the directory is still at its old location.
  git -C "$wt_path" branch -m "$old_branch" "$new_name" >&2 || return 1

  # Move the directory; on failure, revert the branch rename.
  mv "$wt_path" "$new_wt_path" || {
    git -C "$wt_path" branch -m "$new_name" "$old_branch" >&2 2>/dev/null
    return 1
  }

  # Repair the worktree linkage from inside the moved directory.
  git -C "$new_wt_path" worktree repair >&2

  # Kill the old session (if any).
  # Switch to the renamed path only when the current pane is inside the
  # worktree being renamed; otherwise leave the user where they are.
  local old_session_id pane_root
  old_session_id=$(get_session_id "$(format_session_name "$wt_path")")
  [[ -n "$old_session_id" ]] && tmux kill-session -t "$old_session_id" 2>/dev/null

  pane_root=$(git -C "$(tmux display-message -p '#{pane_current_path}')" \
    rev-parse --show-toplevel 2>/dev/null)
  [[ "$pane_root" == "$wt_path" ]] && switch_or_create_session "$new_wt_path"
}

# Emit tab-delimited branch picker entries for fzf: [new] sentinel + all branches.
_gen_branch_picker_entries() {
  local repo_path="$1"
  printf "[new]\t%s new branch\n" "$_ICON_NEW"
  list_branches "$repo_path" | while IFS= read -r branch; do
    if [[ "$branch" == origin/* ]]; then
      printf "%s\t%s %s\n" "$branch" "$_ICON_REMOTE" "$branch"
    else
      printf "%s\t%s %s\n" "$branch" "$_ICON_BRANCH" "$branch"
    fi
  done
}

# Return 0 if git fetch should run (FETCH_HEAD missing or >15 min old).
# Uses --git-common-dir so the check works correctly from inside linked worktrees.
_fetch_is_stale() {
  local repo_path="$1"
  local window=900  # 15 minutes
  local git_common fetch_head mtime now
  git_common=$(git -C "$repo_path" rev-parse --git-common-dir 2>/dev/null) || return 0
  # --git-common-dir returns a relative path for the main worktree; make it absolute.
  [[ "$git_common" != /* ]] && git_common="$repo_path/$git_common"
  fetch_head="$git_common/FETCH_HEAD"
  [[ -f "$fetch_head" ]] || return 0
  mtime=$(stat -f %m "$fetch_head" 2>/dev/null) || return 0
  now=$(date +%s)
  (( now - mtime > window ))
}

# Interactively pick a branch for a new worktree.
# Returns "new:<name>" or "existing:<branch>" on stdout with exit 0.
# Exit 1 = ctrl-bs (go back), exit 2 = Esc (close all).
#
# Opens fzf with --listen so a background process can push a reload after
# git fetch --all completes.  Auto-fetches only when FETCH_HEAD is stale
# (>15 min); ctrl-f triggers a manual refresh at any time.
pick_branch() {
  local repo_path="$1"
  local _port _tmpfile _refresh_script _fetch_pid=""
  _port=$(( 51200 + RANDOM % 14335 ))
  _tmpfile=$(mktemp)
  _refresh_script="$(dirname "${BASH_SOURCE[0]}")/fetch_reload.sh"
  local _HEADER_BASE="enter:checkout  ctrl-bs:back  ctrl-f:refresh"

  trap 'rm -f "$_tmpfile"; [[ -n "$_fetch_pid" ]] && kill "$_fetch_pid" 2>/dev/null' RETURN

  # Generate initial branch list.
  _gen_branch_picker_entries "$repo_path" > "$_tmpfile"

  # Auto-fetch in the background if stale.
  local _initial_header="$_HEADER_BASE"
  if _fetch_is_stale "$repo_path"; then
    "$_refresh_script" "$repo_path" "$_tmpfile" "$_port" "$_HEADER_BASE" &
    _fetch_pid=$!
    _initial_header="$_HEADER_BASE [syncing...]"
  fi

  while true; do
    local selected rc
    selected=$(
      cat "$_tmpfile" | fzf $FZF_POPUP \
          --listen "$_port" \
          --with-nth 2 \
          --delimiter $'\t' \
          --prompt "Branch > " \
          --header "$_initial_header" \
          --expect "ctrl-bs" \
          --bind "ctrl-f:change-header($_HEADER_BASE ⟳ fetching...)+execute-silent('$_refresh_script' '$repo_path' '$_tmpfile' '$_port' '$_HEADER_BASE')"
    )
    rc=$?
    _initial_header="$_HEADER_BASE"  # Reset for any subsequent loop iterations.

    [[ $rc -eq 130 ]] && return 2
    [[ -z "$selected" ]] && return 2

    local key item
    key=$(printf '%s' "$selected" | head -1)
    item=$(printf '%s' "$selected" | sed -n '2p' | cut -f1)
    [[ "$key" == "ctrl-bs" ]] && return 1
    [[ -z "$item" ]] && return 2

    if [[ "$item" == "[new]" ]]; then
      local name_output name_rc name_key new_name
      name_output=$(echo "" | fzf $FZF_POPUP \
        --print-query --no-select-1 \
        --prompt "New branch name: " \
        --header "enter:create  ctrl-bs:back" \
        --expect "ctrl-bs")
      name_rc=$?
      [[ $name_rc -eq 130 ]] && return 2
      name_key=$(printf '%s' "$name_output" | sed -n '2p')
      [[ "$name_key" == "ctrl-bs" ]] && continue
      new_name=$(sanitize_name "$(printf '%s' "$name_output" | head -1)")
      [[ -z "$new_name" ]] && continue
      echo "new:${new_name}"
      return 0
    else
      echo "existing:${item}"
      return 0
    fi
  done
}
