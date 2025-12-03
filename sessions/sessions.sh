#!/bin/bash

list_projects() {
  fd \
      -H \
      ^.git$ \
      -td \
      -tf \
      --max-depth=5 \
      --prune \
      --format \
      {//} \
      -E \
      node_modules \
      $HOME/Projects \
      $XDG_CONFIG_HOME
}

format_session_name() {
  if [[ "$1" =~ $HOME/* ]]; then
    without_home=${1/$HOME\//} 
    echo ${without_home//./_}
  else
    echo ${1//./_}
  fi
}

switch_or_create_session() {
  session_path=$1
  session_name=$(format_session_name $session_path)

  if ! tmux has-session -t $session_name; then
    tmux new-session -c $session_path -s $session_name -d
  fi

  tmux switch -t $session_name
}

switch_or_create_session $(list_projects | fzf --tmux bottom,50%)
