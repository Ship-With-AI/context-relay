#!/usr/bin/env bash
# context-relay supervisor: run an agent command again and again, each run a fresh session
# that rehydrates from .relay/HANDOFF.md. Harness-agnostic.
#
#   relay-loop.sh [--max N] [--stall N] [--pause S] -- <command...>
#
#   relay-loop.sh -- claude -p "Continue the task in the context-relay state. Update .relay/HANDOFF.md before you stop."
#   relay-loop.sh -- codex exec "Continue the task in the context-relay state. Update .relay/HANDOFF.md before you stop."
#   relay-loop.sh -- omp "Continue from the context-relay state."     # with RELAY_EOL_ACTION=exit
#
# Stops when HANDOFF.md has a "Status: done" line (exit 0), after --max runs (default 20,
# exit 4), or after --stall consecutive runs (default 2) that left HANDOFF.md unchanged (exit 3).
set -eu

usage() { echo "usage: relay-loop.sh [--max N] [--stall N] [--pause S] -- <command...>" >&2; exit 2; }
max=20 stall=2 pause=2
while [ $# -gt 0 ]; do
  case "$1" in
    --max) max="$2"; shift 2 ;;
    --stall) stall="$2"; shift 2 ;;
    --pause) pause="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ $# -gt 0 ] || usage

cd "${RELAY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
h=.relay/HANDOFF.md
digest() { if [ -f "$h" ]; then cksum <"$h"; else echo none; fi; }
is_done() { [ -f "$h" ] && grep -qiE '^Status:[[:space:]]*done' "$h"; }

run=0 still=0
while [ "$run" -lt "$max" ]; do
  if is_done; then echo "relay-loop: HANDOFF.md says done after $run runs" >&2; exit 0; fi
  run=$((run + 1))
  before="$(digest)"
  echo "relay-loop: run $run/$max: $*" >&2
  "$@" || echo "relay-loop: run $run exited with $?" >&2
  if [ "$(digest)" = "$before" ]; then still=$((still + 1)); else still=0; fi
  if [ "$still" -ge "$stall" ]; then
    echo "relay-loop: HANDOFF.md unchanged for $still runs, stopping" >&2
    exit 3
  fi
  sleep "$pause"
done
if is_done; then echo "relay-loop: HANDOFF.md says done after $run runs" >&2; exit 0; fi
echo "relay-loop: reached --max $max" >&2
exit 4
