import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { addDecision, resolveDecision, listDecisions, digestMarkdown, fold } from "../src/decide.ts";
import type { DecisionEvent } from "../src/decide.ts";

let tmpHome: string;
let originalHome: string | undefined;

beforeEach(() => {
  originalHome = process.env.HOME;
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "decide-test-"));
  process.env.HOME = tmpHome;
  delete process.env.DECIDE_HOME;
});

afterEach(() => {
  process.env.HOME = originalHome;
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

describe("standing is retired", () => {
  it("defaults the queue to ~/.decide, not ~/.standing", () => {
    addDecision({ project: "p", agent: "a", title: "t", recommend: "r" });
    expect(fs.existsSync(path.join(tmpHome, ".decide", "decisions.jsonl"))).toBe(true);
    expect(fs.existsSync(path.join(tmpHome, ".standing"))).toBe(false);
  });

  it("the decide skill does not point at ~/.standing", () => {
    const skill = path.join(import.meta.dirname, "../../../plugins/house-rules-kit/skills/decide/SKILL.md");
    const text = fs.readFileSync(skill, "utf8");
    expect(text).not.toContain(".standing");
    expect(text).toContain("~/.decide/decisions.jsonl");
  });
});

describe("decision queue fold", () => {
  it("add then list shows an open decision", () => {
    const id = addDecision({ project: "shots", agent: "shots.inbox", title: "ship it?", recommend: "yes" });
    const decisions = listDecisions();
    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({ id, status: "open", title: "ship it?", recommend: "yes" });
  });

  it("resolve then list shows resolved with the resolution text", () => {
    const id = addDecision({ project: "shots", agent: "shots.inbox", title: "ship it?" });
    resolveDecision(id, "yes, go ahead");
    const decisions = listDecisions();
    expect(decisions[0]).toMatchObject({ status: "resolved", resolution: "yes, go ahead" });
  });

  it("resolving twice fails loud instead of silently overwriting", () => {
    const id = addDecision({ project: "shots", agent: "shots.inbox", title: "ship it?" });
    resolveDecision(id, "yes");
    expect(() => resolveDecision(id, "no wait")).toThrow(/already resolved/);
  });

  it("resolving an unknown id fails loud", () => {
    expect(() => resolveDecision("nope", "x")).toThrow(/no decision/);
  });

  it("digest groups open decisions by project and omits resolved ones", () => {
    addDecision({ project: "shots", agent: "shots.inbox", title: "A" });
    const idB = addDecision({ project: "sette", agent: "sette.jobs", title: "B" });
    resolveDecision(idB, "done");
    const md = digestMarkdown();
    expect(md).toContain("## shots");
    expect(md).toContain("A");
    expect(md).not.toContain("## sette");
    expect(md).not.toContain("B");
  });

  it("two concurrent appends both survive (lock prevents corruption)", async () => {
    await Promise.all([
      Promise.resolve().then(() => addDecision({ project: "p", agent: "a", title: "first" })),
      Promise.resolve().then(() => addDecision({ project: "p", agent: "a", title: "second" })),
    ]);
    const decisions = listDecisions();
    expect(decisions.map((d) => d.title).sort()).toEqual(["first", "second"]);
  });
});

// Regression: a watcher agent filed a new "nightly backup failed"
// decision every 2h while the backup stayed broken -- three open
// decisions for one outage after two runs, growing forever without a fold.
describe("decision queue: --key dedupe", () => {
  it("a second add with the same open key folds into the existing decision instead of creating one", () => {
    const id1 = addDecision({
      project: "homelab",
      agent: "homelab.log-watch",
      title: "Nightly backup failed since 11:20",
      key: "nightly-backup",
    });
    const id2 = addDecision({
      project: "homelab",
      agent: "homelab.log-watch",
      title: "Nightly backup failed since ~11:37",
      key: "nightly-backup",
    });
    expect(id2).toBe(id1);

    const decisions = listDecisions();
    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({
      id: id1,
      status: "open",
      firstTitle: "Nightly backup failed since 11:20",
      title: "Nightly backup failed since ~11:37",
      key: "nightly-backup",
      seenCount: 2,
    });
    expect(decisions[0]!.lastSeenAt).not.toBeNull();
  });

  // Review of 1247452: the key alone matched, so another agent's "tests-failing"
  // folded into this one's decision and vanished from the digest.
  it("the same key from a different project or agent is a separate decision", () => {
    addDecision({ project: "shots", agent: "shots.nightly", title: "shots tests fail", key: "tests-failing" });
    addDecision({ project: "guide", agent: "guide.nightly", title: "guide tests fail", key: "tests-failing" });
    addDecision({ project: "shots", agent: "shots.inbox", title: "inbox tests fail", key: "tests-failing" });
    const decisions = listDecisions();
    expect(decisions).toHaveLength(3);
    expect(decisions.every((d) => d.seenCount === 1)).toBe(true);
  });

  // Review of 1247452: a recurrence without --context erased the evidence.
  it("a recurrence with no context keeps the previous context", () => {
    addDecision({ project: "p", agent: "a", title: "one", context: "ping 100% loss", key: "k" });
    addDecision({ project: "p", agent: "a", title: "two", key: "k" });
    expect(listDecisions()[0]).toMatchObject({ seenCount: 2, title: "two", context: "ping 100% loss" });
  });

  it("a third add with the same key keeps folding (seenCount keeps growing)", () => {
    addDecision({ project: "p", agent: "a", title: "one", key: "k" });
    addDecision({ project: "p", agent: "a", title: "two", key: "k" });
    addDecision({ project: "p", agent: "a", title: "three", key: "k" });
    const decisions = listDecisions();
    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({ seenCount: 3, title: "three" });
  });

  it("without --key, behavior is unchanged: every add is a separate decision", () => {
    addDecision({ project: "p", agent: "a", title: "first, no key" });
    addDecision({ project: "p", agent: "a", title: "second, no key" });
    const decisions = listDecisions();
    expect(decisions).toHaveLength(2);
    expect(decisions.every((d) => d.key === null && d.seenCount === 1)).toBe(true);
  });

  it("a resolved decision with a key does not block a new decision with the same key", () => {
    const id1 = addDecision({ project: "p", agent: "a", title: "first outage", key: "nightly-backup" });
    resolveDecision(id1, "came back on its own");
    const id2 = addDecision({ project: "p", agent: "a", title: "second outage", key: "nightly-backup" });
    expect(id2).not.toBe(id1);

    const decisions = listDecisions();
    expect(decisions).toHaveLength(2);
    const resolved = decisions.find((d) => d.id === id1)!;
    const open = decisions.find((d) => d.id === id2)!;
    expect(resolved.status).toBe("resolved");
    expect(open.status).toBe("open");
    expect(open.seenCount).toBe(1);
  });

  it("folds old logs that predate the seen event type (no key, no seen events)", () => {
    const events: DecisionEvent[] = [
      {
        type: "add",
        id: "abcd1234",
        project: "shots",
        agent: "shots.inbox",
        title: "old-format decision",
        options: [],
        recommend: null,
        context: "",
        at: "2026-08-01T00:00:00.000Z",
        // note: no `key` field at all, as old logs never wrote one
      } as DecisionEvent,
    ];
    const decisions = fold(events);
    expect(decisions).toHaveLength(1);
    expect(decisions[0]).toMatchObject({
      id: "abcd1234",
      key: null,
      seenCount: 1,
      lastSeenAt: null,
      firstTitle: "old-format decision",
    });
  });
});

describe("decision queue: list/digest show the fold count", () => {
  it("digest shows ×N and the last-seen time for a folded decision, and omits both otherwise", () => {
    addDecision({ project: "homelab", agent: "a", title: "Nightly backup failed", key: "nightly-backup" });
    addDecision({ project: "homelab", agent: "a", title: "Nightly backup still failing", key: "nightly-backup" });
    addDecision({ project: "homelab", agent: "a", title: "unrelated, unfolded decision" });

    const md = digestMarkdown();
    expect(md).toContain("Nightly backup still failing ×2");
    expect(md).toMatch(/last seen: \S+/);
    expect(md).toContain("unrelated, unfolded decision");
    expect(md).not.toMatch(/unrelated, unfolded decision ×/);
  });

  it("--json (listDecisions) includes key, seenCount, lastSeenAt, firstTitle", () => {
    const id = addDecision({ project: "p", agent: "a", title: "first", key: "k" });
    addDecision({ project: "p", agent: "a", title: "second", key: "k" });
    const [d] = listDecisions();
    expect(d).toMatchObject({ id, key: "k", firstTitle: "first", title: "second", seenCount: 2 });
    expect(typeof d!.lastSeenAt).toBe("string");
  });
});
