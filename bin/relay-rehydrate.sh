#!/usr/bin/env bash
# context-relay: print the current working state for injection at session start.
#
# Harness-neutral. Claude Code and Codex add SessionStart hook stdout to the
# model context; the omp/pi extension calls this script and injects its output.
# Prints nothing (exit 0) when no state file exists.
#
# Sources: .relay/sources lists find(1) -path patterns relative to the repo root,
# one per line, in priority order; for each pattern the newest match is used.
# Without that file the only source is .relay/HANDOFF.md.
#
# Env: RELAY_ROOT (default: git toplevel, else cwd). Settings come from .relay/config;
# an environment variable of the same name overrides the file.
set -eu

root="${RELAY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root"

relay_cfg() { # <key> <default>: env, then .relay/config, then default
  v="$(printenv "$1" 2>/dev/null || true)"
  if [ -z "$v" ] && [ -f .relay/config ]; then
    v="$(sed -n "s/^$1=\([^#[:space:]]*\).*/\1/p" .relay/config | tail -n 1)"
  fi
  printf '%s' "${v:-$2}"
}
budget="$(relay_cfg RELAY_MAX_BYTES 16000)"

patterns=""
if [ -f .relay/sources ]; then
  patterns="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' .relay/sources | grep -v '^$' || true)"
else
  patterns=".relay/HANDOFF.md"
fi

newest() {
  best=""
  while IFS= read -r f; do
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
  done <<EOF
$(find . -path "./$1" -type f -not -path './.git/*' -not -path '*/node_modules/*' 2>/dev/null)
EOF
  printf '%s' "${best#./}"
}

files=""
for p in $patterns; do
  f="$(newest "$p")"
  [ -n "$f" ] || continue
  case "
$files
" in *"
$f
"*) continue ;; esac
  files="${files:+$files
}$f"
done

[ -n "$files" ] || exit 0

echo "<context-relay>"
echo "Working state restored from a previous session or context window. It is a lead, not the truth:"
echo "verify it against git and the repo before acting, and fix it if stale. Keep it current at milestones."
remaining="$budget"
echo "$files" | while IFS= read -r f; do
  [ "$remaining" -gt 0 ] || break
  stamp="$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"
  size="$(wc -c <"$f" | tr -d ' ')"
  echo
  echo "## $f (modified $stamp)"
  head -c "$remaining" "$f"
  if [ "$size" -gt "$remaining" ]; then
    echo
    echo "[truncated at $remaining of $size bytes; read $f for the rest]"
    remaining=0
  else
    remaining=$((remaining - size))
  fi
done
echo
echo "</context-relay>"
