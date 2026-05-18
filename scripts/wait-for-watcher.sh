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
#
# Two corner cases the script handles, both with a clear note so the
# caller knows what happened:
#
# 1. Baseline captured *after* the rebuild already finished. The
#    sentinel count is already past where the caller thought it was;
#    no future advance will arrive until a fresh edit. The script
#    detects this by watching the log file's byte size: if the log
#    doesn't grow for a few seconds *and* the sentinel hasn't moved,
#    the rebuild we're waiting on is already in the past, so exit 0
#    rather than hang on a deadline.
#
# 2. Dune watch mode skips a rebuild when the file's content hash is
#    unchanged (a `touch` alone, for instance). The same idle-bail
#    path covers this: the log won't grow, and we exit 0 with a note.
#
# Hard ceiling stays at 60 seconds so a genuinely stuck watcher still
# surfaces quickly rather than holding the foreground for minutes.

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

hard_deadline=$(($(date +%s) + 60))
idle_threshold_seconds=5

count_sentinel() {
  grep -c "waiting for filesystem" "$log" 2>/dev/null || echo 0
}

log_size() { wc -c < "$log" | tr -d ' '; }

previous_size=$(log_size)
last_growth_at=$(date +%s)

while :; do
  current=$(count_sentinel)
  if [ "$current" -gt "$baseline" ]; then
    tail -100 "$log"
    exit 0
  fi

  now=$(date +%s)
  if [ "$now" -ge "$hard_deadline" ]; then
    echo "wait-for-watcher: timed out after 60s (baseline=$baseline current=$current log=$log)" >&2
    tail -50 "$log" >&2
    exit 1
  fi

  current_size=$(log_size)
  if [ "$current_size" != "$previous_size" ]; then
    previous_size=$current_size
    last_growth_at=$now
  else
    idle_for=$((now - last_growth_at))
    if [ "$idle_for" -ge "$idle_threshold_seconds" ]; then
      echo "wait-for-watcher: log idle for ${idle_for}s and sentinel still at ${current} (baseline=${baseline}). Likely a no-op rebuild (content hash unchanged) or baseline captured post-rebuild. Exiting 0." >&2
      tail -50 "$log"
      exit 0
    fi
  fi

  sleep 0.5
done
