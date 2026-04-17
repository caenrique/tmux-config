#!/bin/bash
# Background fetch + fzf reload helper invoked by pick_branch in common.sh.
# Args: $1=repo_path  $2=tmpfile  $3=fzf_port  $4=header_base
#
# Forks all work to background immediately so callers (execute-silent) return
# at once and the picker stays fully interactive during the fetch.

source "$(dirname "$0")/common.sh"

_repo="$1"; _file="$2"; _port="$3"; _header="$4"

(
  _spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  _i=0

  # Spinner loop; brief delay lets fzf open its listener first.
  (
    sleep 0.3
    while true; do
      curl -s --max-time 0.5 -XPOST "localhost:$_port" \
        -d "change-header($_header ${_spin[$((_i % 10))]} fetching...)" 2>/dev/null || true
      sleep 0.12
      (( _i++ ))
    done
  ) &
  _sp=$!

  git -C "$_repo" fetch --all --quiet 2>/dev/null
  _gen_branch_picker_entries "$_repo" > "$_file"

  kill "$_sp" 2>/dev/null; wait "$_sp" 2>/dev/null
  curl -s --max-time 2 -XPOST "localhost:$_port" \
    -d "change-header($_header)+reload(cat '$_file')" 2>/dev/null || true
) &
disown
