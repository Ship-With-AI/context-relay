<!-- context-relay:begin -->
## Context relay

Working state lives in `.relay/HANDOFF.md` (format: `.relay/TEMPLATE.md`). The harness injects it at session start and after compaction; nobody pastes it by hand.

- **Update it at every milestone**: task finished, plan changed, dead end found, before a long or risky operation, and when asked to wrap up. Overwrite it; it is a snapshot, not a log.
- Write what a cold reader needs: goal, done (with evidence), in progress, next steps in order, decisions and why, dead ends, open questions, how to verify.
- When it is injected, treat it as a lead: check it against `git log`, `git status` and the tests before acting. If it is stale, fix it first.
- Durable decisions also go to the project's decision log or ADRs; `HANDOFF.md` gets overwritten.
- If a workflow framework owns state here (GSD `.planning/STATE.md`, `.continue-here.md`), keep that state current through the framework; `HANDOFF.md` covers only work outside it.
<!-- context-relay:end -->
