/**
 * context-relay for omp (and pi): checkpoint, rehydrate, end of life, restart.
 *
 * - Checkpoint: when compaction runs with the `handoff` method (manual /handoff or automatic
 *   at the threshold), mirror the document to .relay/HANDOFF.md and archive the previous one.
 *   Opaque summaries (remote, snapcompact) are not mirrored; pi compactions carry no method
 *   and are mirrored as-is.
 * - Rehydrate: on the first prompt of a fresh session, inject .relay/bin/relay-rehydrate.sh output.
 * - End of life: after RELAY_EOL_COMPACTIONS compactions or RELAY_EOL_HOURS of session age,
 *   run RELAY_EOL_ACTION (restart | notify | exit | off), see .relay/config.
 * - `/relay` shows status; `/relay restart` opens a fresh session that continues from the handoff.
 *
 * Install: copy to <project>/.omp/extensions/ (or ~/.omp/agent/extensions/).
 */
import * as fs from "node:fs/promises";
import * as path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const HANDOFF = ".relay/HANDOFF.md";
const ARCHIVE_DIR = ".relay/archive";
const REHYDRATE = ".relay/bin/relay-rehydrate.sh";
const CONTINUE_PROMPT =
	"Continue the task from the context-relay working state. Verify it against the repository first.";

type EolAction = "restart" | "notify" | "exit" | "off";
interface RelayConfig {
	eolCompactions: number;
	eolHours: number;
	eolAction: EolAction;
	archiveKeep: number;
}

export default function contextRelay(pi: ExtensionAPI) {
	pi.setLabel?.("Context relay");
	let eolFired = false;
	let eolPending: string | undefined;

	const reset = async () => {
		eolFired = false;
		eolPending = undefined;
	};
	pi.on("session_start", reset);
	pi.on("session_switch", reset);

	pi.on("before_agent_start", async (_event, ctx) => {
		if (ctx.agent?.kind === "sub" || !stats(ctx).fresh) return;
		const text = await rehydrate(pi, ctx);
		if (!text) return;
		ctx.ui.notify(`Context relay: restored ${text.length} chars of working state`, "info");
		return { message: { customType: "context-relay", content: text, display: false, attribution: "agent" } };
	});

	pi.on("session_compact", async (event, ctx) => {
		if (event.fromExtension || ctx.agent?.kind === "sub") return;
		const cfg = await loadConfig(ctx.cwd);
		const entry = event.compactionEntry;
		if (entry.method === undefined || entry.method === "handoff") await saveHandoff(ctx, entry, cfg);
		const s = stats(ctx);
		const reason =
			eolPending ??
			(cfg.eolCompactions > 0 && s.compactions >= cfg.eolCompactions
				? `${s.compactions} compactions (limit ${cfg.eolCompactions})`
				: undefined);
		if (reason) endOfLife(pi, ctx, cfg, reason);
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (eolFired || eolPending || ctx.agent?.kind === "sub") return;
		const cfg = await loadConfig(ctx.cwd);
		if (cfg.eolAction === "off" || cfg.eolHours <= 0) return;
		const s = stats(ctx);
		if (s.ageHours < cfg.eolHours) return;
		// Checkpoint through a regular compaction (handoff first in methodOrder); the
		// session_compact handler then runs the end-of-life action.
		eolPending = `${s.ageHours.toFixed(1)}h old (limit ${cfg.eolHours}h)`;
		ctx.compact({ suppressContinuation: true, onError: () => endOfLife(pi, ctx, cfg, eolPending!) } as never);
	});

	function endOfLife(api: ExtensionAPI, ctx: ExtensionContext, cfg: RelayConfig, reason: string) {
		if (eolFired || cfg.eolAction === "off") return;
		eolFired = true;
		eolPending = undefined;
		if (cfg.eolAction === "exit") {
			ctx.ui.notify(`Context relay: end of life (${reason}); handoff saved, exiting`, "warning");
			ctx.shutdown();
			return;
		}
		const next =
			cfg.eolAction === "restart"
				? "then stop and tell the user to press Enter on `/relay restart`, which opens a fresh session that continues from the handoff."
				: "then stop and tell the user the session reached end of life.";
		api.sendMessage(
			{
				customType: "context-relay-eol",
				content: `Context relay: this session reached end of life (${reason}). Do not start new work in it. Finish the current step, make sure ${HANDOFF} is current, ${next}`,
				display: true,
				attribution: "agent",
			},
			{ deliverAs: ctx.isIdle() ? "nextTurn" : "steer" },
		);
		if (cfg.eolAction === "restart" && ctx.ui.supportsEditor !== false) ctx.ui.setEditorText?.("/relay restart");
		ctx.ui.notify(`Context relay: end of life (${reason})`, "warning");
	}

	pi.registerCommand("relay", {
		description: "Context relay: `/relay` status, `/relay restart` fresh session from the handoff",
		handler: async (args, ctx) => {
			if (args.trim() === "restart") {
				await ctx.waitForIdle();
				const { cancelled } = await ctx.newSession();
				if (cancelled) return;
				pi.sendUserMessage(CONTINUE_PROMPT);
				return;
			}
			const cfg = await loadConfig(ctx.cwd);
			const s = stats(ctx);
			const handoff = await fs.stat(path.join(ctx.cwd, HANDOFF)).catch(() => undefined);
			ctx.ui.notify(
				[
					`Context relay`,
					`  handoff:     ${handoff ? `${HANDOFF} (${handoff.mtime.toISOString()})` : "none yet"}`,
					`  compactions: ${s.compactions} / end of life at ${cfg.eolCompactions > 0 ? cfg.eolCompactions : "never"}`,
					`  age:         ${s.ageHours.toFixed(1)}h / end of life at ${cfg.eolHours > 0 ? `${cfg.eolHours}h` : "never"}`,
					`  on end:      ${cfg.eolAction}`,
				].join("\n"),
				"info",
			);
		},
	});
}

function stats(ctx: ExtensionContext) {
	const branch = ctx.sessionManager.getBranch();
	let compactions = 0;
	let fresh = true;
	for (const e of branch) {
		if (e.type === "compaction") compactions++;
		if (
			e.type === "compaction" ||
			(e.type === "message" && e.message.role === "assistant") ||
			(e.type === "custom_message" && e.customType === "context-relay")
		)
			fresh = false;
	}
	const first = branch.find(e => typeof e.timestamp === "string");
	const startedMs = first ? Date.parse(first.timestamp) : Date.now();
	return { compactions, fresh, ageHours: (Date.now() - startedMs) / 3_600_000 };
}

async function rehydrate(pi: ExtensionAPI, ctx: ExtensionContext): Promise<string | undefined> {
	const script = path.join(ctx.cwd, REHYDRATE);
	if (!(await exists(script))) return;
	const result = await pi.exec("bash", [script], { cwd: ctx.cwd, timeout: 10_000 });
	const text = result.stdout.trim();
	return result.code === 0 && text ? text : undefined;
}

async function saveHandoff(ctx: ExtensionContext, entry: { summary?: string; method?: string }, cfg: RelayConfig) {
	const summary = entry.summary?.trim();
	if (!summary) return;
	const target = path.join(ctx.cwd, HANDOFF);
	await fs.mkdir(path.dirname(target), { recursive: true });
	if (await exists(target)) {
		const archiveDir = path.join(ctx.cwd, ARCHIVE_DIR);
		await fs.mkdir(archiveDir, { recursive: true });
		const stamp = new Date().toISOString().replace(/[:.]/g, "-");
		await fs.rename(target, path.join(archiveDir, `HANDOFF-${stamp}.md`));
		const old = (await fs.readdir(archiveDir)).filter(n => n.startsWith("HANDOFF-")).sort();
		for (const name of old.slice(0, Math.max(0, old.length - cfg.archiveKeep))) {
			await fs.rm(path.join(archiveDir, name));
		}
	}
	const header = `<!-- context-relay: written by ${entry.method ?? "compaction"} at ${new Date().toISOString()} -->\nStatus: active\n\n`;
	await fs.writeFile(target, `${header}${summary}\n`);
	ctx.ui.notify(`Context relay: handoff saved to ${HANDOFF}`, "info");
}

async function loadConfig(cwd: string): Promise<RelayConfig> {
	const file: Record<string, string> = {};
	const text = await fs.readFile(path.join(cwd, ".relay/config"), "utf8").catch(() => "");
	for (const line of text.split("\n")) {
		const m = /^(RELAY_[A-Z_]+)=([^#\s]*)/.exec(line);
		if (m) file[m[1]] = m[2];
	}
	const get = (key: string, fallback: string) => process.env[key] || file[key] || fallback;
	const num = (key: string, fallback: string) => {
		const n = Number(get(key, fallback));
		return Number.isFinite(n) && n > 0 ? n : 0;
	};
	const action = get("RELAY_EOL_ACTION", "restart") as EolAction;
	return {
		eolCompactions: num("RELAY_EOL_COMPACTIONS", "3"),
		eolHours: num("RELAY_EOL_HOURS", "8"),
		eolAction: (["restart", "notify", "exit", "off"] as const).includes(action) ? action : "restart",
		archiveKeep: num("RELAY_ARCHIVE_KEEP", "10") || 10,
	};
}

async function exists(p: string): Promise<boolean> {
	try {
		await fs.access(p);
		return true;
	} catch {
		return false;
	}
}
