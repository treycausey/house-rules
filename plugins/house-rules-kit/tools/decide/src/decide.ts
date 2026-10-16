// Decision queue: append-only JSONL at $DECIDE_HOME/decisions.jsonl (default
// ~/.decide/decisions.jsonl), one queue per machine (do not sync it). Two concurrent writers on the same
// machine never corrupt each other because writes are single `appendFileSync`
// calls guarded by an mkdir lock,
// and reads fold the whole log rather than mutating records in place.

import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";

// Where the queue lives. DECIDE_HOME wins; otherwise ~/.decide.
export function decideHome(): string {
  if (process.env.DECIDE_HOME) return process.env.DECIDE_HOME;
  // No silent fallback: a queue written to /tmp would look filed and then be
  // lost on reboot, and no other process would ever read it.
  if (!process.env.HOME) throw new Error("decide: neither DECIDE_HOME nor HOME is set; set one of them");
  return path.join(process.env.HOME, ".decide");
}

export type DecisionEventType = "add" | "resolve" | "seen";

export interface DecisionAddEvent {
  type: "add";
  id: string;
  project: string;
  agent: string;
  title: string;
  options: string[];
  recommend: string | null;
  context: string;
  // Stable slug naming the underlying problem (e.g. "nightly-backup"), not the
  // time. Optional: old logs and callers that don't pass --key have none.
  key?: string | null;
  at: string;
}

export interface DecisionResolveEvent {
  type: "resolve";
  id: string;
  resolution: string;
  at: string;
}

// Recorded when `decide add --key <k>` finds an already-open decision with
// that key instead of filing a new one -- folds a recurring problem (e.g.
// "nightly backup failed" refiled every 2h while it's still down) into one Decision
// instead of growing the queue forever.
export interface DecisionSeenEvent {
  type: "seen";
  id: string;
  title: string;
  context: string;
  at: string;
}

export type DecisionEvent = DecisionAddEvent | DecisionResolveEvent | DecisionSeenEvent;

export interface Decision {
  id: string;
  project: string;
  agent: string;
  title: string;
  // The title from the original `add` event, kept even after later `seen`
  // events overwrite `title` with the latest one.
  firstTitle: string;
  options: string[];
  recommend: string | null;
  context: string;
  createdAt: string;
  status: "open" | "resolved";
  resolution: string | null;
  resolvedAt: string | null;
  key: string | null;
  // 1 for a decision with no `seen` events; 1 + the number of `seen` events
  // otherwise.
  seenCount: number;
  lastSeenAt: string | null;
}

export function decisionsPath(): string {
  return path.join(decideHome(), "decisions.jsonl");
}

function lockPath(): string {
  return path.join(decideHome(), "decisions.lock");
}

// Blocking sleep for the lock retry loop, so a waiting writer does not spin
// a CPU core at 100% for up to 10 seconds.
function sleepMs(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function withLock<T>(fn: () => T): T {
  const dir = lockPath();
  fs.mkdirSync(path.dirname(dir), { recursive: true });
  const deadline = Date.now() + 10_000;
  for (;;) {
    try {
      fs.mkdirSync(dir);
      break;
    } catch (err: any) {
      if (err?.code !== "EEXIST") throw err;
      if (Date.now() > deadline) {
        // stale lock older than 30s: reclaim it
        try {
          const st = fs.statSync(dir);
          if (Date.now() - st.mtimeMs > 30_000) {
            fs.rmSync(dir, { recursive: true, force: true });
            continue;
          }
        } catch {
          continue;
        }
        throw new Error("decisions.jsonl is locked by another writer; timed out waiting");
      }
      sleepMs(25);
    }
  }
  try {
    return fn();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

export function readEvents(): DecisionEvent[] {
  const file = decisionsPath();
  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (err: any) {
    // No queue yet is normal. Any other read failure (permissions, a
    // directory in the way) must not look like an empty queue.
    if (err?.code === "ENOENT") return [];
    throw err;
  }
  const out: DecisionEvent[] = [];
  for (const line of raw.split("\n")) {
    if (line.trim() === "") continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      // A malformed line must not silently vanish: warn loudly, but don't
      // fail the whole read over one bad line (the rest of the log is still
      // good evidence).
      console.error(`decide: skipping malformed line in ${decisionsPath()}: ${line.slice(0, 200)}`);
    }
  }
  return out;
}

export function fold(events: DecisionEvent[]): Decision[] {
  const byId = new Map<string, Decision>();
  const order: string[] = [];
  for (const ev of events) {
    if (ev.type === "add") {
      if (!byId.has(ev.id)) order.push(ev.id);
      byId.set(ev.id, {
        id: ev.id,
        project: ev.project,
        agent: ev.agent,
        title: ev.title,
        firstTitle: ev.title,
        options: ev.options,
        recommend: ev.recommend,
        context: ev.context,
        createdAt: ev.at,
        status: "open",
        resolution: null,
        resolvedAt: null,
        key: ev.key ?? null,
        seenCount: 1,
        lastSeenAt: null,
      });
    } else if (ev.type === "resolve") {
      const d = byId.get(ev.id);
      if (d) {
        d.status = "resolved";
        d.resolution = ev.resolution;
        d.resolvedAt = ev.at;
      }
    } else if (ev.type === "seen") {
      // Old logs predate this event type and simply never produce one, so
      // seenCount/lastSeenAt stay at their "never seen again" defaults.
      const d = byId.get(ev.id);
      if (d) {
        d.seenCount += 1;
        d.lastSeenAt = ev.at;
        d.title = ev.title;
        // A recurrence that brings no new evidence keeps the last evidence.
        if (ev.context) d.context = ev.context;
      }
    }
  }
  return order.map((id) => byId.get(id)!);
}

export function listDecisions(): Decision[] {
  return fold(readEvents());
}

function writeEventRaw(ev: DecisionEvent): void {
  fs.mkdirSync(path.dirname(decisionsPath()), { recursive: true });
  fs.appendFileSync(decisionsPath(), JSON.stringify(ev) + "\n");
}

function appendEvent(ev: DecisionEvent): void {
  withLock(() => writeEventRaw(ev));
}

export function addDecision(input: {
  project: string;
  agent: string;
  title: string;
  options?: string[];
  recommend?: string;
  context?: string;
  // A stable slug naming the underlying problem (not the time). When an OPEN
  // decision from the same project and agent already has this key, no new
  // decision is created -- a `seen`
  // event is appended to the existing one instead, and its id is returned.
  // A resolved decision with this key does not match: a recurrence after
  // resolution is a new decision. Omitting --key keeps the old behavior.
  key?: string;
}): string {
  // The dedupe check and the write must happen under the same lock: two
  // concurrent `decide add --key` calls for the same new problem must not
  // both see "no open decision yet" and both create one.
  return withLock(() => {
    if (input.key) {
      const existing = fold(readEvents()).find(
        (d) =>
          d.key === input.key &&
          d.project === input.project &&
          d.agent === input.agent &&
          d.status === "open",
      );
      if (existing) {
        const ev: DecisionSeenEvent = {
          type: "seen",
          id: existing.id,
          title: input.title,
          context: input.context ?? "",
          at: new Date().toISOString(),
        };
        writeEventRaw(ev);
        return existing.id;
      }
    }
    const id = crypto.randomBytes(4).toString("hex");
    const ev: DecisionAddEvent = {
      type: "add",
      id,
      project: input.project,
      agent: input.agent,
      title: input.title,
      options: input.options ?? [],
      recommend: input.recommend ?? null,
      context: input.context ?? "",
      key: input.key ?? null,
      at: new Date().toISOString(),
    };
    writeEventRaw(ev);
    return id;
  });
}

export function resolveDecision(id: string, resolution: string): void {
  const existing = listDecisions().find((d) => d.id === id);
  if (!existing) throw new Error(`no decision with id "${id}"`);
  if (existing.status === "resolved") {
    throw new Error(`decision "${id}" is already resolved: ${existing.resolution}`);
  }
  appendEvent({ type: "resolve", id, resolution, at: new Date().toISOString() });
}

export function digestMarkdown(): string {
  const open = listDecisions().filter((d) => d.status === "open");
  if (open.length === 0) return "# Open decisions\n\nNone.\n";
  const byProject = new Map<string, Decision[]>();
  for (const d of open) {
    if (!byProject.has(d.project)) byProject.set(d.project, []);
    byProject.get(d.project)!.push(d);
  }
  const lines: string[] = ["# Open decisions", ""];
  for (const [project, decisions] of Array.from(byProject.entries()).sort()) {
    lines.push(`## ${project}`, "");
    for (const d of decisions) {
      const seenSuffix = d.seenCount > 1 ? ` ×${d.seenCount}` : "";
      lines.push(`- **${d.id}** (${d.agent}): ${d.title}${seenSuffix}`);
      if (d.seenCount > 1 && d.lastSeenAt) lines.push(`  - last seen: ${d.lastSeenAt}`);
      if (d.options.length > 0) lines.push(`  - options: ${d.options.join(" | ")}`);
      if (d.recommend) lines.push(`  - recommend: ${d.recommend}`);
      if (d.context) lines.push(`  - context: ${d.context}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}
