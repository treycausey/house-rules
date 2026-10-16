import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";

// `decide resolve <id> --resolution "..."` once stored the literal text
// "--resolution" as the answer (2026-09-25).
const BIN = path.join(__dirname, "../bin/decide.ts");
let home: string;

function decide(...args: string[]) {
  return spawnSync("bun", [BIN, ...args], {
    env: { ...process.env, HOME: home, DECIDE_HOME: path.join(home, ".decide") },
    encoding: "utf8",
  });
}

function lastResolution(): string | undefined {
  const lines = fs.readFileSync(path.join(home, ".decide", "decisions.jsonl"), "utf8").trim().split("\n");
  const ev = lines.map((l) => JSON.parse(l)).filter((e) => e.type === "resolve").at(-1);
  return ev?.resolution;
}

function addOne(): string {
  const out = decide("add", "--project", "p", "--agent", "a", "--title", "t");
  expect(out.status).toBe(0);
  const id = out.stdout.trim().split(/\s+/).at(-1)!;
  return id;
}

describe("decide resolve", () => {
  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), "decide-cli-"));
  });
  afterEach(() => fs.rmSync(home, { recursive: true, force: true }));

  it("stores the text after --resolution, not the flag", () => {
    const id = addOne();
    const out = decide("resolve", id, "--resolution", "the cleaner unplugged it");
    expect(out.status).toBe(0);
    expect(lastResolution()).toBe("the cleaner unplugged it");
  });

  it("still accepts the positional form", () => {
    const id = addOne();
    expect(decide("resolve", id, "done").status).toBe(0);
    expect(lastResolution()).toBe("done");
  });

  it("refuses a flag as the resolution text", () => {
    const id = addOne();
    const out = decide("resolve", id, "--note");
    expect(out.status).toBe(2);
    expect(fs.readFileSync(path.join(home, ".decide", "decisions.jsonl"), "utf8")).not.toContain('"resolve"');
  });
});

describe("decide cli basics", () => {
  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), "decide-cli-"));
  });
  afterEach(() => fs.rmSync(home, { recursive: true, force: true }));

  it("--help prints usage and exits 0", () => {
    const out = decide("--help");
    expect(out.status).toBe(0);
    expect(out.stdout).toContain("decide add");
  });

  it("fails loud when neither HOME nor DECIDE_HOME is set", () => {
    const env: Record<string, string> = { PATH: process.env.PATH ?? "" };
    const out = spawnSync("bun", [BIN, "list"], { env, encoding: "utf8" });
    expect(out.status).toBe(1);
    expect(out.stderr).toContain("neither DECIDE_HOME nor HOME is set");
  });
});
