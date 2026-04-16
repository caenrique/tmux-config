#!/bin/bash
# Session manager invoked by C-S-s.
# Shows a unified list: running sessions (green, sorted by recency) at the top,
# followed by projects without a session.  All actions are in a single fzf picker.
#   Enter     — switch to session / open project as new session
#   Ctrl-W    — open branch picker to create a worktree for the row's repo
#   Ctrl-D    — kill session + delete worktree (no prompt); list updates in place
#   Ctrl-X    — kill session only; entry becomes a project row
#   Ctrl-R    — rename session; list updates in place
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
_RESET=$'\033[0m'

# Emit the unified 3-field TSV list consumed by manage_sessions.
# Format: type<TAB>key<TAB>display
#   s <TAB> stripped_id <TAB> <green>session_name<reset>    ← running session
#   p <TAB> path        <TAB> display_name                  ← project w/o session
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

  # Pin the previous session at the very top (if it exists and differs from current).
  if [[ -n "$prev_session" && "$prev_session" != "$current_session" ]]; then
    local prev_id
    prev_id=$(get_session_id "$prev_session")
    if [[ -n "$prev_id" ]]; then
      printf "s\t%s\t%s%s%s\n" "${prev_id#\$}" "$_GREEN" "$prev_session" "$_RESET"
    fi
  fi

  # Sessions: field 3 = session working dir, used by sort_by_score for the
  # path-prefix boost (longer shared prefix with pane_path → higher rank).
  tmux ls -F "#{session_id}"$'\t'"#{session_name}"$'\t'"#{session_path}" 2>/dev/null \
    | sed 's/^\$//' \
    | while IFS=$'\t' read -r raw_id name sess_path; do
        [[ "$name" == "$prev_session" ]] && continue
        printf "%s\t%s\t%s\n" "$name" "$raw_id" "$sess_path"
      done \
    | sort_by_score "$pane_path" \
    | while IFS=$'\t' read -r name raw_id _path; do
        printf "s\t%s\t%s%s%s\n" "$raw_id" "$_GREEN" "$name" "$_RESET"
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
        printf "p\t%s\t%s\n" "$path" "$name"
      done
}

# ── Action functions ──────────────────────────────────────────────────────────
# Called as: sessions.sh --action <name> <type> <id> <tmpfile>
# Each is a no-op when type != s (e.g. ctrl-d pressed on a project row).

# ctrl-d: kill session, then remove its worktree if applicable.
_action_ctrl_d() {
  local type="$1" id="$2" tmpfile="$3"
  [[ "$type" != "s" ]] && return
  local tmux_id="\$$id"
  local sess_path
  sess_path=$(tmux display-message -p -t "$tmux_id" '#{session_path}' 2>/dev/null)
  tmux kill-session -t "$tmux_id" 2>/dev/null
  local git_dir
  git_dir=$(git -C "$sess_path" rev-parse --git-dir 2>/dev/null)
  if [[ "$git_dir" == *"worktrees"* ]]; then
    local wt_repo
    wt_repo=$(git -C "$sess_path" rev-parse --show-toplevel 2>/dev/null)
    [[ -n "$wt_repo" ]] && git -C "$wt_repo" worktree remove --force "$sess_path" >&2
  fi
  grep -v $'^s\t'"$id"$'\t' "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
}

# ctrl-x: kill session only; convert the entry to a project row in place.
_action_ctrl_x() {
  local type="$1" id="$2" tmpfile="$3"
  [[ "$type" != "s" ]] && return
  local tmux_id="\$$id"
  local sess_path
  sess_path=$(tmux display-message -p -t "$tmux_id" '#{session_path}' 2>/dev/null)
  local current_display
  current_display=$(grep $'^s\t'"$id"$'\t' "$tmpfile" | cut -f3)
  local clean_name
  clean_name=$(printf '%s' "$current_display" | sed $'s/\033\\[[0-9;]*m//g')
  tmux kill-session -t "$tmux_id" 2>/dev/null
  awk -F'\t' -v OFS='\t' -v id="$id" -v path="$sess_path" -v name="$clean_name" \
      '$1=="s" && $2==id { $1="p"; $2=path; $3=name } { print }' \
      "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
}

# ctrl-r: rename session via a nested fzf prompt; update display in place.
_action_ctrl_r() {
  local type="$1" id="$2" tmpfile="$3"
  [[ "$type" != "s" ]] && return
  local tmux_id="\$$id"
  local current_display
  current_display=$(grep $'^s\t'"$id"$'\t' "$tmpfile" | cut -f3)
  local clean_name
  clean_name=$(printf '%s' "$current_display" | sed $'s/\033\\[[0-9;]*m//g')
  local rename_output rename_rc rename_key new_name
  rename_output=$(echo "" | fzf $FZF_POPUP \
    --print-query --no-select-1 \
    --query "$clean_name" \
    --prompt "Rename to: " \
    --header "enter:rename  ctrl-bs:cancel" \
    --expect "ctrl-bs")
  rename_rc=$?
  [[ $rename_rc -eq 130 ]] && return
  rename_key=$(printf '%s' "$rename_output" | sed -n '2p')
  [[ "$rename_key" == "ctrl-bs" ]] && return
  new_name=$(printf '%s' "$rename_output" | head -1)
  new_name=$(printf '%s' "$new_name" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]/-/g')
  [[ -z "$new_name" || "$new_name" == "$clean_name" ]] && return
  tmux rename-session -t "$tmux_id" "$new_name"
  local new_display="${_GREEN}${new_name}${_RESET}"
  NEW_DISPLAY="$new_display" awk -F'\t' -v OFS='\t' -v id="$id" \
      '$1=="s" && $2==id { $3=ENVIRON["NEW_DISPLAY"] } { print }' \
      "$tmpfile" > "${tmpfile}.new" && mv "${tmpfile}.new" "$tmpfile"
}

manage_sessions() {
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
          --header "enter:open  ctrl-w:worktree  ctrl-d:wt+kill  ctrl-x:kill  ctrl-r:rename  ctrl-bs:back" \
          --preview "[ '{1}' = s ] \
                     && tmux capture-pane -e -p -t '\$'{2} 2>/dev/null \
                     || ls '{2}' 2>/dev/null" \
          --preview-window "up:50%:border-bottom:nofollow:nohidden" \
          --bind "ctrl-d:execute-silent('$self' --action ctrl-d {1} {2} '$tmpfile')+reload(cat '$tmpfile')+pos({n})" \
          --bind "ctrl-x:execute-silent('$self' --action ctrl-x {1} {2} '$tmpfile')+reload(cat '$tmpfile')+pos({n})" \
          --bind "ctrl-r:execute-silent('$self' --action ctrl-r {1} {2} '$tmpfile')+reload(cat '$tmpfile')+pos({n})"
    )
    fzf_rc=$?

    [[ $fzf_rc -eq 130 ]] && return 0  # Esc → close
    [[ -z "$output" ]]    && return 0

    local key line type key2 display
    key=$(printf '%s' "$output" | head -1)
    line=$(printf '%s' "$output" | sed -n '2p')
    type=$(printf '%s' "$line" | cut -f1)    # s or p
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

    # ── Project row: Enter ────────────────────────────────────────────────────
    elif [[ "$type" == "p" ]]; then
      update_score "$display"
      switch_or_create_session "$key2" "$display"
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
if [[ "$1" == --action ]]; then
  case "$2" in
    ctrl-d) _action_ctrl_d "${@:3}" ;;
    ctrl-x) _action_ctrl_x "${@:3}" ;;
    ctrl-r) _action_ctrl_r "${@:3}" ;;
  esac
  exit
fi

manage_sessions
