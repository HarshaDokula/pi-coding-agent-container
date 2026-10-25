# Using this container

A walkthrough of what you can do and how. Feature details live in
[README.md](README.md); the threat model lives in [SECURITY.md](SECURITY.md).

---

## 1. First time

```bash
cd ~/path/to/pi-coding-agent-container

cp .env.example .env      # GIT_NAME / GIT_EMAIL at minimum
make ssh-key              # dedicated ed25519 key, prints the public half
                          # add it at https://github.com/settings/ssh/new
make setup                # creates .pi-data, .secrets, tightens .env to 0600
make build                # builds the image (Docker required)
make install              # optional: puts `pictl` on your PATH
```

Log in to a model provider once, inside the agent:

```bash
pictl          # then run /login in the TUI, pick provider, paste the key
# or set it from the shell:
PI_API_KEY=... make run   # provider-specific env var also works, but auth.json wins
```

Then verify the key is alive before blaming the model:

```bash
make check-keys
```

```
STATUS PROVIDER     KEY                  DETAIL
OK     deepseek     sk-e5f…e65a          HTTP 200
```

---

## 2. Running the agent

```bash
pictl                       # agent on the current directory
pictl ~/code/my-project     # agent on a specific directory
pictl ~/code/app ~/code/lib # two directories, mounted side by side
pictl -a "fix the failing tests"   # one-off prompt, no TUI
pictl -d -a "..."                  # same, in the background
```

Without `pictl` (it just wraps this):

```bash
make run                            # WORK_DIR from .env, default ./workspace
make run WORK_DIR=~/code/my-project
make run-args args="summarise this repo"
make shell                          # bash inside the container
```

| Flag | Meaning |
|---|---|
| `pictl -a "prompt"` | one-off prompt instead of the TUI |
| `pictl -d` | detached (background) |
| `pictl -p NAME` | isolated instance: own network, own `.pi-data-NAME` |
| `pictl -w` | load the shared LLM-Wiki knowledge base |
| `pictl -r` / `--research` | allow arbitrary public web for this session |
| `pictl --no-egress` | disable the egress proxy for this session |
| `pictl -- VAR=value` | anything else goes straight to `make` |
| `pictl --dry-run` | print the `make` command without running it |

---

## 3. Network access (egress)

The container has **no direct internet access**. All traffic goes through an
allowlist proxy, so a leaked key cannot be posted to a random host.

| Mode | Command | What is reachable |
|---|---|---|
| allowlist (default) | `pictl` | model providers, GitHub (HTTPS + SSH), npm, PyPI, crates, common search APIs |
| research | `pictl -r` | the allowlist **plus any public host on 80/443** — loopback, private ranges, `*.internal`, cloud metadata and non-web ports stay blocked |
| off | `pictl --no-egress` | everything (legacy, unfiltered) |

When something is blocked, the proxy tells you what to add:

```
egress-proxy: DENY docs.example.com:443 (not in EGRESS_ALLOWLIST)
```

```bash
pictl -- EGRESS_ALLOWLIST=api.deepseek.com,github.com,github.com:22,docs.example.com
# or persist it:
echo 'EGRESS_ALLOWLIST=api.deepseek.com,github.com,github.com:22,docs.example.com' >> .env
```

Use `-r` when you genuinely need open-ended research; use the allowlist for
everything else.

---

## 4. GitHub access

Two separate credentials, on purpose:

* **git push/pull** uses SSH with `~/.ssh/pi_agent_ed25519`, mounted read-only
  at `/home/node/.ssh/git_key`. Nothing else from your `~/.ssh` is exposed.
* **`gh` API calls** use a token from `.secrets/github_token.txt` (optional):

  ```bash
  cp .env.example .env
  # put GITHUB_TOKEN=... in .env once, then:
  make setup     # migrates it into .secrets/ (chmod 400) and warns
  ```

  `gh` is guarded: `auth`, `repo`, `secret`, `ssh-key`, `gpg-key`, `config`,
  `alias`, `extension`, `gist`, `copilot` and `codespace` are denied, and
  `gh api` is read-only (GET only, no custom auth headers, no `--hostname`,
  no request bodies). Use `gh issue`, `gh pr`, `gh release`, `gh search`.

---

## 5. Multiple projects at once

Each project gets its own data dir, network and container:

```bash
pictl ~/code/app-a            # -> .pi-data-pi-agent-app-a, own /24, own container
pictl ~/code/app-b
```

Config changes in the default `.pi-data` are seeded into **new** instances
only. To push them into existing ones:

```bash
pictl sync --dry-run     # show what would change
pictl sync               # apply (credential files are never backed up)
pictl net-clean          # reclaim Docker networks from finished projects
```

---

## 6. Secret hygiene

Where things live, and what to do:

| Secret | Location | Rotation |
|---|---|---|
| Provider keys | `.pi-data/agent/auth.json` (`0600`) | `/login` again, or edit the file, then `pictl sync` |
| GitHub token | `.secrets/github_token.txt` (`0400`) → `/run/secrets/gh_*` | replace the file, `make setup`, restart |
| git SSH key | `~/.ssh/pi_agent_ed25519` | `rm` it, `make ssh-key`, re-add on GitHub |
| Session transcripts | `.pi-data*/agent/sessions/*.jsonl` | prune: `find .pi-data* -name '*.jsonl' -mtime +30 -delete` |

Guardrails that are already on:

* tool results are **redacted** before being written to a transcript
  (`src/redact-secrets.ts`) — PATs, `sk-` keys, PEM blocks, `Bearer` values;
* `sync` never leaves `.bak` copies of credential files;
* `.env` is forced to `0600` by `make setup`;
* egress is allowlisted (see §3).

**Rotate a key** (do this after any leaked paste):

```bash
# 1. revoke it at the provider
# 2. update the local copy
$EDITOR .pi-data/agent/auth.json      # or re-run /login
# 3. propagate + verify
pictl sync && make check-keys
# 4. restart running instances
```

Never commit `.pi-data*`, `.secrets/`, `.env` — all are gitignored. If a secret
ever lands in a commit, rotate it; removing the file is not enough.

---

## 7. Keeping it current

```bash
make test          # 290+ assertions, no Docker needed
make update        # rebuild the image from scratch
make check-keys    # are the provider keys still valid?
pictl net-clean    # if Docker complains about exhausted address pools
make clean         # stop containers
```

The image is pinned (`PI_VERSION`, base-image digest). To upgrade pi:

```bash
echo 'PI_VERSION=1.5.0' >> .env   # or: make build PI_VERSION=1.5.0
make update
```

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No models available` / instant 401 | key missing or dead → `make check-keys`; `DEEPSEEK_API_KEY` in `.env` will **not** override a bad `auth.json` |
| `egress-proxy: DENY host:port` | add the host to `EGRESS_ALLOWLIST`, or run with `pictl -r` |
| `[SYSTEM BLOCK]` from `gh` | that command is denied by design (see §4) |
| `git push` fails with host key error | the image ships pinned `known_hosts`; report it rather than disabling StrictHostKeyChecking |
| `make: *** Refusing to run as root` | run as your normal user; the container maps your uid |
| `all predefined address pools have been fully subnetted` | `pictl net-clean` |
| `make check-keys` says "nothing probeable" | run it on the **host** (the in-container shim blocks `auth.json` by design) |
| Two instances fighting over ports/network | give each a `pictl -p NAME` |
| Want the old, unfiltered behaviour | `pictl --no-egress` |

---

## 9. What this container does *not* protect against

It isolates you from the host (files, privileges, Docker socket) and limits
where credentials can go. It does **not** stop the agent from reading its own
provider key and using it, and in `research` mode it cannot stop a determined
agent from sending data to a public host. See README §4–5 and SECURITY.md for
the honest boundary.
