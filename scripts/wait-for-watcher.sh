#!/usr/bin/env bash
# Wait for the dune watcher to finish its next rebuild cycle, then
# print the tail of the watcher log so the caller can read the result.
#
# The watcher prints "waiting for filesystem changes" at the end of
# every rebuild -- green or red -- so a fresh occurrence past a
# pre-edit baseline marks "the rebuild this edit triggered is done."
#
# Usage:
#   before=$(grep -c "waiting for filesystem" "$LOG")
#   # ... make file edits ...
#   scripts/wait-for-watcher.sh "$LOG" "$before"
#
# Intended for Claude to run with run_in_background so a single
# notification fires when the rebuild settles -- no fixed sleep, no
# generic Monitor timeout.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <watcher-log-path> <baseline-sentinel-count>" >&2
  exit 2
fi

log="$1"
baseline="$2"

if [ ! -f "$log" ]; then
  echo "watcher log not found: $log" >&2
  exit 1
fi

# Bound the wait so a misconfigured invocation does not run forever.
# Five minutes is long enough for any realistic incremental rebuild
# of this project and short enough that a stuck wait surfaces fast.
deadline=$(($(date +%s) + 300))

count_sentinel() {
  grep -c "waiting for filesystem" "$log" 2>/dev/null || echo 0
}

while :; do
  current=$(count_sentinel)
  if [ "$current" -gt "$baseline" ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "wait-for-watcher: timed out after 5 minutes" >&2
    echo "baseline=$baseline current=$current log=$log" >&2
    exit 1
  fi
  sleep 0.5
done

tail -100 "$log"
