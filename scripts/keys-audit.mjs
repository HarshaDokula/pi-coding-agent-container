#!/usr/bin/env node
/**
 * keys-audit.mjs — show (and optionally fix) which credential each pi data dir
 * will actually use.
 *
 * Why this exists: every per-project instance gets its own `.pi-data-<name>`
 * seeded once from `.pi-data`. A rotated/dead provider key therefore keeps
 * living in every existing instance, and `auth.json` takes precedence over the
 * `models.json` secret indirection — so fixing one directory is not enough
 * (SECURITY.md A5/A7).
 *
 * Usage:
 *   node scripts/keys-audit.mjs [--root DIR] [--provider NAME] [--prune] [--apply]
 *
 *   (no flags)                audit every `.pi-data*` dir
 *   --provider P              restrict the audit to one provider
 *   --prune --provider P      show what would be removed from auth.json
 *   --prune --provider P --apply
 *                             actually remove P from every instance's auth.json
 *
 * Key values are never printed, only the last four characters. Exit codes:
 *   0 audit ok, 1 refused/error, 2 usage error.
 */

import fs from "node:fs";
import path from "node:path";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valueOf = (f, fallback = "") => {
  const i = argv.indexOf(f);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

if (has("-h") || has("--help")) {
  console.log(fs.readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 24).join("\n").replace(/^ \* ?/gm, ""));
  process.exit(0);
}

const root = path.resolve(valueOf("--root", process.cwd()));
const providerFilter = valueOf("--provider", "");
// Filename to read instead of auth.json. Only for tests: the hardened container
// denies auth.json to non-pi processes, so a hermetic test needs another name.
const authName = valueOf("--auth-name", "auth.json");
const prune = has("--prune");
const apply = has("--apply");

if (prune && !providerFilter) {
  console.error("keys-audit: --prune requires --provider NAME");
  process.exit(2);
}
if (apply && !prune) {
  console.error("keys-audit: --apply only makes sense with --prune");
  process.exit(2);
}

const INSTANCE_RE = /^\.pi-data(-pi-agent-.*)?$/;

function findInstances(dir) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.isDirectory() && INSTANCE_RE.test(e.name))
    .map((e) => path.join(dir, e.name))
    .filter((p) => fs.existsSync(path.join(p, "agent")))
    .sort();
}

function readJson(file) {
  if (!fs.existsSync(file)) return null;
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    // Never report "no credentials" for a file we simply could not read.
    console.error(`keys-audit: cannot read ${file} (${err.code ?? err.message})`);
    console.error("           if this says EACCES inside the container, run the audit on the host:");
    console.error("           the fs-vault shim denies auth.json to non-pi processes by design.");
    process.exit(1);
  }
}

const tail = (k) => (typeof k === "string" && k.length > 4 ? `****${k.slice(-4)}` : "****");

/** Providers configured through the models.json secret indirection. */
function secretProviders(models) {
  const out = new Map();
  const providers = models?.providers ?? {};
  for (const [name, cfg] of Object.entries(providers)) {
    const key = cfg?.apiKey;
    if (typeof key === "string" && key.startsWith("!")) out.set(name, key);
  }
  return out;
}

const instances = findInstances(root);
if (instances.length === 0) {
  console.error(`keys-audit: no .pi-data* instances under ${root}`);
  process.exit(1);
}

let pruned = 0;
let shadowing = 0;

if (!prune) {
  const rows = [];
  for (const inst of instances) {
    const agent = path.join(inst, "agent");
    const auth = readJson(path.join(agent, authName)) ?? {};
    const models = readJson(path.join(agent, "models.json"));
    const settings = readJson(path.join(agent, "settings.json")) ?? {};
    const secrets = secretProviders(models);

    const names = [...new Set([...Object.keys(auth), ...secrets.keys()])]
      .filter((n) => !providerFilter || n === providerFilter)
      .sort();

    if (names.length === 0) {
      rows.push({ inst, model: "—", source: "none (no credentials)", note: "" });
      continue;
    }

    for (const name of names) {
      const inAuth = Object.prototype.hasOwnProperty.call(auth, name);
      const inSecret = secrets.has(name);
      let source;
      if (inAuth) {
        const k = auth[name]?.key ?? auth[name]?.access ?? "";
        source = `auth.json ${tail(k)}`;
        if (inSecret) {
          source += "  ← shadows models.json secret";
          shadowing++;
        }
      } else {
        source = `models.json ${secrets.get(name)}`;
      }
      const isDefault = settings.defaultProvider === name;
      rows.push({
        inst,
        model: isDefault ? `${name}/${settings.defaultModel ?? "?"} (default)` : name,
        source,
        note: "",
      });
    }
  }

  const w = (s) => String(s).replace(root + path.sep, "");
  const iw = Math.max(9, ...rows.map((r) => w(r.inst).length));
  const mw = Math.max(6, ...rows.map((r) => r.model.length));

  console.log(`${"INSTANCE".padEnd(iw)}  ${"PROVIDER".padEnd(mw)}  SOURCE`);
  for (const r of rows) {
    console.log(`${w(r.inst).padEnd(iw)}  ${r.model.padEnd(mw)}  ${r.source}`);
  }
  console.log();
  console.log(`scanned ${instances.length} instance(s) under ${root}`);
  if (shadowing > 0) {
    console.log(
      `${shadowing} provider entr${shadowing === 1 ? "y" : "ies"} in auth.json shadow the models.json secret — ` +
        `remove with: make keys-prune PROVIDER=<name>`,
    );
  }
  console.log("verify the keys themselves with: make check-keys   (per instance: PI_DATA_DIR=<dir>)");
  process.exit(0);
}

// --- prune ----------------------------------------------------------------
const target = providerFilter;
for (const inst of instances) {
  const authPath = path.join(inst, "agent", authName);
  const auth = readJson(authPath);
  if (!auth || !Object.prototype.hasOwnProperty.call(auth, target)) continue;

  const rel = authPath.replace(root + path.sep, "");
  if (!apply) {
    console.log(`would remove "${target}" from ${rel}`);
    pruned++;
    continue;
  }

  const before = Object.keys(auth);
  delete auth[target];
  const body = `${JSON.stringify(auth, null, 2)}\n`;
  try {
    JSON.parse(body);
  } catch {
    console.error(`keys-audit: refusing to write invalid JSON to ${rel}`);
    process.exit(1);
  }
  const tmp = `${authPath}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, body, { mode: 0o600 });
  fs.chmodSync(tmp, 0o600);
  fs.renameSync(tmp, authPath);
  const after = Object.keys(auth);
  console.log(`removed "${target}" from ${rel} (providers: ${before.join(",")} -> ${after.join(",") || "none"})`);
  pruned++;
}

if (pruned === 0) {
  console.log(`keys-audit: "${target}" is not present in any auth.json under ${root}`);
} else if (!apply) {
  console.log(`\n${pruned} instance(s) would change. Re-run with --apply to write.`);
}
