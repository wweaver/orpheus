#!/bin/sh
# Minimal pianobar stand-in for tests.
# Honors $XDG_CONFIG_HOME/pianobar/config for fifo and event_command paths.
# On start, fires a "userlogin" event. Then reads FIFO forever; on 'q' exits 0.
set -eu

CFG="$XDG_CONFIG_HOME/pianobar/config"
FIFO=$(grep '^fifo = ' "$CFG" | head -n1 | sed 's/^fifo = //')
EVT=$(grep '^event_command = ' "$CFG" | head -n1 | sed 's/^event_command = //')

# Fire userlogin ok.
printf 'pRet=1\npRetStr=OK\nwRet=0\nwRetStr=OK\n' | "$EVT" userlogin

# Read commands forever.
while IFS= read -r cmd < "$FIFO"; do
  case "$cmd" in
    q) exit 0 ;;
    *) : ;;
  esac
done
