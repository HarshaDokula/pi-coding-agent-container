# Security model

> **Purpose:** What the container enforces, what is only a speed bump, and what remains exposed.
>
> Back to [README](../README.md) · [documentation index](README.md).


This container keeps the agent away from **your host** — its files, its
privileges, its Docker daemon. It does **not** keep the agent away from its own
credentials, and it should not be described as if it did. The sections below
separate what the kernel enforces from what is only a speed bump. The full
threat model and the remediation backlog live in [SECURITY.md](../SECURITY.md).

## 1. Guards that are enforced

* **Privilege and filesystem isolation come from Docker, not from scripts in
  this repo.** The container runs as your `HOST_UID` (`make` now refuses to run
  as `uid 0`), with `cap_drop: ALL`, `no-new-privileges`, a read-only root
  filesystem, `noexec` tmpfs for `/tmp`, `~/.config` and `~/.npm`, a
  `pids_limit`, and no Docker socket. Only the workspace, `.pi-data`, and the
  per-instance toolchain volume are writable; `/tmp`, `~/.config`, and `~/.npm`
  are `noexec` tmpfs, and the rest of the root filesystem is read-only.
* **Binary purge:** `su`, `mount`, `passwd`, `login`, `unshare`, `nsenter`, …
  are deleted at build time and every remaining setuid/setgid bit is stripped
  (`chmod a-s`) — including `gh`, which is **no longer setuid**.
* **Git transport:** push/pull/fetch use SSH with one dedicated key mounted at
  `/home/node/.ssh/git_key`. The GitHub token is only used by `gh` for API
  calls, never for git transport.

## 2. `gh` guardrail (always on, no switch)

`gh` is a small wrapper (`src/gh-vault.c`) that reads the token from the Docker
secret and execs `src/gh-guard.sh`. The guard blocks `gh auth`, `repo`,
`secret`, `ssh-key`, `gpg-key`, `config`, `alias`, `extension`, `gist`,
`copilot` and `codespace`, and only hands the token to git's credential helper
when a genuine git operation is in the process ancestry. There is no
`PARANOID_MODE` toggle — the guard is unconditional.

`gh api` is allowed **read-only only**: `-X`/`--method` must be `GET`, and
sensitive headers (`Authorization`, `Cookie`, `Proxy-Authorization`),
`--hostname`, `--input` and `-f`/`-F`/`--field` (request bodies) are rejected.
Anything still reachable through read-only `gh api` is bounded by the token's
own scopes, so keep it single-purpose and expiring.

## 3. Credential handling — the honest version

* The GitHub token is a Docker secret mounted at `/run/secrets/gh_*` with mode
  `0444`: readable by the container user, which is the same user the agent runs
  as. Docker secrets keep it out of `docker inspect`, out of the image and out
  of `docker-compose.yml`; they do **not** put it out of the agent's reach.
* The wrapper passes the token to the `gh` child in the environment, so a
  same-UID process can read it from `/proc/<pid>/environ`.
* LLM provider keys have three storage levels ([USAGE §1a](../USAGE.md)): plaintext
  `auth.json` (mode `0600`) in the data dir, one `.secrets/llm_key` file
  (`0400`) referenced from `models.json`, or a reference-only `PI_KEY_SOURCE`
  materialised into tmpfs per run. Seeding/`make sync` copy `auth.json` and the
  `models.json` reference; the default secret route keeps the key itself out of
  the data dirs. `.env` (which may hold the GitHub token or a key reference) is
  tightened to `0600` by `make setup`.

## 4. Execution firewalls — speed bumps, not boundaries

`src/fs-vault.c` (an `LD_PRELOAD` shim, activated via `/etc/ld.so.preload`) and
`src/app-firewall.js` (a `NODE_OPTIONS=--require` shim) between them deny reads
of `auth.json`, `.secrets`, `.env`, and `/run/secrets/gh_*` from *casual* child
processes such as `cat`, `grep` or `python`. They are useful: they stop
accident-prone exploration and they keep the agent from stumbling into a key by
reflex.

They are **not** a security boundary:

* `LD_PRELOAD` is user space, not kernel interception. Statically linked
  binaries (put one in `/workspace`, or rebuild with `PI_WITH_TOOLCHAIN=1` to
  restore `gcc`), raw syscalls and `AT_SECURE` executables bypass it.
  `/workspace` is writable and executable, and `/tmp` being `noexec` does not
  prevent building or placing a binary elsewhere.
* The shim's allowlist lets any process whose command line contains `pi` read
  `auth.json` — including pi's own `read` tool, which is the agent's primary
  way to read files.
* `NODE_OPTIONS` can be cleared (`env -u NODE_OPTIONS …`) or avoided by any
  non-Node tool, and `app-firewall.js` matches path substrings, so it also
  blocks harmless files (e.g. `.env.example`).

## 5. What this means for your data

A built-in extension (`src/redact-secrets.ts`, installed into the data dir by
`make setup`) strips common credential shapes — GitHub PATs and tokens,
`sk-` API keys, AWS access key IDs, `Bearer`/`Basic` authorization values and
PEM private-key blocks — from every tool result before it is persisted.

One thing is **not** covered: a secret the agent types inline in a command is
still recorded as that command's input (redacting it there would change what
executes). Network egress is bounded instead, by the allowlist in §6: a
secret the agent already holds can only leave to an approved host. Treat
`.pi-data*` as secret-bearing: restrict its permissions, exclude it from
unencrypted backups, prune it, and rotate any credential that has already
appeared in an old session. Both residuals are tracked in
[SECURITY.md](../SECURITY.md) (A1, B5).

## 6. Outbound egress control

The agent runs arbitrary code and can read its own provider keys, so its
outbound network is controlled. `pi_network` is an `internal: true` Docker
network and the `egress` sidecar (`src/egress-proxy.js`, loaded from
[`docker-compose.egress.yml`](../docker-compose.egress.yml)) is the only route
out. Three modes:

| `EGRESS=` | Behaviour | Use for |
|---|---|---|
| *(unset)* / `true` | **allowlist** (default) — only `EGRESS_ALLOWLIST` hosts | everyday coding, PR/issue work |
| `research` | allowlist **plus any public host on 80/443**, with an SSRF guard | researching a broad topic or very recent news |
| `false` | no proxy at all (legacy) | only if you accept an unnetted container |

```bash
make run                     # allowlist
make run EGRESS=research     # allowlist + arbitrary public web
make run EGRESS=false        # no egress control

pictl                        # allowlist (default)
pictl -r                     # same as EGRESS=research
pictl --no-egress            # same as EGRESS=false
```

All three work through `pictl` too: `-r`/`--research` and `--no-egress` map to
the `EGRESS` variable, `pictl -- EGRESS=research` still passes through, and an
`EGRESS` value inherited from the environment is surfaced in `pictl --dry-run`
so the printed command always shows the mode that will be used.

**Research mode** exists precisely for the "I need to read arbitrary sites"
case. It still refuses anything that could be used to pivot onto your machine
or cloud: loopback, RFC1918, link-local, CGNAT, multicast, `*.internal`,
`*.local`, `host.docker.internal`, and metadata endpoints (`169.254.169.254`,
`metadata.google.internal`, …). It also refuses non-web ports. That is the
difference between it and `EGRESS=false`: you get the open web, not the open
network.

```bash
# denied — cannot reach the Docker host or cloud metadata
egress-proxy: DENY 169.254.169.254:80 (non-public address)
egress-proxy: DENY host.docker.internal:443 (blocked hostname)
# allowed — public research traffic, logged
egress-proxy: ALLOW news.ycombinator.com:443 (research)
```

The allowlist in both modes covers what the agent needs to keep working: model
providers, `github.com` for HTTPS **and** `github.com:22` for SSH,
`codeload.github.com` / `*.githubusercontent.com`, npm, PyPI, crates.io, and
common search APIs (DuckDuckGo, Wikipedia, Brave, Serper, Tavily, Exa).

How traffic is routed:

| Traffic | Mechanism |
|---|---|
| Model / API calls | `HTTPS_PROXY=http://egress:8888` — pi installs an undici `EnvHttpProxyAgent`, so all provider requests honour it |
| `gh`, `curl`, `npm`, `pip` | standard `HTTPS_PROXY` / `HTTP_PROXY` support |
| `git` over SSH | `/etc/ssh/ssh_config.d/90-pi-egress.conf` sets `ProxyCommand` to `src/ssh-netcat-proxy.sh` (`nc -X connect -x egress:8888`); `GIT_SSH_COMMAND` is deliberately left alone |
| container → internal hosts | impossible: internal network plus the SSRF guard |

**The honest trade-off.** In research mode the agent can reach any public host,
so a leaked key *can* be posted somewhere on the internet — CONNECT tunnels are
opaque, so the proxy cannot inspect methods or payloads. Your options, in order
of strength:

1. Keep the default allowlist and add hosts as the `DENY` log tells you to.
2. Flip to `EGRESS=research` only for the session where you need it, and rotate
   keys if you suspect a prompt injection happened.
3. Move the keys out of the agent entirely with a credential-injecting proxy
   (the OpenShell model) — the only way to get arbitrary browsing *and* keep
   secrets unreadable by the agent.

> Verified in this repo: allowlist and research-mode decisions, the SSRF guard
> against loopback/private/metadata addresses, DNS-rebinding (mixed public +
> private answers), HTTP forward, CONNECT allow/deny, plus end-to-end
> `curl`/`fetch` runs through the proxy (`example.com` 200 through research
> mode, `169.254.169.254` 403). The unit tests cover the proxy and compose
> wiring; a live `make run` on a machine with a Docker daemon is still the
> final smoke test.

## 7. Git is built from source, and pinned

The image does not use Debian's git (`2.47.3`). It builds **git from source**
(currently `2.56.1`) in the builder stage and installs it at `/usr/local/git`,
because `git worktree add --relative-paths` only exists from 2.48 and is
required for a worktree to be usable when just the worktree is bind-mounted into
a container (a worktree's `.git` file records an absolute path into the main
repository).

Supply-chain handling matches the rest of the image:

- the source tarball is pinned by version **and** verified against a pinned
  SHA-256 before it is unpacked; a mismatch fails the build;
- the compiler never reaches the runtime image — only the installed tree is
  copied across (C2);
- the distro package stays installed at `/usr/bin/git`, because
  `src/gh-guard.sh` calls that path; the hardening wrapper at
  `/usr/local/bin/git` still unsets `GIT_TRACE*` and execs the new binary;
- both binaries receive the same `insteadOf` / `core.sshCommand` system config,
  so behaviour does not depend on which one runs.

Bump `GIT_VERSION` and `GIT_SHA256` together:

```bash
curl -fsSL https://github.com/git/git/archive/refs/tags/v<version>.tar.gz | sha256sum
```
