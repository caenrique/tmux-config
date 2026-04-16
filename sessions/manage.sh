#!/bin/bash
# Session manager invoked by C-S-a.
# Lists all running tmux sessions in an fzf popup with a per-session preview
# of its windows.  Ctrl-D and Ctrl-R keep the picker open.

source "$(dirname "$0")/common.sh"

# Slightly taller popup to give the preview pane more vertical space.
SESSION_POPUP="--tmux center,100%,100% --reverse --no-scrollbar --no-info --no-separator --no-border"

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
      printf '%s\n' "$entries" \
      | fzf $SESSION_POPUP \
          --with-nth 2 \
          --delimiter $'\t' \
          --prompt "Sessions > " \
          --expect "ctrl-d,ctrl-r,ctrl-bs" \
          --header "enter:switch  ctrl-d:kill  ctrl-r:rename  ctrl-bs:back" \
          --preview "tmux capture-pane -e -p -t '\$'{1} 2>/dev/null" \
          --preview-window "up:50%:border-bottom:nofollow:nohidden"
    )
    fzf_rc=$?

    [[ $fzf_rc -eq 130 ]] && return 0  # Esc → close
    [[ -z "$output" ]] && return 0

    local key line session_id session_name
    key=$(printf '%s' "$output" | head -1)
    line=$(printf '%s' "$output" | sed -n '2p')
    # Reconstruct the full $N session ID from the stripped numeric field.
    # \$ inside double-quotes is a literal '$'; $(...) is a command substitution.
    session_id="\$$(printf '%s' "$line" | cut -f1)"
    session_name=$(printf '%s' "$line" | cut -f2)

    [[ "$key" == "ctrl-bs" ]] && return 0  # ctrl-bs at top level → close

    if [[ "$key" == "ctrl-d" ]]; then
      tmux kill-session -t "$session_id"
      # Loop: reopen with updated list.

    elif [[ "$key" == "ctrl-r" ]]; then
      local rename_output rename_rc rename_key new_name
      rename_output=$(echo "" | fzf $FZF_POPUP \
        --print-query --no-select-1 \
        --query "$session_name" \
        --prompt "Rename to: " \
        --expect "ctrl-bs")
      rename_rc=$?
      [[ $rename_rc -eq 130 ]] && return 0                      # Esc → close
      rename_key=$(printf '%s' "$rename_output" | sed -n '2p')
      [[ "$rename_key" == "ctrl-bs" ]] && continue               # ctrl-bs → back
      new_name=$(printf '%s' "$rename_output" | head -1)
      new_name=$(printf '%s' "$new_name" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]/-/g')
      [[ -z "$new_name" || "$new_name" == "$session_name" ]] && continue
      tmux rename-session -t "$session_id" "$new_name"
      # Loop: reopen with updated list.

    else
      tmux switch-client -t "$session_id"
      return 0
    fi
  done
}

manage_sessions
