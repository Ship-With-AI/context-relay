# Context Relay

Long coding-agent sessions that hand themselves off. The working state lives in one file in the repo (`.relay/HANDOFF.md`), the harness rolls the context over early, a session-start hook reads the file back, and a session that has compacted too often or lived too long ends and restarts clean. Works with omp, Pi, Claude Code and Codex. Needs bash and git.

## Install

```bash
git clone https://github.com/Ship-With-AI/context-relay
context-relay/install.sh --harness omp /path/to/project            # omp, pi, claude, codex; comma-separated
context-relay/install.sh --flavor gsd --harness claude /path/to/project
cd /path/to/project && .relay/bin/relay-rehydrate.sh                # prints nothing until a handoff exists
```

The installer copies `.relay/` (scripts, template, config, sources), wires the chosen harnesses, appends the rule to `AGENTS.md`/`CLAUDE.md` when present, and never overwrites existing harness settings: it prints what to merge instead.

## How it works

| Verb | What | Who |
|---|---|---|
| Checkpoint | rewrite `.relay/HANDOFF.md` | the agent at milestones (rule in `AGENTS.relay.md`); omp/Pi also at compaction |
| Rollover | reset the context window | the harness, at ~60% |
| Rehydrate | inject the state at session start and after compaction | `relay-rehydrate.sh` via omp/Pi extension or `SessionStart` hook |
| End of life | stop a session after N compactions or N hours | omp extension, `relay-hook.sh` |
| Restart | continue in a fresh session from the file | `/relay restart` (omp, Pi), `/clear` (Claude Code), `/new` (Codex), `relay-loop.sh` |

## Configure (`.relay/config`)

| Key | Default | Effect |
|---|---|---|
| `RELAY_COMPACT_AT_PERCENT` | 60 | omp `compaction.thresholdPercent` (written at install) |
| `RELAY_COMPACT_AT_TOKENS` | 120000 | Claude Code `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, Codex `model_auto_compact_token_limit` (written at install) |
| `RELAY_EOL_COMPACTIONS` | 3 | end of life after N compactions (0 = never) |
| `RELAY_EOL_HOURS` | 8 | end of life after N hours (0 = never) |
| `RELAY_EOL_ACTION` | restart | `restart` · `notify` · `exit` · `off` |
| `RELAY_MAX_BYTES` | 16000 | cap on injected state |
| `RELAY_ARCHIVE_KEEP` | 10 | previous handoffs kept in `.relay/archive/` |

Environment variables of the same name override the file.

## Daily use

| You want to | omp, Pi | Claude Code | Codex |
|---|---|---|---|
| Start or resume | open the harness, type the task or "continue" | same | same |
| See status | `/relay` | `cat .relay/HANDOFF.md` | same |
| Checkpoint now | `/handoff` | "update the handoff" | same |
| Fresh session | `/relay restart` | `/clear` | `/new` |
| Run unattended | `.relay/bin/relay-loop.sh -- <harness command>` | same | same |

`relay-loop.sh` stops on `Status: done` in the handoff (exit 0), after two runs that left it unchanged (exit 3), or at `--max` (exit 4).

## Compose with frameworks

`.relay/sources` lists files to inject, newest match per pattern. `--flavor gsd` injects GSD's `.continue-here.md` and `STATE.md` before `HANDOFF.md`. The relay never writes a framework's files.

## Limits

- Claude Code and Codex cannot write the handoff at the moment of compaction (`PreCompact` cannot reach the model); the milestone rule carries that.
- Codex delivers `SessionStart(compact)` one turn late (openai/codex#28736).
- Running subagents are not carried across a restart.
- Tested end to end on omp 18.12.4. Claude Code/Codex hook tested with simulated input; Pi untested.

MIT. By [ShipWithAI](https://shipwithai.substack.com).
