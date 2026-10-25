# Security review & remediation tracker

Review of `main` @ `9ecc124` (2026-10-25). Scope: `Dockerfile`,
`docker-compose*.yml`, `Makefile`, `bin/pictl`, `scripts/*`, `src/*`, and the
resulting on-disk state.

This file is the single source of truth for outstanding security work. Every
item has a stable ID — reference it in commits (`fix(security): A2 …`).
Legend: **DONE** = fixed on this branch · **OPEN** = tracked, not yet done ·
**ACCEPTED** = deliberate residual risk, documented.

---

## P0 — do this now (manual, cannot be automated)

- [ ] **P0.1 Rotate every credential that appears in agent transcripts.**
      Session JSONL files under `.pi-data*/agent/sessions/` contain plaintext
      secrets: a GitHub PAT, an old `DEEPSEEK_API_KEY`, and a complete
      `BEGIN OPENSSH PRIVATE KEY` block (the agent `cat`ed them and pi persisted
      the tool output). Rotate the PAT, the SSH key and both LLM keys, then
      `shred` the affected session files.
- [ ] **P0.2 Assume every credential the agent can read is already public.**
      Until B1/B5/D5 are addressed, the model of trust is "the agent holds the
      secret", so scope and expire keys accordingly (read-only deploy keys,
      spend-limited API keys, per-project keys).

---

## A. Secret storage & at-rest handling

| ID | Sev | Status | Finding | Where | Remediation |
|---|---|---|---|---|---|
| A1 | crit | **DONE** | Agent transcripts persisted every credential the agent reads, verbatim and unencrypted, and replay them into future context. | `.pi-data*/agent/sessions/*.jsonl` | `src/redact-secrets.ts` extension redacts common credential shapes from every `tool_result` (content + structuredContent) before persistence. Seeded into each instance's `agent/extensions/` by `make setup`. Residual: a secret typed inline in a `tool_call` input is still recorded (redacting it there would change the executed command) |
| A2 | high | **DONE** | `.env` was mode `0644` (world-readable) while holding `GITHUB_TOKEN` and `GIT_GPG_KEY`. | `.env`, `Makefile:setup` | `setup` now enforces `chmod 600 .env` and warns when `.env` is group/world-readable |
| A3 | high | OPEN | GitHub token exists twice: `.env` and `.secrets/github_token.txt`. | `Makefile:246-252` | Drop it from `.env`; support `GITHUB_TOKEN_FILE` / keyring lookup |
| A4 | med | OPEN | `sync` writes `<file>.bak` beside credentials, so a superseded key lingers on disk. | `scripts/sync-agent-config.sh:139` | Skip backups for `auth.json`/`models.json`, or `shred -u` the `.bak` |
| A5 | med | OPEN | Keys are replicated into every `.pi-data-pi-agent-*` dir with no revocation path; seeding copies `auth.json` wholesale. | `scripts/seed-agent-config.sh` | Single source of truth (symlink one `auth.json`, or `models.json` `apiKey` indirection) |
| A6 | med | OPEN | "Logged in" is not verification — pi stores API keys without validating them, so a dead key looks healthy (this already caused a real outage). | — | `make check-keys`: curl each configured provider and fail loudly |
| A7 | med | OPEN | Plaintext keys at rest in `auth.json` / `models-store.json`. | `.pi-data/agent/` | pi supports `$ENV` and `!command` in `models.json` `apiKey` — read from the host keyring / a docker secret at request time instead of storing literals |

## B. The "firewalls" (defense-in-depth that does not hold)

| ID | Sev | Status | Finding | Where | Remediation |
|---|---|---|---|---|---|
| B1 | crit | OPEN | `fs-vault` allows **any** process whose cmdline contains `"pi "` to read `auth.json` — including pi's own `read` tool, i.e. the agent's primary tool. Path matching is a substring check. | `src/fs-vault.c:33-42` | Unfixable as designed. Keep it as a speed bump only; move the secret out of the agent's reach (proxy model) |
| B2 | crit | OPEN | `LD_PRELOAD`/`ld.so.preload` is not a boundary: bypassed by static binaries (`build-essential` ships, `/workspace` is `rw,exec`), raw syscalls, and `AT_SECURE` (setuid) executables. | `src/fs-vault.c`, `Dockerfile:74-78` | Landlock/seccomp profile, gVisor (`runtime: runsc`), or an egress proxy. Remove the compiler from the runtime stage |
| B3 | high | OPEN | `NODE_OPTIONS=--require app-firewall.js` is bypassed with `env -u NODE_OPTIONS` / any non-Node tool. It also does not block `auth.json` at all (only `gh_`, `.secrets`, `.env`). | `src/app-firewall.js:9` | Keep as a UX guard; stop treating it as a control (documented under B4) |
| B4 | high | **DONE** | README claimed kernel-level interception, real-time stack analysis, and that `noexec` tmpfs stops static binaries — all false. | `README.md` §1-§6 | Rewritten to describe actual behaviour and residual risk; points here |
| B5 | crit | **DONE (default on)** | Container egress was unrestricted, so any obtained secret left in one HTTPS request. | `docker-compose.egress.yml` | `src/egress-proxy.js` sidecar on an `internal: true` network. Modes: `allowlist` (default), `research` (allowlist + any public host on 80/443, with an SSRF guard for loopback/RFC1918/link-local/metadata/`*.internal`/non-web ports), `false` (off). Denials log `DENY host:port (reason)`. **Residual:** research mode cannot inspect CONNECT tunnels, so a leaked key can reach any public host by design — full fix is credential injection (OpenShell model). Unit + end-to-end verified; live `docker compose` restart to be confirmed |

## C. Container hardening

| ID | Sev | Status | Finding | Where | Remediation |
|---|---|---|---|---|---|
| C1 | crit | **DONE** | A setuid-**root** `gh` binary was installed right after "purging privilege escalation vectors", with no `no-new-privileges` and no `cap_drop`. The secret it read was `0444` and already readable by the container user, so the setuid step bought nothing. | `Dockerfile:57`, `docker-compose.yml` | `gh` is now mode `0755`; `gh-vault` no longer elevates; compose sets `cap_drop: [ALL]` and `no-new-privileges:true` |
| C2 | high | OPEN | Compiler toolchain (`build-essential`, `python3-dev`, npm) in the runtime image — enables B2 and arbitrary native builds. | `Dockerfile:15-22` | Multi-stage: build deps only in a builder stage |
| C3 | med | OPEN | `ssh-keyscan github.com` at build time = unverified TOFU; a MITM at build poisons `known_hosts`. | `Dockerfile:117` | Pin GitHub's published host-key fingerprints |
| C4 | med | OPEN | Floating base tag `node:26-trixie-slim`, unpinned `gh` package, keyring fetched without checksum. | `Dockerfile:3,49` | Pin base image by digest, pin `gh=<version>`, verify keyring fingerprint |
| C5 | high | **DONE** | `HOST_UID=0` was accepted — compose `user: 0:0` silently disables every privilege drop. | `Makefile:27` | Make now refuses to run when `id -u` is 0 |
| C6 | low | OPEN | No `mem_limit`/`cpus`; only `pids_limit`. | `docker-compose.yml` | Add limits |
| C7 | med | **DONE** | `PARANOID_MODE` was inert: exported by the Makefile, never passed to the container, never read by `gh-guard`; docs presented it as a switch. | `Makefile:30`, `.env.example:26`, `README.md` §1 | Knob removed; the guard is documented as always-on |

## D. `gh` vault & guard

| ID | Sev | Status | Finding | Where | Remediation |
|---|---|---|---|---|---|
| D1 | high | **DONE** | `gh-guard` ran `#!/usr/bin/env bash` and called bare `grep`/`git`/`cat`/`tr`/`readlink` **while `GH_TOKEN` was in its environment**; the agent controls `PATH`. | `src/gh-guard.sh:1` | `#!/bin/bash`, fixed `PATH`, absolute binaries |
| D2 | high | **DONE** | `gh api` was unrestricted: it could target alternate hosts (`--hostname`), send the token through custom headers, and write state (`-X POST`, `-f`) that the `gh secret`/`gh repo` blocks would otherwise prevent. Also `alias`/`extension`/`gist`/`copilot`/`codespace` were reachable. | `src/gh-guard.sh` | `gh api` is read-only now (GET only, no sensitive headers, no `--hostname`, no body flags); `alias`/`extension`/`gist`/`copilot`/`codespace` denied. Covered by `tests/test-gh-guard.sh` |
| D3 | med | OPEN | Vault `setenv`s `GH_TOKEN` into the child, so it is readable at `/proc/<pid>/environ` by the same uid. (README claim removed under B4.) | `src/gh-vault.c:35-36` | Feed the token to the credential helper over a pipe instead of the environment |
| D4 | low | OPEN | Vault reads the first `gh_*` entry in `readdir` order instead of the exact configured path. | `src/gh-vault.c:16-19` | Pass the expected path via `SECRET_TARGET_PATH` and require an exact match |
| D5 | high | OPEN | The SSH private key is fully readable by the agent (`0600`, owned by the container user) — a long-lived, push-capable credential one `cat` away. | `docker-compose.yml:37` | Per-repo read-only deploy keys, short TTLs, `Match host` restrictions, or HTTPS + short-lived tokens |

## E. Supply chain & process

| ID | Sev | Status | Finding | Where | Remediation |
|---|---|---|---|---|---|
| E1 | high | OPEN | `MANAGED_REPO_URL/REF` (default `main`) is cloned and its `skills/` + `extensions/` go straight into the agent's auto-load path — arbitrary code execution by whoever controls that repo, unsigned. | `scripts/fetch-managed.sh` | Pin to a commit SHA, verify a signature, or vendor |
| E2 | low | OPEN | `fetch-llm-wiki.sh` pins a version and uses `--ignore-scripts` (good) but has no integrity/lockfile check. | `scripts/fetch-llm-wiki.sh` | `npm pack` + `sha512` pin |
| E3 | med | OPEN | No CI, no secret scanning, no pre-commit hook. `.gitignore` is correct, but one `git add -f` leaks everything. | repo root | `gitleaks` in CI + pre-commit; `make scan-secrets` |

---

## Residual risk statement

Until B5 + D5 are closed, treat this container as **isolation from the host
filesystem and privileges, not from credential exfiltration**. The agent runs
arbitrary code by design; every in-process control here is a speed bump. Real
containment needs one of:

1. an egress allowlist proxy that injects credentials (agent never holds them), or
2. a stronger runtime boundary (`gVisor`/`runsc`, Landlock + seccomp) plus
   scoped, expiring credentials.

NVIDIA OpenShell targets exactly (1) — see the design note in the review.

---

## Work log

### 2026-10-25 — branch `security/priority-hardening` (off `main` @ `9ecc124`)

Closed: **A2, B4, C1, C5, C7, D1**.

| File | Change |
|---|---|
| `Dockerfile` | `gh` built `0755` instead of `4755`; `gh-guard` `0755` — no setuid-root binary in the image |
| `src/gh-vault.c` | Dropped the `setuid(0)` / `setresuid()` dance entirely; reads the 0444 secret as the invoking user |
| `docker-compose.yml` | `cap_drop: [ALL]` + `security_opt: [no-new-privileges:true]` |
| `Makefile` | Refuses `HOST_UID=0`; `setup` tightens `.env` to `0600` (and says so when it was readable); inert `PARANOID_MODE` export removed |
| `.env.example` | `PARANOID_MODE` removed |
| `src/gh-guard.sh` | `#!/bin/bash`, pinned `PATH`, absolute `/usr/bin/git`, `/bin/grep`, `/bin/cat`, `/usr/bin/tr`, `/usr/bin/readlink` |
| `README.md` | Security section rewritten to separate enforced guards from speed bumps; false claims (kernel-level interception, stack-trace analysis, setuid vault, `noexec` preventing static binaries) removed |

Verification: `gcc -O2 -Wall -Wextra src/gh-vault.c` clean; `bash -n src/gh-guard.sh`
clean; `make test` → 90 passed, 0 failed; `make -n setup` and `make -n run
HOST_UID=0` behave as intended. **Not** verified: `docker compose build`/`run`
(no Docker daemon in this environment) — rebuild and confirm `gh --version`
plus one `gh api rate_limit` and one `git push` before merging.

Note observed while working: `app-firewall.js` blocks any path containing
`.env`, including `.env.example`, so pi's edit tools cannot touch template
files (part of B3).

Remaining top 5, in order: **B5** (egress allowlist) → **A1** (transcript
redaction) → **D2** (restrict `gh api`) → **C2** (multi-stage build, drop the
compiler) → **A5/A7** (credential indirection so no plaintext key file exists).

### 2026-10-25 (2) — branches `security/gh-api-restrictions`, `security/redact-secrets`, `security/egress-allowlist`

Closed: **D2, A1, B5 (opt-in)**.

| Branch | Change |
|---|---|
| `security/gh-api-restrictions` | `gh api` is read-only (GET only; blocks non-GET, sensitive headers, `--hostname`, body flags `-f/-F/--field/--input/--raw-field`); `alias`/`extension`/`gist`/`copilot`/`codespace` denied. `tests/test-gh-guard.sh` (23 asserts) |
| `security/redact-secrets` | `src/redact-secrets.ts` extension redacts PEM blocks, GitHub PATs/tokens, AWS key IDs, `sk-*` keys, Bearer/Basic values from every `tool_result` (content + structuredContent) before persistence; installed by `make setup`. `tests/test-redact-secrets.sh` + `.mjs` (21 asserts incl. extension glue) |
| `security/egress-allowlist` | `src/egress-proxy.js` allowlist sidecar; `EGRESS=true` → internal network + proxy env + SSH ProxyCommand via netcat. `tests/test-egress-proxy.sh` + `.mjs` (12 asserts). **Default off; needs live `docker compose` verification** |

Lesson recorded: GitHub **push protection** (secret scanning) rejected a commit
whose test fixtures contained real-format secret strings (and a real leaked
PAT/key copied from a transcript). Test fixtures are now assembled at runtime
from concatenated chunks so no contiguous secret format appears in source.
Never paste a real credential into a fixture.

Remaining top items, in order: **C2** (multi-stage build, drop compiler from
runtime image) → **A5/A7** (credential indirection so no plaintext key file) →
**C3/C4** (pin base image digest, verify gh keyring, pin known_hosts) →
**D3/D4/D5** (token in child env; vault readdir order; readable SSH key).

### 2026-10-25 (3) — branch `security/egress-default-on`

Follow-up after the question "why is egress opt-in? it should be on for LLM
calls and web search". Two real defects fixed and the default flipped:

1. **The sidecar lived in a compose *profile*, and `docker compose run` does not
   start profile services** — so `EGRESS=true` would have had no proxy to talk
   to. Moved to `docker-compose.egress.yml` (overlay, like the wiki one) with an
   explicit `depends_on`, which `docker compose run` does honour.
2. **Default is now ON** (`EGRESS=false` opts out). An egress control that ships
   off is not a control.

Also: verified pi installs an undici `EnvHttpProxyAgent`
(`dist/core/http-dispatcher.js`), so `HTTPS_PROXY` really is honoured for model
calls — confirmed end-to-end with a real `fetch` through the CONNECT proxy to an
allowlisted host (200) and a denied host (refused). Default allowlist now
includes npm/PyPI/crates and common search APIs, and every decision is logged as
`ALLOW`/`DENY host:port` on stderr so a blocked fetch tells you what to add.

### 2026-10-25 (4) — branch `security/egress-research-mode`

Request: "we need arbitrary browsing for research on a large topic or very
recent news." A pure allowlist cannot serve research, and `EGRESS=false` is the
wrong answer (it also exposes the container to the Docker host and to cloud
metadata endpoints). Added a third mode instead:

- `EGRESS=research` → allowlist **plus** any public host on 80/443, guarded by:
  - IP classification: loopback, RFC1918, link-local, CGNAT (100.64/10),
    multicast, reserved, TEST-NET, IPv6 ULA/link-local/multicast, and
    IPv4-mapped equivalents are refused;
  - blocked hostnames: `localhost`, `*.local`, `*.internal`, `host.docker.internal`,
    `metadata.google.internal`, `instance-data`;
  - DNS checked with `{all:true}` and **every** answer must be public, which
    also defeats DNS-rebinding that mixes a public and a private A record;
  - non-web ports refused (22/8080/…); allowlisted entries still bypass this.
- Decisions are logged: `ALLOW host:port (research)` / `DENY host:port (reason)`.

Verified end-to-end through the proxy: `https://news.ycombinator.com/` → 200 in
research mode; `http://169.254.169.254/latest/meta-data/` → 403
(`non-public address`); `http://10.0.0.1/` → refused. 68 proxy assertions and 28
switch assertions, all green.

Residual, deliberately accepted: CONNECT tunnels are opaque, so research mode
cannot restrict methods or payloads — a leaked key can reach any *public* host.
The only design that gives arbitrary browsing **and** secret containment is
credential injection (agent never holds the key), i.e. the OpenShell model.
