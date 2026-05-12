#!/bin/bash
# Session manager invoked by C-S-s.
# Shows a unified list: running sessions (green, sorted by recency) at the top,
# followed by projects without a session.  All actions are in a single fzf picker.
#   Enter     — switch to session / open project as new session
#   Ctrl-W    — open branch picker to create a worktree for the row's repo
#   Ctrl-D    — kill session + delete worktree; orphaned project dirs prompt to confirm
#   Ctrl-X    — kill session only; entry becomes a project row
#   Ctrl-R    — rename worktree (branch + dir + repair) if linked; session name otherwise
#   Ctrl-BS   — close picker

source "$(dirname "$0")/common.sh"

# Manual sessions: "display_name:working_directory"
MANUAL_SESSIONS=(
  "Notes:$HOME/Notes"
  "default:$HOME"
)

# Emit one "session_name<TAB>cwd" line per discoverable project.
list_projects() {
  list_git_projects
  for entry in "${MANUAL_SESSIONS[@]}"; do
    printf "%s\t%s\n" "${entry%%:*}" "${entry#*:}"
  done
}

# Catppuccin Mocha green — used to highlight running session rows.
# \033[38;2;R;G;Bm sets a 24-bit foreground colour; \033[0m resets it.
_GREEN=$'\033[38;2;166;227;161m'
_YELLOW=$'\033[38;2;249;226;175m'
_RESET=$'\033[0m'

# Emit the unified 3-field TSV list consumed by manage_sessions.
# Format: type<TAB>key<TAB>display
#   s <TAB> stripped_id <TAB> <green>session_name<reset>    ← running session
#   p <TAB> path        <TAB> display_name                  ← project w/o session
#   n <TAB>             <TAB> display_name                  ← new-session sentinel
#
# Both sections are sorted by recency score (highest first).
# Projects already open as sessions are skipped to avoid duplicates.
build_entries() {
  local current_session prev_session pane_path
  current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  prev_session=$(tmux display-message -p '#{client_last_session}' 2>/dev/null)
  pane_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)

  # Newline-wrapped blob of running session names (dots→underscores) for O(1)
  # pattern matching in the projects loop — one tmux call instead of one per entry.
  local sessions_blob
  sessions_blob=$'\n'$(tmux ls -F "#{session_name}" 2>/dev/null | sed 's/\./_/g')$'\n'

  # Pin the current session first (yellow, labelled "(current)").
  if [[ -n "$current_session" ]]; then
    local curr_id
    curr_id=$(get_session_id "$current_session")
    if [[ -n "$curr_id" ]]; then
      local curr_path curr_display
      curr_path=$(tmux display-message -p -t "$curr_id" '#{session_path}' 2>/dev/null)
      curr_display=$(format_session_name "$curr_path")
      [[ "${curr_display//./_}" != "$current_session" ]] && curr_display="$current_session"
      printf "s\t%s\t%s%s (current) %s%s\n" "${curr_id#\$}" "$_YELLOW" "$_ICON_SESSION" "$curr_display" "$_RESET"
    fi
  fi

  # Pin the previous session second (green, labelled "(previous)").
  if [[ -n "$prev_session" && "$prev_session" != "$current_session" ]]; then
    local prev_id
    prev_id=$(get_session_id "$prev_session")
    if [[ -n "$prev_id" ]]; then
      local prev_path prev_display
      prev_path=$(tmux display-message -p -t "$prev_id" '#{session_path}' 2>/dev/null)
      prev_display=$(format_session_name "$prev_path")
      # Only use the path-derived name when it maps back to the stored name
      # (dots→underscores). For manually-named sessions it won't match, so fall back.
      [[ "${prev_display//./_}" != "$prev_session" ]] && prev_display="$prev_session"
      printf "s\t%s\t%s%s (previous) %s%s\n" "${prev_id#\$}" "$_GREEN" "$_ICON_SESSION" "$prev_display" "$_RESET"
    fi
  fi

  # Sessions: field 3 = session working dir, used by sort_by_score for the
  # path-prefix boost (longer shared prefix with pane_path → higher rank).
  # Use format_session_name on the session path to restore dots that tmux
  # silently converted to underscores in the stored session name.  Fall back
  # to the stored name for manually-named sessions whose path doesn't round-trip.
  tmux ls -F "#{session_id}"$'\t'"#{session_name}"$'\t'"#{session_path}" 2>/dev/null \
    | sed 's/^\$//' \
    | while IFS=$'\t' read -r raw_id name sess_path; do
        [[ "$name" == "$prev_session" ]] && continue
        [[ "$name" == "$current_session" ]] && continue
        derived=$(format_session_name "$sess_path")
        [[ "${derived//./_}" != "$name" ]] && derived="$name"
        printf "%s\t%s\t%s\n" "$derived" "$raw_id" "$sess_path"
      done \
    | sort_by_score "$pane_path" \
    | while IFS=$'\t' read -r name raw_id _path; do
        printf "s\t%s\t%s%s %s%s\n" "$raw_id" "$_GREEN" "$_ICON_SESSION" "$name" "$_RESET"
      done

  # Projects: field 3 = project path (same as field 2) for the prefix boost.
  # Dedup uses sessions_blob to avoid per-entry tmux calls.
  list_projects \
    | while IFS=$'\t' read -r name path; do
        local norm="${name//./_}"
        [[ "$sessions_blob" == *$'\n'"$norm"$'\n'* ]] && continue
        printf "%s\t%s\t%s\n" "$name" "$path" "$path"
      done \
    | sort_by_score "$pane_path" \
    | while IFS=$'\t' read -r name path _; do
        printf "p\t%s\t%s %s\n" "$path" "$_ICON_PROJECT" "$name"
      done

  # New-session sentinel — always last.
  printf "n\t\t%s new session\n" "$_ICON_NEW"
}

# ── Action functions ──────────────────────────────────────────────────────────
# Called as: sessions.sh --action <name> <type> <id> <tmpfile>
# ctrl-x is a no-op on non-session rows; ctrl-d and ctrl-r handle both s and p.

# Return 0 if path looks like an orphaned worktree directory: its parent
# contains at least one other directory that is a git repo (.git present).
# Used to offer a delete prompt when git no longer tracks the worktree.
_is_orphaned_worktree_dir() {
  local path="$1"
  local container
  container=$(dirname "$path")
  local sibling
  for sibling in "$container"/*/; do
    sibling="${sibling%/}"
    [[ "$sibling" == "$path" ]] && continue
    [[ -e "$sibling/.git" ]] && return 0
  done
  return 1
}

# ctrl-d: kill session + remove its worktree if applicable (session rows);
#         delete a linked worktree with no session (project rows);
#         prompt to delete if dir looks like an orphaned worktree.
_action_ctrl_d() {
  local type="$1" id="$2" tmpfile="$3"

  if [[ "$type" == "s" ]]; then
    local tmux_id="\$$id"
    local sess_path
    sess_path=$(tmux display-message -p -t "$tmux_id" '#{session_path}' 2>/dev/null)
    tmux kill-session -t "$tmux_id" 2>/dev/null
    local git_dir
    git_dir=$(git -C "$sess_path" rev-parse --git-dir 2>/dev/null)
    grep -v $'^s\t'"$id"$'\t' "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
    if [[ "$git_dir" == *"worktrees"* ]]; then
      local wt_repo
      wt_repo=$(git -C "$sess_path" rev-parse --show-toplevel 2>/dev/null)
      [[ -n "$wt_repo" ]] && git -C "$wt_repo" worktree remove --force "$sess_path" >&2 &
    fi

  elif [[ "$type" == "p" ]]; then
    local wt_path="$id"
    local git_dir
    git_dir=$(git -C "$wt_path" rev-parse --git-dir 2>/dev/null)
    if [[ "$git_dir" != *"worktrees"* ]]; then
      if _is_orphaned_worktree_dir "$wt_path"; then
        local answer
        answer=$(printf 'No\nYes' | fzf $FZF_INLINE \
          --no-sort \
          --prompt "Delete $(basename "$wt_path")? " \
          --header "directory is not git-linked — delete anyway?")
        [[ "$answer" != "Yes" ]] && return
        grep -v $'^p\t'"$(printf '%s' "$wt_path" | sed 's|[/\&]|\\&|g')"$'\t' \
          "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
        rm -rf "$wt_path" &
      else
        tmux display-message -d 2000 "ctrl-d: not a linked worktree"
      fi
      return
    fi
    local wt_repo
    wt_repo=$(git -C "$wt_path" rev-parse --show-toplevel 2>/dev/null)
    [[ -z "$wt_repo" ]] && return
    grep -v $'^p\t'"$(printf '%s' "$wt_path" | sed 's|[/\&]|\\&|g')"$'\t' \
      "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
    git -C "$wt_repo" worktree remove --force "$wt_path" >&2 &
  fi
}

# ctrl-x: kill session only; convert the entry to a project row in place.
_action_ctrl_x() {
  local type="$1" id="$2" tmpfile="$3"
  [[ "$type" != "s" ]] && return
  local tmux_id="\$$id"
  local sess_path
  sess_path=$(tmux display-message -p -t "$tmux_id" '#{session_path}' 2>/dev/null)
  local clean_name
  clean_name=$(strip_ansi "$(grep $'^s\t'"$id"$'\t' "$tmpfile" | cut -f3)")
  clean_name="${clean_name#${_ICON_SESSION} }"
  clean_name="${clean_name#(current) }"
  clean_name="${clean_name#(previous) }"
  tmux kill-session -t "$tmux_id" 2>/dev/null
  # Remove the session row from its current position and insert it as a project
  # row just before the new-session sentinel so it lands in the projects section.
  NEW_NAME="${_ICON_PROJECT} ${clean_name}" \
    awk -F'\t' -v OFS='\t' -v id="$id" -v path="$sess_path" '
      $1=="s" && $2==id { saved = "p\t" path "\t" ENVIRON["NEW_NAME"]; next }
      $1=="n" { if (saved != "") { print saved; saved = "" } }
      { print }
      END { if (saved != "") print saved }
    ' "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
}

# ctrl-r: rename worktree (branch + dir + repair) when on a linked worktree;
#         rename tmux session only otherwise.
# Called via fzf execute (not execute-silent) so it has terminal access.
_action_ctrl_r() {
  local type="$1" id="$2" tmpfile="$3"

  local target_path
  if [[ "$type" == "s" ]]; then
    local tmux_id="\$$id"
    target_path=$(tmux display-message -p -t "$tmux_id" '#{session_path}' 2>/dev/null)
  elif [[ "$type" == "p" ]]; then
    target_path="$id"
  else
    return
  fi

  local git_dir
  git_dir=$(git -C "$target_path" rev-parse --git-dir 2>/dev/null)

  if [[ "$git_dir" == *"worktrees"* ]]; then
    # Linked worktree: rename branch + move dir + repair linkage.
    local main_wt container
    main_wt=$(git -C "$target_path" worktree list --porcelain \
      | awk '/^worktree /{print $2; exit}')
    container=$(dirname "$main_wt")
    rename_worktree "$main_wt" "$container" "$target_path"
    build_entries > "$tmpfile"

  elif [[ "$type" == "s" ]]; then
    # Not a worktree: rename tmux session only.
    local tmux_id="\$$id"
    local clean_name
    clean_name=$(strip_ansi "$(grep $'^s\t'"$id"$'\t' "$tmpfile" | cut -f3)")
    clean_name="${clean_name#${_ICON_SESSION} }"
    clean_name="${clean_name#(current) }"
    clean_name="${clean_name#(previous) }"
    local rename_output rename_rc rename_key new_name
    rename_output=$(echo "" | fzf $FZF_INLINE \
      --print-query --no-select-1 \
      --query "$clean_name" \
      --prompt "Rename to: " \
      --header "enter:rename  ctrl-bs:cancel" \
      --expect "ctrl-bs")
    rename_rc=$?
    [[ $rename_rc -eq 130 ]] && return
    rename_key=$(printf '%s' "$rename_output" | sed -n '2p')
    [[ "$rename_key" == "ctrl-bs" ]] && return
    new_name=$(sanitize_name "$(printf '%s' "$rename_output" | head -1)")
    [[ -z "$new_name" || "$new_name" == "$clean_name" ]] && return
    tmux rename-session -t "$tmux_id" "$new_name"
    local new_display="${_GREEN}${_ICON_SESSION} ${new_name}${_RESET}"
    NEW_DISPLAY="$new_display" awk -F'\t' -v OFS='\t' -v id="$id" \
        '$1=="s" && $2==id { $3=ENVIRON["NEW_DISPLAY"] } { print }' \
        "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"

  else
    # Project row, not a worktree → nothing to rename.
    tmux display-message -d 2000 "ctrl-r: not a linked worktree"
  fi
}

manage_sessions() {
  # Build the list once and write it to a tmpfile.  Mutating actions (ctrl-d,
  # ctrl-x, ctrl-r) call back into this script via --action, modify the tmpfile,
  # then trigger fzf's reload so the popup stays open without flickering.
  # The while loop only iterates when ctrl-w is cancelled (ctrl-bs in pick_branch).
  local tmpfile
  tmpfile=$(mktemp)
  trap "rm -f '$tmpfile' '${tmpfile}.new'" EXIT
  build_entries > "$tmpfile"

  local self="${BASH_SOURCE[0]}"

  while true; do
    local output fzf_rc
    output=$(
      cat "$tmpfile" \
      | fzf $FZF_POPUP \
          --ansi \
          --with-nth 3 \
          --delimiter $'\t' \
          --prompt "Sessions > " \
          --expect "ctrl-w,ctrl-bs" \
          --header "enter:open ctrl-bs:back ?:preview ctrl-x:delete-session ctrl-r:rename ctrl-w:worktree ctrl-d:remove-worktree" \
          --preview "[ '{1}' = s ] \
                     && tmux capture-pane -e -p -t '\$'{2} 2>/dev/null \
                     || ls '{2}' 2>/dev/null" \
          --preview-window "down:50%:border-top:nofollow:hidden" \
          --bind "?:toggle-preview" \
          --bind "ctrl-d:execute('$self' --action ctrl-d {1} {2} '$tmpfile')+reload(cat '$tmpfile')+pos({n})" \
          --bind "ctrl-x:execute-silent('$self' --action ctrl-x {1} {2} '$tmpfile')+reload(cat '$tmpfile')+pos({n})" \
          --bind "ctrl-r:execute('$self' --action ctrl-r {1} {2} '$tmpfile')+reload(cat '$tmpfile')+pos({n})"
    )
    fzf_rc=$?

    [[ $fzf_rc -eq 130 ]] && return 0  # Esc → close
    [[ -z "$output" ]]    && return 0

    local key line type key2 display
    key=$(printf '%s' "$output" | head -1)
    line=$(printf '%s' "$output" | sed -n '2p')
    type=$(printf '%s' "$line" | cut -f1)    # s, p, or n
    key2=$(printf '%s' "$line" | cut -f2)    # stripped session ID or path
    display=$(printf '%s' "$line" | cut -f3) # display name (may contain ANSI codes)

    [[ "$key" == "ctrl-bs" ]] && return 0

    # ── ctrl-w: create a worktree ─────────────────────────────────────────────
    if [[ "$key" == "ctrl-w" ]]; then
      local repo_path
      if [[ "$type" == "p" ]]; then
        repo_path=$(git -C "$key2" rev-parse --show-toplevel 2>/dev/null)
      else
        local tmux_id="\$${key2}"
        local sess_path
        sess_path=$(tmux display-message -p -t "$tmux_id" '#{session_path}' 2>/dev/null)
        repo_path=$(git -C "$sess_path" rev-parse --show-toplevel 2>/dev/null)
      fi
      if [[ -n "$repo_path" ]]; then
        local container result wt_path pick_rc
        container=$(git -C "$repo_path" worktree list --porcelain \
          | awk '/^worktree /{print $2; exit}' \
          | xargs dirname)
        result=$(pick_branch "$repo_path")
        pick_rc=$?
        [[ $pick_rc -eq 2 ]] && return 0  # Esc → close all
        if [[ $pick_rc -eq 0 ]]; then
          if [[ "$result" == new:* ]]; then
            wt_path=$(add_worktree "$repo_path" "$container" "" "${result#new:}") || continue
          else
            wt_path=$(add_worktree "$repo_path" "$container" "${result#existing:}" "") || continue
          fi
          update_score "$(format_session_name "$wt_path")"
          switch_or_create_session "$wt_path"
          return 0
        fi
      fi
      continue
    fi

    # ── New session sentinel: Enter ───────────────────────────────────────────
    if [[ "$type" == "n" ]]; then
      local name_output name_key new_name
      name_output=$(echo "" | fzf $FZF_POPUP \
        --print-query --no-select-1 \
        --prompt "Session name: " \
        --header "enter:create  ctrl-bs:cancel" \
        --expect "ctrl-bs")
      local name_rc=$?
      [[ $name_rc -eq 130 ]] && continue
      name_key=$(printf '%s' "$name_output" | sed -n '2p')
      [[ "$name_key" == "ctrl-bs" ]] && continue
      new_name=$(sanitize_name "$(printf '%s' "$name_output" | head -1)")
      [[ -z "$new_name" ]] && continue
      update_score "$new_name"
      switch_or_create_session "$HOME" "$new_name"
      return 0
    fi

    # ── Project row: Enter ────────────────────────────────────────────────────
    if [[ "$type" == "p" ]]; then
      local clean_display="${display#${_ICON_PROJECT} }"
      update_score "$clean_display"
      switch_or_create_session "$key2" "$clean_display"
      return 0

    # ── Session row: Enter ────────────────────────────────────────────────────
    else
      local tmux_id="\$${key2}"
      tmux switch-client -t "$tmux_id"
      return 0
    fi
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Normal invocation (C-S-s): run manage_sessions.
# Action invocation (fzf execute / execute-silent binding): run the named mutation on the
# tmpfile and exit.  manage_sessions is never called in this path.
if [[ "$1" == --action ]]; then
  case "$2" in
    ctrl-d) _action_ctrl_d "${@:3}" ;;
    ctrl-x) _action_ctrl_x "${@:3}" ;;
    ctrl-r) _action_ctrl_r "${@:3}" ;;
  esac
  exit
fi

# --display-name <session_path> <session_name>
# Used by the tmux status bar to restore dots that tmux converted to underscores.
# Derives the display name from the session path via format_session_name; falls
# back to the stored session name when the path doesn't round-trip (manual sessions).
if [[ "$1" == --display-name ]]; then
  derived=$(format_session_name "$2")
  [[ "${derived//./_}" == "$3" ]] && printf '%s' "$derived" || printf '%s' "$3"
  exit
fi

manage_sessions
