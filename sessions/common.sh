#!/bin/bash
# Shared utilities sourced by sessions.sh and worktree.sh.

export BAT_THEME="Catppuccin Mocha"

# Catppuccin Mocha palette for fzf.
export FZF_DEFAULT_OPTS="\
--color=bg+:#313244,bg:#1E1E2E,spinner:#F5E0DC,hl:#F38BA8 \
--color=fg:#CDD6F4,header:#F38BA8,info:#CBA6F7,pointer:#F5E0DC \
--color=marker:#B4BEFE,fg+:#CDD6F4,prompt:#CBA6F7,hl+:#F38BA8 \
--color=selected-bg:#45475A \
--color=border:#6C7086,label:#CDD6F4"

# Shared fzf flags: bottom-anchored tmux popup, 50% height, minimal chrome.
FZF_POPUP="--tmux center,100%,100% --reverse --no-scrollbar --no-info --no-separator --no-border"

# TSV file storing per-session pick scores for recency ranking.
SCORE_FILE="$HOME/.local/share/tmux-sessions/scores.tsv"

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

# Read "session_name<TAB>cwd" lines from stdin, sort them by current pick score
# (highest first), and write the same format to stdout.
#
# Each stored score is decayed to the present using the same half-life formula
# as update_score before comparison.  Entries absent from the score file sort
# after all scored entries (score treated as 0).
sort_by_score() {
  local now half_life
  now=$(date +%s)
  half_life=$((7 * 24 * 3600))

  awk -F'\t' \
      -v score_file="$SCORE_FILE" -v now="$now" -v hl="$half_life" '
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
      # Zero-pad to 20 chars so lexicographic and numeric sort agree.
      printf "%020.6f\t%s\n", score, $0
    }
  ' | sort -t$'\t' -k1 -rn | cut -f2-
}
