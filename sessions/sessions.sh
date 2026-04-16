#!/bin/bash
# Session manager invoked by C-S-s.
# Lists running tmux sessions with a live preview pane, plus a "[+ new session]"
# entry that opens the project/manual-session picker.
# Ctrl-D kills, Ctrl-R renames; both keep the picker open.

source "$(dirname "$0")/common.sh"

# Manual sessions: "display_name:working_directory"
# The display_name becomes the tmux session name; the path sets the cwd.
MANUAL_SESSIONS=(
  "Notes:$HOME/Notes"
  "default:$HOME"
)

# Slightly taller popup to give the preview pane more vertical space.
SESSION_POPUP="--tmux center,100%,100% --reverse --no-scrollbar --no-info --no-separator --no-border"

# Emit one "session_name<TAB>cwd" line per discoverable project, including
# git repos under ~/Projects/ and $XDG_CONFIG_HOME and all manual entries.
#
# fd flags used:
#   -H              include hidden directories (e.g. ~/.config)
#   ^.git$          match items named exactly ".git" (anchored regex)
#   -td -tf         match both directory-type and file-type .git entries
#                   (bare repos store .git as a file, not a directory)
#   --max-depth=6   cap recursion to avoid very deep trees
#   --prune         do not descend into matched directories
#   --format {//}   output the parent of the match (the repo root, not .git)
#   -E node_modules skip JS dependency trees
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

  for entry in "${MANUAL_SESSIONS[@]}"; do
    printf "%s\t%s\n" "${entry%%:*}" "${entry#*:}"
  done
}

# Open the project/manual-session picker, then switch to or create a session.
# Return codes: 0 = switched, 1 = ctrl-bs (go back), 2 = Esc (close all).
pick_new_session() {
  local selected rc
  selected=$(
    list_projects \
      | sort_by_score \
      | fzf $FZF_POPUP \
          --with-nth 1 \
          --delimiter $'\t' \
          --prompt "New session > " \
          --expect "ctrl-bs"
  )
  rc=$?
  [[ $rc -eq 130 ]] && return 2        # Esc → close everything
  [[ -z "$selected" ]] && return 2     # no projects listed

  local key item
  key=$(printf '%s' "$selected" | head -1)
  item=$(printf '%s' "$selected" | sed -n '2p')
  [[ "$key" == "ctrl-bs" ]] && return 1  # ctrl-bs → go back to session list
  [[ -z "$item" ]] && return 2

  local session_name session_cwd
  session_name=$(printf '%s' "$item" | cut -f1)
  session_cwd=$(printf '%s' "$item" | cut -f2)

  update_score "$session_name"
  switch_or_create_session "$session_cwd" "$session_name"
}

# Main loop — rebuild list and reopen fzf after each kill/rename action.
# Esc closes the picker.  Ctrl-Bs at the session list closes (no previous state).
manage_sessions() {
  while true; do
    # Strip the leading '$' from session IDs (e.g. "$13" → "13") so the value
    # can be safely substituted into the fzf --preview command.  If the raw "$N"
    # form were used, the shell that fzf spawns for the preview would expand
    # "$13" as "${1}3" (positional param 1 concatenated with "3"), corrupting
    # the target.  The '$' is reconstructed below with the '\$' trick.
    local entries
    entries=$(tmux ls -F "#{session_id}"$'\t'"#{session_name}" 2>/dev/null \
      | sed 's/^\$//')
    [[ -z "$entries" ]] && return 0

    local output fzf_rc
    output=$(
      # Sentinel row: field 1 = "new", field 2 = display label.
      # The preview command checks for the "new" sentinel to skip capture-pane.
      { printf 'new\t[+ new session]\n'; printf '%s\n' "$entries"; } \
      | fzf $SESSION_POPUP \
          --with-nth 2 \
          --delimiter $'\t' \
          --prompt "Sessions > " \
          --expect "ctrl-d,ctrl-r,ctrl-bs" \
          --header "enter:switch  ctrl-d:kill  ctrl-r:rename  ctrl-bs:back" \
          --preview "[ '{1}' = new ] && echo 'Open project picker to start a new session' || tmux capture-pane -e -p -t '\$'{1} 2>/dev/null" \
          --preview-window "up:50%:border-bottom:nofollow:nohidden"
    )
    fzf_rc=$?

    [[ $fzf_rc -eq 130 ]] && return 0  # Esc → close
    [[ -z "$output" ]] && return 0

    local key line session_id session_name
    key=$(printf '%s' "$output" | head -1)
    line=$(printf '%s' "$output" | sed -n '2p')
    session_id=$(printf '%s' "$line" | cut -f1)
    session_name=$(printf '%s' "$line" | cut -f2)

    [[ "$key" == "ctrl-bs" ]] && return 0  # ctrl-bs at top level → close

    # [+ new session] — open project picker (Enter only; ctrl-d/ctrl-r ignored).
    if [[ "$session_id" == "new" ]]; then
      if [[ -z "$key" ]]; then
        pick_new_session
        case $? in
          0) return 0 ;;  # session switched
          2) return 0 ;;  # Esc in sub-picker → close all
          # 1 (ctrl-bs) = go back → fall through to continue
        esac
      fi
      continue
    fi

    # Reconstruct the full $N session ID from the stripped numeric field.
    # \$ inside double-quotes is a literal '$'; $(...) is a command substitution.
    local tmux_id="\$$(printf '%s' "$session_id")"

    if [[ "$key" == "ctrl-d" ]]; then
      tmux kill-session -t "$tmux_id"
      # Loop: reopen with updated list.

    elif [[ "$key" == "ctrl-r" ]]; then
      local rename_output rename_rc rename_key new_name
      rename_output=$(echo "" | fzf $FZF_POPUP \
        --print-query --no-select-1 \
        --query "$session_name" \
        --prompt "Rename to: " \
        --expect "ctrl-bs")
      rename_rc=$?
      [[ $rename_rc -eq 130 ]] && return 0                    # Esc → close
      rename_key=$(printf '%s' "$rename_output" | sed -n '2p')
      [[ "$rename_key" == "ctrl-bs" ]] && continue            # ctrl-bs → back
      new_name=$(printf '%s' "$rename_output" | head -1)
      new_name=$(printf '%s' "$new_name" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]/-/g')
      [[ -z "$new_name" || "$new_name" == "$session_name" ]] && continue
      tmux rename-session -t "$tmux_id" "$new_name"
      # Loop: reopen with updated list.

    else
      tmux switch-client -t "$tmux_id"
      return 0
    fi
  done
}

manage_sessions
