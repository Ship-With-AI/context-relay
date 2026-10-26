#!/usr/bin/env bash
# context-relay SessionStart hook for Claude Code and Codex.
#
# Reads the hook JSON on stdin, counts compactions and tracks age per session in
# .relay/state/, prints the rehydrated working state, and appends an end-of-life
# notice once RELAY_EOL_COMPACTIONS or RELAY_EOL_HOURS is reached. Stdout of a
# SessionStart hook becomes model context in both harnesses.
set -eu

root="${RELAY_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root"
here="$(cd "$(dirname "$0")" && pwd)"

relay_cfg() { # <key> <default>: env, then .relay/config, then default
  v="$(printenv "$1" 2>/dev/null || true)"
  if [ -z "$v" ] && [ -f .relay/config ]; then
    v="$(sed -n "s/^$1=\([^#[:space:]]*\).*/\1/p" .relay/config | tail -n 1)"
  fi
  printf '%s' "${v:-$2}"
}

input="$(tr -d '\n')"
field() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
sid="$(field session_id)"
src="$(field source)"
sid="$(printf '%s' "${sid:-unknown}" | tr -c 'A-Za-z0-9_-' '_')"
src="${src:-startup}"

state=".relay/state"
mkdir -p "$state"
find "$state" -type f -mtime +30 -delete 2>/dev/null || true
f="$state/$sid"
now="$(date +%s)"
if [ ! -f "$f" ] || [ "$src" = clear ]; then echo "$now 0" >"$f"; fi
read -r started count <"$f"
if [ "$src" = compact ]; then
  count=$((count + 1))
  echo "$started $count" >"$f"
fi

"$here/relay-rehydrate.sh"

action="$(relay_cfg RELAY_EOL_ACTION restart)"
[ "$action" != off ] || exit 0
max_c="$(relay_cfg RELAY_EOL_COMPACTIONS 3)"
max_h="$(relay_cfg RELAY_EOL_HOURS 8)"
age_h=$(((now - started) / 3600))
reason=""
if [ "$max_c" -gt 0 ] && [ "$count" -ge "$max_c" ]; then reason="$count compactions (limit $max_c)"; fi
if [ -z "$reason" ] && [ "$max_h" -gt 0 ] && [ "$age_h" -ge "$max_h" ]; then reason="${age_h}h old (limit ${max_h}h)"; fi
[ -n "$reason" ] || exit 0

echo
echo "<context-relay-eol>"
echo "This session reached end of life: $reason. Do not start new work in it."
echo "1. Finish the current step."
echo "2. Update .relay/HANDOFF.md so a fresh session can continue from it alone."
if [ "$action" = restart ]; then
  echo "3. Tell the user: \"Session end of life: run /clear (Claude Code) or /new (Codex). The fresh session reloads the handoff automatically.\""
else
  echo "3. Tell the user the session reached end of life."
fi
echo "</context-relay-eol>"
