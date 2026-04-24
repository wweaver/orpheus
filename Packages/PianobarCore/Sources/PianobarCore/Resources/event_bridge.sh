#!/bin/sh
# Forwards a pianobar event to the PianobarGUI app via a Unix domain socket.
# pianobar invokes this with the event name as $1 and the key=value payload on stdin.
# PIANOBAR_GUI_SOCK must be exported in the environment by PianobarProcess.
set -eu
if [ -z "${PIANOBAR_GUI_SOCK:-}" ]; then exit 0; fi

# Buffer stdin once so we can both forward it and (optionally) append a copy
# to a debug log for diagnosing event-payload problems (e.g. missing coverArt).
PAYLOAD=$(cat)

if [ -n "${PIANOBAR_GUI_EVENT_LOG:-}" ]; then
  {
    printf '=== %s %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    printf '%s\n' "$PAYLOAD"
  } >> "$PIANOBAR_GUI_EVENT_LOG" 2>/dev/null || true
fi

# Record format: "$1\n<stdin>\n\x1e". Use printf for portability.
{
  printf '%s\n' "$1"
  printf '%s' "$PAYLOAD"
  printf '\036'
} | /usr/bin/nc -U "$PIANOBAR_GUI_SOCK" >/dev/null 2>&1 || true
