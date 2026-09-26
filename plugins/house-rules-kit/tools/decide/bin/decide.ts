#!/usr/bin/env bun
import { addDecision, resolveDecision, listDecisions, digestMarkdown } from "../src/decide.ts";

const BOOLEAN_FLAGS = new Set(["open", "all", "json"]);

function parseFlags(args: string[]): { positional: string[]; flags: Record<string, string[]> } {
  const positional: string[] = [];
  const flags: Record<string, string[]> = {};
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a.startsWith("--")) {
      const key = a.slice(2);
      if (BOOLEAN_FLAGS.has(key)) {
        (flags[key] ??= []).push("true");
      } else {
        const value = args[++i] ?? "";
        (flags[key] ??= []).push(value);
      }
    } else {
      positional.push(a);
    }
  }
  return { positional, flags };
}

function usage(exitCode = 2): never {
  (exitCode === 0 ? console.log : console.error)(`usage:
  decide add --project <p> --agent <id> --title "<question>" [--option "<a>" ...] [--recommend "<a>"] [--context "<why>"] [--key "<stable-slug>"]
  decide list [--open|--all] [--json]
  decide resolve <id> "<choice or note>"   (or: decide resolve <id> --resolution "<choice or note>")
  decide digest`);
  process.exit(exitCode);
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!cmd) usage();
  if (cmd === "--help" || cmd === "-h" || cmd === "help") usage(0);

  if (cmd === "add") {
    const { flags } = parseFlags(rest);
    const project = flags.project?.[0];
    const agent = flags.agent?.[0];
    const title = flags.title?.[0];
    if (!project || !agent || !title) {
      console.error("decide add requires --project, --agent, and --title");
      process.exit(2);
    }
    const id = addDecision({
      project,
      agent,
      title,
      options: flags.option ?? [],
      recommend: flags.recommend?.[0],
      context: flags.context?.[0],
      key: flags.key?.[0],
    });
    console.log(id);
    return;
  }

  if (cmd === "list") {
    const { flags } = parseFlags(rest);
    let decisions = listDecisions();
    if (flags.open) decisions = decisions.filter((d) => d.status === "open");
    if (flags.json) {
      console.log(JSON.stringify(decisions, null, 2));
      return;
    }
    if (decisions.length === 0) {
      console.log("no decisions");
      return;
    }
    for (const d of decisions) {
      const mark = d.status === "open" ? "OPEN" : "RESOLVED";
      const seenSuffix = d.seenCount > 1 ? `  ×${d.seenCount}` : "";
      console.log(`${d.id}  [${mark}]  ${d.project}/${d.agent}  ${d.title}${seenSuffix}`);
      if (d.seenCount > 1 && d.lastSeenAt) console.log(`         last seen: ${d.lastSeenAt}`);
      if (d.status === "resolved") console.log(`         -> ${d.resolution}`);
    }
    return;
  }

  if (cmd === "resolve") {
    // Accept `--resolution "<text>"` as well as the positional form, and never
    // store a flag as the resolution: `resolve <id> --resolution "..."` once
    // recorded the literal text "--resolution" (2026-09-25).
    const flagAt = rest.indexOf("--resolution");
    const id = rest[0];
    const resolution = flagAt >= 0 ? rest[flagAt + 1] : rest[1];
    if (!id || !resolution || id.startsWith("--") || resolution.startsWith("--")) {
      console.error('decide resolve <id> "<choice or note>"  (or --resolution "<text>"; the text may not start with --)');
      process.exit(2);
    }
    resolveDecision(id, resolution);
    console.log(`resolved ${id}`);
    return;
  }

  if (cmd === "digest") {
    process.stdout.write(digestMarkdown());
    return;
  }

  usage();
}

main().catch((err) => {
  console.error(String(err?.message ?? err));
  process.exit(1);
});
