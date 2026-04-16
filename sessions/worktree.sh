#!/bin/bash
# Git worktree manager invoked by C-S-w.
# Shows the worktrees of the current project (or lets you pick one) in an fzf
# popup with actions to switch, delete, or rename worktrees.

source "$(dirname "$0")/common.sh"

# Find all git projects under ~/Projects/ and $XDG_CONFIG_HOME.
# Delegates the fd scan to list_git_projects from common.sh.
list_projects() {
  list_git_projects
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

# Emit the full worktree list consumed by fzf: two sentinel rows followed by
# one entry per worktree.  Called via --list for fzf reload bindings.
_list_entries() {
  local repo_path="$1"
  printf "switch\t%s switch project\n" "$_ICON_SWITCH"
  printf "\t%s new worktree\n" "$_ICON_NEW"
  list_worktrees "$repo_path" | while IFS=$'\t' read -r wt_path branch; do
    printf "%s\t%s %s [%s]\n" "$wt_path" "$_ICON_BRANCH" "$(basename "$wt_path")" "$branch"
  done
}

# ctrl-d: delete the worktree and kill its tmux session.
_action_ctrl_d() {
  local repo_path="$1" wt_path="$2"
  [[ -z "$wt_path" || "$wt_path" == "switch" ]] && return
  delete_worktree "$repo_path" "$wt_path"
}

# ctrl-r: rename worktree via an inline fzf prompt; reload stays in place.
# Called via fzf execute (not execute-silent) so it has terminal access.
_action_ctrl_r() {
  local repo_path="$1" wt_path="$2"
  [[ -z "$wt_path" || "$wt_path" == "switch" ]] && return
  local container
  container=$(dirname "$repo_path")
  rename_worktree "$repo_path" "$container" "$wt_path"
}

# Show the worktree manager for a project.
#   Enter    — switch to (or create) a tmux session for the selected worktree
#   Ctrl-D   — delete worktree + session; picker stays open via reload
#   Ctrl-R   — rename worktree; picker stays open via reload
#   Ctrl-BS  — go back to the project picker
#   sentinels — switch project / new worktree handled in the main loop
manage_worktrees() {
  local repo_path="$1"
  local container self
  container=$(dirname "$repo_path")
  self="${BASH_SOURCE[0]}"

  while true; do
    local output fzf_rc
    output=$(
      "$self" --list "$repo_path" \
      | fzf $FZF_POPUP \
          --with-nth 2 \
          --delimiter $'\t' \
          --prompt "Worktrees > " \
          --expect "ctrl-bs" \
          --header "enter:switch  ctrl-d:delete  ctrl-r:rename  ctrl-bs:back" \
          --bind "ctrl-d:execute-silent('$self' --action ctrl-d '$repo_path' {1})+reload('$self' --list '$repo_path')+pos({n})" \
          --bind "ctrl-r:execute('$self' --action ctrl-r '$repo_path' {1})+reload('$self' --list '$repo_path')+pos({n})"
    )
    fzf_rc=$?

    [[ $fzf_rc -eq 130 ]] && return 0  # Esc → close
    [[ -z "$output" ]] && return 0

    local key line wt_path
    key=$(printf '%s' "$output" | head -1)
    line=$(printf '%s' "$output" | sed -n '2p')
    wt_path=$(printf '%s' "$line" | cut -f1)

    [[ "$key" == "ctrl-bs" ]] && return 1  # ctrl-bs → back to project picker

    if [[ "$wt_path" == "switch" ]]; then
      local new_repo pick_rc
      new_repo=$(pick_project)
      pick_rc=$?
      [[ $pick_rc -eq 2 ]] && return 0   # Esc in project picker → close all
      if [[ $pick_rc -eq 0 ]]; then
        repo_path="$new_repo"
        container=$(dirname "$repo_path")
      fi

    elif [[ -z "$wt_path" ]]; then
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

    else
      switch_or_create_session "$wt_path"
      return 0
    fi
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────
# --list <repo_path>  : emit the worktree list (called by fzf reload bindings)
# --action <name> ... : run a mutation    (called by fzf execute-silent bindings)
# Normal invocation (C-S-w): run manage_worktrees.
if [[ "$1" == --list ]]; then
  _list_entries "$2"
  exit
fi

if [[ "$1" == --action ]]; then
  case "$2" in
    ctrl-d) _action_ctrl_d "$3" "$4" ;;
    ctrl-r) _action_ctrl_r "$3" "$4" ;;
  esac
  exit
fi

repo_path=$(get_current_project)

while true; do
  if [[ -z "$repo_path" ]]; then
    repo_path=$(pick_project) || exit 0
  fi

  manage_worktrees "$repo_path"
  [[ $? -eq 1 ]] || exit 0
  repo_path=""
done
