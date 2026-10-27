# Security review & remediation tracker

Review of `main` @ `9ecc124` (2026-10-25). Scope: `Dockerfile`,
`docker-compose*.yml`, `Makefile`, `bin/pictl`, `scripts/*`, `src/*`, and the
resulting on-disk state.

This file is the single source of truth for outstanding security work. Every
item has a stable ID — reference it in commits (`fix(security): A2 …`).
Legend: **DONE** = fixed and merged to `main` · **OPEN** = tracked, not yet done
· **ACCEPTED** = deliberate residual risk, documented.

---

## Status snapshot (2026-10-25)

**16 of 27 items closed.** Suite: 290+ assertions across 15 test files
(5 of them drive `make` and SKIP cleanly where make is not installed).

| Area | Closed | Open |
|---|---|---|
| A. Secret storage | A1, A2, A4, A5\*, A6, A7 | A3 |
| B. Firewalls / egress | B4, B5 | B1, B2, B3 (accepted residuals) |
| C. Container hardening | C1, C2, C3, C4, C5, C7 | C6 |
| D. gh vault & guard | D1, D2 | D3, D4, D5 |
| E. Supply chain & process | — | E1, E2, E3 |

\* A5 closed for the secret route: nothing secret is written into the data dirs,
so seeding/sync no longer replicate a key. Instances still on a plaintext
`auth.json` keep the old behaviour until it is pruned (see below).

### Credential model (tracked under A5 + A7)

A bearer token has to exist as bytes at request time, so the goal is *no
persistent copy*, not "no key anywhere". Three levels exist; USAGE §1a documents
them, `scripts/set-llm-key.sh` implements levels 2 and 3:

| Level | What persists on disk | How |
|---|---|---|
| 1 | plaintext `auth.json` (0600) in **every** instance | `/login` (or writing `auth.json`) |
| 2 | one plaintext `.secrets/llm_key` (0400), outside the data dirs | `make set-key …` |
| 3 | **only a reference** — `PI_KEY_SOURCE=keychain:…` in `.env` | `make set-key … --ephemeral` |

Level 3 fetches the key per run and writes it to tmpfs (`$XDG_RUNTIME_DIR` or
`/dev/shm`, mode 400); nothing survives a reboot. Level 2 still leaves one
plaintext file; level 1 leaves N copies.

Residual, unavoidable while the agent makes its own model calls: the key is
readable by the agent **while it runs** (B1). Level 3 shrinks what persists; it
does not hide the secret from the process holding it. Closing that needs the
credential-injecting proxy (D3/D5).

### Operational tooling added during the review

| Command | Purpose |
|---|---|
| `make doctor` | one-shot triage: docker, image tool set, `.env` perms, secrets, keys, egress mode |
| `make check-keys` | probe each provider key (also resolves the `models.json` secret) |
| `make keys-audit` | which credential each instance will actually use (masked) |
| `make keys-prune PROVIDER=x [APPLY=1]` | remove a stale provider entry from every instance |
| `make set-key …` | store the key as a secret, or reference-only with `--ephemeral` |
| `make refresh-known-hosts` | regenerate the pinned GitHub host keys from GitHub metadata |

Two lessons recorded during the review, because both broke real usage:

1. Hardening removed `make` along with the compiler (C2). `make` is back; only
   `gcc`/`cc`/`ld`/headers stay out, behind `PI_WITH_TOOLCHAIN=1`.
2. `GIT_SSH_COMMAND` cannot carry `ProxyCommand … %h %p` — git splits it on
   whitespace, ssh never tunnels, and on an internal network it then fails with
   "Could not resolve hostname". The ProxyCommand lives in
   `/etc/ssh/ssh_config.d/90-pi-egress.conf` now, verified by `git push`.

**Suggested order for what is left**

1. **A3** — `GITHUB_TOKEN` is duplicated in `.env` and `.secrets/`; make
   `.secrets/` the only source (small, testable).
2. **C6** — no `mem_limit`/`cpus` on the agent service (trivial compose change).
3. **E3** — secret scanning in CI + pre-commit. The transcript leak would have
   been caught by this.
4. **D4** — the vault reads the first `gh_*` secret in readdir order instead of
   the configured path (small C change).
5. **E1** — `MANAGED_REPO_URL` is cloned at build time from a moving ref and its
   `skills/`+`extensions/` land in the agent's auto-load path.
6. **D3 / D5** — token in the `gh` child's environment; SSH key readable by the
   agent. Both need a design change (credential-injecting proxy), which is also
   the only way to close B1/B2 properly.
7. **E2** — no integrity pin on the vendored wiki package (`npm pack` + sha512).
8. **B1 / B2 / B3** — accepted: they are speed bumps, now documented as such.
   Closing them properly means Landlock/seccomp or gVisor, not more preload
   tricks.

---

## P0 — do this now (manual, cannot be automated)

- [ ] **P0.1 Rotate every credential that appears in agent transcripts.**
      Session JSONL files under `.pi-data*/agent/sessions/` contain plaintext
      secrets: a GitHub PAT, an old `DEEPSEEK_API_KEY`, and a complete
      `BEGIN OPENSSH PRIVATE KEY` block (the agent `cat`ed them and pi persisted
      the tool output). **Confirmed dead** (verified against the provider on
      2026-10-25): both DeepSeek keys — `****e65a` and `****d524` both return
      `401 Authentication Fails`. Still to rotate: the GitHub PAT and the git SSH
      key. Then remove the affected session files.
- [ ] **P0.2 Stale keys live in every instance.** 27 `.pi-data*/agent/auth.json`
      copies still hold a retired key, and `auth.json` outranks the secret, so
      rotating in one place is not enough:

      ```bash
      make keys-audit                          # who uses what (masked)
      make keys-prune PROVIDER=deepseek APPLY=1 # remove the stale entry everywhere
      make set-key SET_KEY_ARGS="--provider deepseek --from keychain:pi-deepseek --ephemeral"
      pictl sync && make check-keys
      ```
- [ ] **P0.3 Assume every credential the agent can read is already public.**
      Until B1/B5/D5 are addressed, the model of trust is "the agent holds the
      secret", so scope and expire keys accordingly (read-only deploy keys,
      spend-limited API keys, per-project keys).
- [ ] **P0.4 Never paste a real credential into a test fixture or a commit.**
      GitHub push protection blocked a commit during this review because a
      fixture contained a real leaked key. Fixtures are now assembled from
      fragments; keep it that way.

---

## A. Secret storage & at-rest handling

| ID | Sev | Status | Finding | Where | Remediation |
|---|---|---|---|---|---|
| A1 | crit | **DONE** | Agent transcripts persisted every credential the agent reads, verbatim and unencrypted, and replay them into future context. | `.pi-data*/agent/sessions/*.jsonl` | `src/redact-secrets.ts` extension redacts common credential shapes from every `tool_result` (content + structuredContent) before persistence. Seeded into each instance's `agent/extensions/` by `make setup`. Residual: a secret typed inline in a `tool_call` input is still recorded (redacting it there would change the executed command) |
| A2 | high | **DONE** | `.env` was mode `0644` (world-readable) while holding `GITHUB_TOKEN` and `GIT_GPG_KEY`. | `.env`, `Makefile:setup` | `setup` now enforces `chmod 600 .env` and warns when `.env` is group/world-readable |
| A3 | high | OPEN | GitHub token exists twice: `.env` and `.secrets/github_token.txt`. | `Makefile:246-252` | Drop it from `.env`; support `GITHUB_TOKEN_FILE` / keyring lookup |
| A4 | med | **DONE** | `sync` wrote `<file>.bak` beside credentials, so a superseded key lingered on disk after rotation. | `scripts/sync-agent-config.sh` | Credential files (`auth.json`, `models.json`) are never backed up, and a stale `<file>.bak` from an older sync is removed and reported. Non-credential files still get a backup |
| A5 | med | **DONE (secret route)** | Keys were replicated into every `.pi-data-pi-agent-*` dir with no revocation path; seeding copied `auth.json` wholesale. | `scripts/seed-agent-config.sh` | With the secret route nothing secret lives in the data dir, so seeding/sync only copy a `models.json` reference. Residual: instances still using plaintext `auth.json` keep the old behaviour |
| A6 | med | **DONE** | "Logged in" is not verification — pi stores API keys without validating them, so a dead key looks healthy (this already caused a real outage). | — | `make check-keys` probes each known provider and fails loudly; keys stay masked. Run it on the host |
| A7 | med | **DONE** | Plaintext keys at rest in `auth.json`. | `.pi-data/agent/` | `make set-key` writes the key to `.secrets/llm_key` (`0400`), mounts it as a Docker secret at `/run/secrets/llm_key`, and points `models.json` at it with `apiKey: "!cat /run/secrets/llm_key"`. Sources include macOS keychain, `pass` and 1Password, so the key can stay out of a file entirely. Residual: the agent can still read the secret at runtime (B1), and `auth.json` remains a plaintext fallback |

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
| C2 | high | **DONE** | Compiler toolchain in the runtime image enabled B2 and arbitrary native builds. | `Dockerfile` | Builder stage compiles the two vault binaries; the runtime image has no compiler. `PI_WITH_TOOLCHAIN=1` restores it intentionally |
| C3 | med | **DONE** | `ssh-keyscan github.com` at build time was unverified TOFU; a MITM at build poisoned `known_hosts`. | `Dockerfile` | `src/github_known_hosts` ships the published keys and the build verifies their fingerprints |
| C4 | med | **DONE** | Floating base tag, and the `gh` apt keyring was fetched and piped into apt without verification. | `Dockerfile` | Base pinned by digest; keyring verified with a pinned SHA-256. Remainder: `gh` package version still unpinned (deliberate — upstream prunes versions) |
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

### 2026-10-25 (5) — branch `security/build-hardening`

Request: keep going down the backlog. Closed **C2, C3, C4**.

| ID | Change |
|---|---|
| C2 | Dockerfile is multi-stage: a `builder` stage (gcc + libc6-dev) compiles `gh-vault` and `fs-vault.so`, and only the artefacts are copied into the runtime image. The shipped image has **no compiler**, which removes the main way to defeat the preload shims. Python interpreter/pip are kept (running Python is a core agent task); `build-essential`/`python3-dev` are opt-in via `PI_WITH_TOOLCHAIN=1`. |
| C3 | `src/github_known_hosts` ships GitHub's three published host keys, and the build verifies them against GitHub's published fingerprints with `ssh-keygen -lf`. `ssh-keyscan` at build time (TOFU) is gone. |
| C4 | Base image pinned by digest (`node:26-trixie-slim@sha256:36793bc…`); the GitHub CLI apt keyring is verified against a pinned SHA-256 (`sha256sum -c`) instead of being piped straight into apt. |

Verification: `gcc -Wall -Wextra` clean on both C sources; new
`tests/test-build-hardening.sh` (25 assertions) checks the multi-stage split,
absence of the toolchain in the runtime stage, pinned digest, keyring checksum,
and validates the shipped host keys against the published fingerprints. Full
suite: 268 assertions, 0 failures.

Still needs one real `make build` on a machine with Docker (no daemon here).
C4 remainder: the `gh` *package version* is still unpinned (the repo is pinned
by keyring); pinning it makes builds break whenever upstream prunes versions,
so it stays a deliberate trade-off.

### 2026-10-25 (6) — branch `fix/check-keys`

Closed **A6**. `make check-keys` (`scripts/check-keys.sh`) makes one cheap
read-only call per provider and reports `OK` / `FAIL` / `SKIP`, printing only a
masked fingerprint — never the key. Providers with probes: deepseek, openai,
anthropic, google, opencode (the latter gets a specific message for OpenCode's
`FreeTierError`, since free Zen keys cannot work outside OpenCode).

Notes from building it:

- It runs on the **host**: inside the container the fs-vault shim blocks
  `auth.json` for non-pi processes (by design), and the error message now says so.
- It accepts `--auth-file` to probe a backup or a copy.
- `PI_CHECK_KEYS_CURL` injects the binary, so the test suite is hermetic
  (`tests/helpers/fake-curl.sh` + 23 assertions, no network, no real keys).
- Live run against the existing credentials flagged the `opencode` key as
  HTTP 401 `Invalid credential` — i.e. it is already dead. Rotate it (P0.1).
- `curl` is looked up with `[ -x ]`/`command -v`; test stubs live in the repo
  because `/tmp` is `noexec` in the hardened container (the hardening works).

### 2026-10-25 (7) — branch `fix/sync-credential-backups`

Closed **A4**. `scripts/sync-agent-config.sh` no longer writes `.bak` copies of
`auth.json` / `models.json`, and removes a stale one left by an earlier sync
(reported in the output). Rationale: a `.bak` outlives the rotation it was meant
to protect, so after rotating a key the old one stays live on disk in every
instance. Non-credential files (`settings.json`, `models-store.json`) keep the
old backup behaviour.

Test note: the `auth.json` half of the sync test is skipped when the fixture
cannot be written, because inside the container the fs-vault shim blocks that
path for non-pi processes. It runs fully on the host. This is the second place
where the shim blocks legitimate tooling (the first was `make check-keys`) —
more evidence for B1's "speed bump, not boundary" framing.

---

## Repo hygiene (2026-10-25)

- **Removed `tests.md` from the repo.** It was a tracked, public "security test"
  document that enumerated attack vectors against this container (credential
  capture scripts, direct `auth.json` reads, bypass techniques) and was stale —
  it described binaries that no longer exist. It is an attack map, not
  documentation. A copy was kept locally at `plans/security-attack-notes.md`
  (gitignored) for reference; treat it as sensitive.
- Deleted 12 merged local branches; `main` is the only shared branch left
  (`experimental/subagents` and `version_control_pi_data` are unmerged work).
- Added `make help` and `USAGE.md` so the features are discoverable without
  reading a 700-line README.
- `docs/` exists but is empty and root-owned (cannot be removed from the
  container). Harmless.
- 26 stale `.pi-data-pi-agent-*` directories (~250 MB) are left over from old
  runs. They are gitignored; prune with:
  `ls -d .pi-data-pi-agent-* | grep -v "$(basename "$PWD")" | xargs rm -rf`
  (only after confirming no instance is running).

### 2026-10-25 (8) — branch `fix/llm-key-indirection`

Closed **A7**, and A5 for the secret route. Prompted by a fair objection: the
docs I had just written recommended writing a plaintext key into `auth.json`,
which is exactly the thing flagged in A7.

Mechanism, verified against the real `pi` binary before documenting it:
`models.json` accepts `"apiKey": "!command"` and runs it **at request time**
(`dist/core/http-dispatcher.js` + `docs/models-configuration.md`). A run with a
fake provider key produced `401 … ****3a2b` from a `!printf` command with no
`auth.json` at all, so the indirection is real.

New:

- `scripts/set-llm-key.sh` / `make set-key` — takes the key from **stdin, a
  file, an env var, the macOS keychain, `pass`, or 1Password (`op`)**, writes it
  to `<repo>/.secrets/llm_key` (`0400`), and points `models.json` at
  `/run/secrets/llm_key`. It never echoes the key, refuses empty/whitespace/short
  input, leaves an unrelated `models.json` untouched (prints the stanza instead
  of risking a bad JSON merge), and **warns when the provider still has an
  `auth.json` entry, because that wins**.
- `docker-compose.yml` mounts `llm_key` as a Docker secret (target overridable
  with `LLM_KEY_SECRET_PATH`); `make setup` creates a `0400` placeholder so
  compose never fails on a missing file.
- `make check-keys` now also reads the `models.json` → `!cat /run/secrets/...`
  indirection (mapping the container path back to `<repo>/.secrets/`), so the
  recommended setup is verifiable, and reports which secret the key came from.
- Docs: USAGE §1a now leads with the secret route, marks `/login` as the
  plaintext fallback, and spells out the precedence order
  (`--api-key > auth.json > models.json > env`). README Quick Start step 4
  matches. USAGE §6 gained the new secret in its rotation table.

Residual, unchanged and documented: the agent can still read the secret at
runtime (B1), so this protects the *data directories*, backups and sync — not
the running process. Closing that needs the credential-injecting proxy (D3/D5).

Tests: `tests/test-set-llm-key.sh` (32 assertions, hermetic) plus the extended
`check-keys` suite. Total: 325 assertions, 0 failures.

### 2026-10-25 (9) — branch `fix/restore-basic-functionality`

The hardening broke two things for real users; both are fixed without giving up
the control that caused them.

1. **`make` was gone from the image.** C2 removed `build-essential`, which also
   removed `make` — a build *driver*, not a compiler. A coding-agent container
   without `make` cannot build most projects. `make` is back in the runtime
   stage; `gcc`/`cc`/`ld`/headers stay out (that is the actual B2 control), and
   `PI_WITH_TOOLCHAIN=1` still restores the whole toolchain on demand.

2. **git over SSH was broken with egress on.** The Makefile passed
   `GIT_SSH_COMMAND="ssh … -o ProxyCommand=nc -X connect -x egress:8888 %h %p"`.
   Git splits that value on whitespace, so ssh received `ProxyCommand=nc` plus
   stray args, never tunnelled, and then failed with
   `Could not resolve hostname github.com` — because an `internal: true` network
   also blocks external DNS. Reproduced, then fixed by moving the ProxyCommand
   into `ssh_config` (`/etc/ssh/ssh_config.d/90-pi-egress.conf` +
   `src/ssh-netcat-proxy.sh`), where ssh expands `%h`/`%p` itself. The helper
   falls back to a direct connection when no proxy is configured, so
   `EGRESS=false` still works. Verified end-to-end: `git ls-remote` over SSH
   through the allowlist proxy returns refs.

Also added, because "it stopped working" needs a first response:

- **`make doctor`** (`scripts/doctor.sh`) — docker reachability, `.env`
  permissions, secret files (including placeholders), provider keys, egress mode,
  and — when a daemon is available — whether the image still contains
  `make git ssh nc gh node python3 curl` and the ssh proxy config. Every finding
  prints the command that fixes it.
- **`make refresh-known-hosts`** (`scripts/refresh-known-hosts.sh`) — regenerates
  `src/github_known_hosts` from `https://api.github.com/meta`, checking the keys
  against the fingerprints in the same response and failing closed when
  fingerprints are absent. This replaces "disable StrictHostKeyChecking" when
  GitHub rotates keys.
- Regression tests: `tests/test-basic-functionality.sh` (21 assertions) pins the
  runtime tool set, the ssh_config indirection, the wrapper's argv in both modes,
  and the absence of a `ProxyCommand` in `GIT_SSH_COMMAND`; the build-hardening
  suite gained refresh-known-hosts coverage (30 assertions).

Verification: 30 + 21 assertions green; `git ls-remote` through the proxy works;
`pi -p "reply ok"` still answers with the redaction extension installed.

Note: `make test` itself needs `make`, so the suite runs on the host (or in a
rebuilt image) — inside this pre-fix image only the make-free tests run.

**Verification update.** `git push` was exercised *through* the new
ProxyCommand after the fix: it failed with `GIT_SSH_COMMAND` still exported (git
splits it, ssh never tunnels) and succeeded once the ProxyCommand came from
`ssh_config` — the same push that published this branch. That is the concrete
evidence that "security hardening" and "git works" are not in conflict here.

### 2026-10-25 (10) — branch `fix/key-rotation-across-instances`

Regression report: "401 ****e65a on other projects". Investigated: the key is
genuinely dead at the provider — `api.deepseek.com/models` returns 401 for both
`****e65a` and the older `****d524`. Nothing in the container is broken; the
credential is revoked.

The *reason it looked project-specific* is structural, and it is A5 again: every
instance was seeded once with its own `auth.json`, and `auth.json` outranks the
`models.json` secret. Fixing `.pi-data` therefore does not fix instances created
earlier, and seeding never overwrites an existing `auth.json`.

Added `scripts/keys-audit.mjs` with two Makefile entry points:

- `make keys-audit` — for every `.pi-data*` dir, prints the provider, the
  **effective** credential source (auth.json vs models.json secret) and flags
  entries that shadow the secret. Keys are masked to the last four characters;
  it refuses to guess when a file cannot be read (the first version silently
  reported "no credentials" when the fs-vault shim denied access — now it fails
  loudly and tells you to run it on the host).
- `make keys-prune PROVIDER=<p> [APPLY=1]` — removes a stale provider entry from
  every instance's `auth.json` (dry run by default; atomic write, mode 0600,
  other providers preserved).

Tests: `tests/test-keys-audit.sh` (30 assertions, hermetic).

Also documented the rotation recipe end to end (USAGE troubleshooting, README
"Which key is each instance using?"): revoke at the provider → `make keys-prune`
→ `make set-key` → `pictl sync` → `make check-keys` → restart.

### 2026-10-25 (11) — branch `fix/no-persistent-key-file`

Fair pushback: "this still stores auth keys in text files, right?" — yes, and the
docs implied otherwise. Corrected, and the remaining level implemented.

Honest inventory at the time of asking:

| Where | What |
|---|---|
| `.secrets/llm_key` | the key, plaintext, `0400`, on the host |
| `/run/secrets/llm_key` | the same file bind-mounted into the container (compose secrets are bind mounts, not tmpfs) |
| 27 × `.pi-data*/agent/auth.json` | the old plaintext copies, still preferred over the secret |

A bearer token must exist as bytes at request time, so "no key anywhere" is not
achievable; what is achievable is *no persistent* copy. Added:

- `scripts/materialise-key.sh` — when `PI_KEY_SOURCE` is set
  (`keychain:`, `op:`, `pass:`, `file:`, `env:`), fetch the key per run and write
  it to a **tmpfs** path (`$XDG_RUNTIME_DIR` or `/dev/shm`, mode `400`), printing
  that path for compose. `make run` / `run-args` / `shell` pass it as
  `LLM_KEY_FILE`. Without a source it keeps using `.secrets/llm_key`.
- `make set-key … --ephemeral` — validates the source, records only the
  reference (`PI_KEY_SOURCE=…`) in `.env`, scrubs a previously stored key from
  `.secrets/llm_key`, and writes the `models.json` indirection. Refuses `stdin`
  because the source must be re-readable.
- `docker-compose.yml`: the `llm_key` secret source is `${LLM_KEY_FILE:-.secrets/llm_key}`.

So there are now three levels, stated in USAGE §1a: plaintext in every data dir
(`/login`), one plaintext file outside the data dirs (`make set-key`), or
reference-only + tmpfs (`--ephemeral`). Residual, unchanged: whoever can run code
in the container can read the key while it is materialised (B1) — this reduces
what persists, not what the running agent can see.

Tests: `tests/test-materialise-key.sh` (27 assertions) covers tmpfs placement,
mode 400, stable path, broken sources failing loudly, the `/dev/shm` fallback,
`--ephemeral` scrubbing, and `.env` idempotency.

### 2026-10-25 (12) — branch `docs/security-status`

Tracker refresh requested: folded the last three rounds (keys-audit/prune,
basic-functionality restore, reference-only credential mode) into the status
snapshot instead of leaving them only in the work log.

Changed in this file:

- Snapshot now states the **credential model** as three levels (plaintext in
  every instance → one file outside the data dirs → reference-only + tmpfs), with
  the honest residual: a bearer token must exist in memory at request time, so
  the goal is no *persistent* copy, not "no key anywhere".
- Added the operational tooling table (`doctor`, `check-keys`, `keys-audit`,
  `keys-prune`, `set-key`, `refresh-known-hosts`) so the tooling is not buried in
  the log.
- Recorded the two lessons that broke real usage: `make` removed with the
  compiler (C2), and `GIT_SSH_COMMAND` mangling `ProxyCommand %h %p`.
- P0 rewritten against the verified state: both DeepSeek keys are confirmed
  dead at the provider; what remains is rotating the PAT and git SSH key, and
  pruning the stale key out of 27 instance copies.
