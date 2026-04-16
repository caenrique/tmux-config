#!/bin/bash
# Git worktree manager invoked by C-S-w.
# Shows the worktrees of the current project (or lets you pick one) in an fzf
# popup with actions to switch, delete, or rename worktrees.

source "$(dirname "$0")/common.sh"

# Find all git projects under ~/Projects/ and $XDG_CONFIG_HOME.
# Outputs one "display_name<TAB>path" line per repo root.
# display_name is derived via format_session_name for consistent short labels.
# See sessions.sh list_projects for fd flag documentation.
list_projects() {
  fd \
    -H \
    ^.git$ \
    -td \
    -tf \
    --max-depth=6 \
    --prune \
    --format \
    {//} \
    -E \
    node_modules \
    "$HOME/Projects" \
    "$XDG_CONFIG_HOME" \
  | while IFS= read -r path; do
      printf "%s\t%s\n" "$(format_session_name "$path")" "$path"
    done
}

# Return the git root of the directory currently open in the active tmux pane,
# or an empty string if the pane is not inside a git repo.
get_current_project() {
  local pane_path
  pane_path=$(tmux display-message -p '#{pane_current_path}')
  git -C "$pane_path" rev-parse --show-toplevel 2>/dev/null
}

# Present an fzf project picker.  The current project (if any) is listed first
# with a "(current) " prefix so it can be quickly confirmed with Enter.
# Returns 1 (and outputs nothing) if the user cancels.
# Outputs the selected repo path on stdout.
pick_project() {
  local current
  current=$(get_current_project)

  local entries
  if [[ -n "$current" ]]; then
    # Prepend the current project with a "(current) " display prefix.
    # Filter it from the main list (match on the path field) to avoid dupes.
    local current_label
    current_label="(current) $(format_session_name "$current")"
    entries=$(printf "%s\t%s\n" "$current_label" "$current"
              list_projects | awk -F'\t' -v p="$current" '$2 != p')
  else
    entries=$(list_projects)
  fi

  local selected rc
  selected=$(printf '%s\n' "$entries" \
    | fzf $FZF_POPUP \
        --with-nth 1 \
        --delimiter $'\t' \
        --prompt "Project > " \
        --header "enter:select  ctrl-bs:back" \
        --expect "ctrl-bs")
  rc=$?
  [[ $rc -eq 130 ]] && return 2       # Esc → close all
  [[ -z "$selected" ]] && return 2

  local key item
  key=$(printf '%s' "$selected" | head -1)
  item=$(printf '%s' "$selected" | sed -n '2p')
  [[ "$key" == "ctrl-bs" ]] && return 1  # ctrl-bs → go back
  [[ -z "$item" ]] && return 2

  # Return the path (field 2).
  printf '%s' "$item" | cut -f2
}

# Return the name of the default remote branch (e.g. "main" or "master").
# Reads refs/remotes/origin/HEAD, which git sets after 'git remote set-head'.
# sed 's|.*/||' strips everything up to and including the last slash, leaving
# only the branch name portion of "refs/remotes/origin/main".
get_default_branch() {
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|.*/||'
}

# List branches available for a new worktree checkout.
# Outputs local branch names first, then remote-only branches prefixed with
# "origin/" so the user can distinguish them.
#
# comm -23 computes the set difference: lines only in file1 (not file2).
#   File 1: remote branch names stripped of "origin/" prefix, sorted.
#   File 2: local branch names, sorted.
# Result: branches that exist remotely but have no local counterpart.
# The "origin/" prefix is re-added with sed so the user sees the full ref.
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
# Replaces characters that are awkward in filesystem paths:
#   /       → -   (nested branch paths like "feature/login" → "feature-login")
#   (space) → -   (user-typed names containing spaces)
#
# ${var//pattern/replacement} replaces ALL occurrences (double slash).
branch_to_dir() {
  local name="${1//\//-}"
  echo "${name// /-}"
}

# Interactively pick a branch for a new worktree.
# Returns "new:<name>" or "existing:<branch>" on stdout with exit 0.
# Exit 1 = ctrl-bs (go back), exit 2 = Esc (close all).
pick_branch() {
  local repo_path="$1"

  while true; do
    local selected rc
    selected=$({ echo "[+ new branch]"; list_branches "$repo_path"; } \
      | fzf $FZF_POPUP \
          --prompt "Branch > " \
          --header "enter:checkout  ctrl-bs:back" \
          --expect "ctrl-bs")
    rc=$?
    [[ $rc -eq 130 ]] && return 2    # Esc → close all
    [[ -z "$selected" ]] && return 2

    local key item
    key=$(printf '%s' "$selected" | head -1)
    item=$(printf '%s' "$selected" | sed -n '2p')
    [[ "$key" == "ctrl-bs" ]] && return 1  # ctrl-bs → back to worktree list
    [[ -z "$item" ]] && return 2

    if [[ "$item" == "[+ new branch]" ]]; then
      # --print-query outputs the typed query as line 1; --expect adds key as line 2.
      # Note: --exit-0 must NOT be used here; it would cause fzf to close
      # immediately once typed text stops matching the (empty) item list.
      local name_output name_rc name_key new_name
      name_output=$(echo "" | fzf $FZF_POPUP \
        --print-query --no-select-1 \
        --prompt "New branch name: " \
        --header "enter:create  ctrl-bs:back" \
        --expect "ctrl-bs")
      name_rc=$?
      [[ $name_rc -eq 130 ]] && return 2  # Esc → close all
      name_key=$(printf '%s' "$name_output" | sed -n '2p')
      [[ "$name_key" == "ctrl-bs" ]] && continue  # ctrl-bs → back to branch list
      # Trim leading/trailing whitespace; replace inner spaces with hyphens.
      new_name=$(printf '%s' "$name_output" | head -1)
      new_name=$(printf '%s' "$new_name" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]/-/g')
      [[ -z "$new_name" ]] && continue  # empty → retry
      echo "new:${new_name}"
      return 0
    else
      echo "existing:${item}"
      return 0
    fi
  done
}

# Create a git worktree under $container for the given branch or new name.
# All git output is redirected to stderr so it is visible in the terminal but
# does not pollute the stdout path that callers capture with $().
# Returns the new worktree path on stdout, or nothing on failure.
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
    # Strip "origin/" prefix for the directory name; git accepts the full ref.
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

# List the worktrees belonging to the same repo as $repo_path.
# Outputs one "path<TAB>branch" line per worktree.
# Uses --porcelain for reliable field parsing; the non-porcelain format varies
# and is harder to parse safely for detached HEADs.
# Each stanza ends with a blank line; "branch" may be absent for detached HEADs
# (git emits a standalone "detached" keyword instead).
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

# Delete a worktree and kill its tmux session (if one is running).
# Uses --force so that untracked or modified files do not block removal.
delete_worktree() {
  local repo_path="$1"
  local wt_path="$2"

  local session_id
  session_id=$(get_session_id "$(format_session_name "$wt_path")")
  [[ -n "$session_id" ]] && tmux kill-session -t "$session_id"

  git -C "$repo_path" worktree remove --force "$wt_path" >&2
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

  # Pre-fill the query with the current branch name so the user can edit it.
  # Note: --exit-0 must NOT be used here; it would cause fzf to close
  # immediately once the query stops matching the (empty) item list.
  local rename_output rename_rc rename_key new_name
  rename_output=$(echo "" | fzf $FZF_POPUP \
    --print-query --no-select-1 \
    --query "$old_branch" \
    --prompt "Rename to: " \
    --header "enter:rename  ctrl-bs:back" \
    --expect "ctrl-bs")
  rename_rc=$?
  [[ $rename_rc -eq 130 ]] && return 2                      # Esc → close all
  rename_key=$(printf '%s' "$rename_output" | sed -n '2p')
  [[ "$rename_key" == "ctrl-bs" ]] && return 1              # ctrl-bs → back
  new_name=$(printf '%s' "$rename_output" | head -1)
  new_name=$(printf '%s' "$new_name" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]/-/g')
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
  # This updates .git/worktrees/<name>/gitdir to point to the new path.
  git -C "$new_wt_path" worktree repair >&2

  # Tear down the old session (if any) and open a new one at the new path.
  local old_session_id
  old_session_id=$(get_session_id "$(format_session_name "$wt_path")")
  [[ -n "$old_session_id" ]] && tmux kill-session -t "$old_session_id"

  switch_or_create_session "$new_wt_path"
}

# Show the worktree manager for a project.
# Displays an fzf list of all worktrees with the following key bindings:
#   Enter   — switch to (or create) a tmux session for the selected worktree
#   Ctrl-D  — delete the worktree and its tmux session; list stays open
#   Ctrl-R  — rename the branch, directory, and session; list stays open
#   (top)   — "[+ new worktree]" opens the branch picker to add a worktree
#
# fzf --expect outputs the pressed key on line 1 and the selected item on
# line 2.  An empty key line means Enter was pressed (the default action).
#
# Ctrl-D and Ctrl-R loop: after each action the list is rebuilt and fzf reopens
# so the user can perform multiple operations without relaunching the picker.
manage_worktrees() {
  local repo_path="$1"
  local container
  container=$(dirname "$repo_path")

  while true; do
    # Rebuild the display list on every iteration so deleted entries disappear.
    # split($1,a,"/") splits the path by "/" into array a; a[n] is the basename.
    local wt_entries
    wt_entries=$(list_worktrees "$repo_path" | awk -F'\t' '{
      n = split($1, a, "/")
      print $1 "\t" a[n] " [" $2 "]"
    }')

    local output fzf_rc
    output=$(
      # "switch" sentinel: switch to a different project.
      # Empty field 1 sentinel: add a new worktree.
      { printf "switch\t[+ switch project]\n"
        printf "\t[+ new worktree]\n"
        printf '%s\n' "$wt_entries"; } \
      | fzf $FZF_POPUP \
          --with-nth 2 \
          --delimiter $'\t' \
          --prompt "Worktrees > " \
          --expect "ctrl-d,ctrl-r,ctrl-bs" \
          --header "enter:switch  ctrl-d:delete  ctrl-r:rename  ctrl-bs:back"
    )
    fzf_rc=$?

    [[ $fzf_rc -eq 130 ]] && return 0  # Esc → close
    [[ -z "$output" ]] && return 0

    local key line wt_path
    key=$(printf '%s' "$output" | head -1)
    line=$(printf '%s' "$output" | sed -n '2p')
    # Field 1 of the selected line is the worktree path, "switch", or empty.
    wt_path=$(printf '%s' "$line" | cut -f1)

    [[ "$key" == "ctrl-bs" ]] && return 1  # ctrl-bs → back to project picker

    if [[ "$wt_path" == "switch" ]]; then
      # [+ switch project]: open project picker (Enter only; ctrl-d/ctrl-r ignored).
      if [[ -z "$key" ]]; then
        local new_repo pick_rc
        new_repo=$(pick_project)
        pick_rc=$?
        [[ $pick_rc -eq 2 ]] && return 0   # Esc in project picker → close all
        if [[ $pick_rc -eq 0 ]]; then
          repo_path="$new_repo"
          container=$(dirname "$repo_path")
        fi
        # pick_rc=1 (ctrl-bs) = back to worktree list → just loop
      fi
      # Loop: reopen with the new (or unchanged) project's worktrees.

    elif [[ -z "$wt_path" ]]; then
      # [+ new worktree]: run the branch picker then add and switch.
      local result pick_rc worktree_path
      result=$(pick_branch "$repo_path")
      pick_rc=$?
      [[ $pick_rc -eq 1 ]] && continue   # ctrl-bs → back to worktree list
      [[ $pick_rc -eq 2 ]] && return 0   # Esc → close all
      if [[ "$result" == new:* ]]; then
        worktree_path=$(add_worktree "$repo_path" "$container" "" "${result#new:}") \
          || continue
      else
        worktree_path=$(add_worktree "$repo_path" "$container" "${result#existing:}" "") \
          || continue
      fi
      switch_or_create_session "$worktree_path"
      return 0

    elif [[ "$key" == "ctrl-d" ]]; then
      delete_worktree "$repo_path" "$wt_path"
      # Loop: reopen fzf with the updated list.

    elif [[ "$key" == "ctrl-r" ]]; then
      rename_worktree "$repo_path" "$container" "$wt_path"
      [[ $? -eq 2 ]] && return 0  # Esc in rename prompt → close all
      # rc=0 (renamed) or rc=1 (ctrl-bs/no change): loop

    else
      switch_or_create_session "$wt_path"
      return 0
    fi
  done
}

# Main ─────────────────────────────────────────────────────────────────────────
# Use the current pane's git repo; fall back to the project picker if not in one.
# ctrl-bs in the worktree list returns here to show the project picker.

repo_path=$(get_current_project)

while true; do
  if [[ -z "$repo_path" ]]; then
    repo_path=$(pick_project) || exit 0  # Esc or ctrl-bs at project picker = close
  fi

  manage_worktrees "$repo_path"
  [[ $? -eq 1 ]] || exit 0  # rc=1 = ctrl-bs, go back to project picker
  repo_path=""               # clear so project picker shows on next iteration
done
