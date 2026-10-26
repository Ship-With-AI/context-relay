#!/usr/bin/env bash
# context-relay installer.
#   install.sh [--flavor plain|gsd] [--harness omp,pi,claude,codex] <project-dir>
# Copies the contract files into <project-dir>/.relay, wires the chosen harnesses with the
# rollover threshold from .relay/config, and appends the agent rule to AGENTS.md or CLAUDE.md.
# Idempotent: existing files are left alone; existing harness config is never overwritten.
set -euo pipefail

kit="$(cd "$(dirname "$0")" && pwd)"
flavor=plain
harness=omp
while [ $# -gt 1 ]; do
  case "$1" in
    --flavor) flavor="$2"; shift 2 ;;
    --harness) harness="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ $# -eq 1 ] || { echo "usage: install.sh [--flavor plain|gsd] [--harness omp,pi,claude,codex] <project-dir>" >&2; exit 2; }
dest="$(cd "$1" && pwd)"
note() { printf '  %s\n' "$*"; }

echo "context-relay → $dest (flavor: $flavor, harness: $harness)"
mkdir -p "$dest/.relay/bin"
for s in relay-rehydrate.sh relay-hook.sh relay-loop.sh; do
  cp "$kit/bin/$s" "$dest/.relay/bin/$s" && chmod +x "$dest/.relay/bin/$s"
done
note ".relay/bin/{relay-rehydrate,relay-hook,relay-loop}.sh"
for f in TEMPLATE.md config; do
  [ -f "$dest/.relay/$f" ] || { cp "$kit/$f" "$dest/.relay/$f"; note ".relay/$f"; }
done

if [ ! -f "$dest/.relay/sources" ]; then
  case "$flavor" in
    plain) printf '%s\n' ".relay/HANDOFF.md" >"$dest/.relay/sources" ;;
    gsd) printf '%s\n' "# GSD owns phase state; the relay injects it automatically." \
      ".planning/*.continue-here.md" ".planning/STATE.md" ".relay/HANDOFF.md" >"$dest/.relay/sources" ;;
    *) echo "unknown flavor: $flavor" >&2; exit 2 ;;
  esac
  note ".relay/sources ($flavor)"
fi

cfg() { sed -n "s/^$1=\([^#[:space:]]*\).*/\1/p" "$dest/.relay/config" | tail -n 1; }
pct="$(cfg RELAY_COMPACT_AT_PERCENT)"; pct="${pct:-60}"
tok="$(cfg RELAY_COMPACT_AT_TOKENS)"; tok="${tok:-120000}"

gi="$dest/.gitignore"
for line in '.relay/archive/' '.relay/state/'; do
  grep -qxF "$line" "$gi" 2>/dev/null || { echo "$line" >>"$gi"; note ".gitignore += $line"; }
done

rules=""
for f in AGENTS.md CLAUDE.md; do [ -f "$dest/$f" ] && [ ! -L "$dest/$f" ] && { rules="$dest/$f"; break; }; done
if [ -z "$rules" ]; then
  echo "  ! no AGENTS.md/CLAUDE.md: paste $kit/AGENTS.relay.md into your agent rules"
elif grep -q 'context-relay:begin' "$rules"; then
  note "$(basename "$rules") already has the relay rule"
else
  { echo; cat "$kit/AGENTS.relay.md"; } >>"$rules"
  note "$(basename "$rules") += relay rule"
fi

IFS=, read -r -a hs <<<"$harness"
for h in "${hs[@]}"; do
  case "$h" in
    omp|pi)
      ext="$dest/.omp/extensions"; conf="$dest/.omp/config.yml"
      [ "$h" = pi ] && ext="$dest/.pi/extensions" && conf=""
      mkdir -p "$ext"
      cp "$kit/omp/context-relay.ts" "$ext/context-relay.ts"
      note "${ext#"$dest"/}/context-relay.ts"
      if [ -z "$conf" ]; then
        echo "  ! pi: set compaction.reserveTokens in .pi/settings.json to roll over near ${pct}%"
      elif [ -f "$conf" ] && grep -q '^compaction:' "$conf"; then
        echo "  ! .omp/config.yml already has compaction:, merge $kit/omp/config.yml by hand (thresholdPercent: $pct)"
      else
        { [ -f "$conf" ] && echo; sed "s/thresholdPercent: [0-9]*/thresholdPercent: $pct/" "$kit/omp/config.yml"; } >>"$conf"
        note ".omp/config.yml += compaction (thresholdPercent: $pct)"
      fi ;;
    claude)
      s="$dest/.claude/settings.json"
      if [ -f "$s" ]; then
        echo "  ! $s exists, merge $kit/claude/settings.json by hand (window: $tok)"
      else
        mkdir -p "$dest/.claude"
        sed "s/\"CLAUDE_CODE_AUTO_COMPACT_WINDOW\": \"[0-9]*\"/\"CLAUDE_CODE_AUTO_COMPACT_WINDOW\": \"$tok\"/" "$kit/claude/settings.json" >"$s"
        note ".claude/settings.json (auto-compact window: $tok)"
      fi ;;
    codex)
      echo "  ! Codex: merge into ~/.codex/config.toml:"
      sed "s/model_auto_compact_token_limit = [0-9]*/model_auto_compact_token_limit = $tok/" "$kit/codex/config.toml" | grep -v '^#' | sed 's/^/      /' ;;
    *) echo "unknown harness: $h" >&2; exit 2 ;;
  esac
done
echo "done. Check: (cd $dest && .relay/bin/relay-rehydrate.sh)"
