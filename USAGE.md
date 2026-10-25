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

### 1a. Set up a model provider (so the first session just works)

Pi needs a key before it can talk to a model. **Put it in the default
`.pi-data`**, because every per-project instance is *seeded from there* on first
start — a key you add inside `pictl`'s own instance stays in that instance.

Pick one route:

**Route A — interactive login (recommended)**

```bash
make run          # plain `make run`, not `pictl`: it uses the default .pi-data
```

In the TUI run `/login`, choose the provider, paste the key. It is written to
`.pi-data/agent/auth.json` (mode `0600`). Quit the session.

**Route B — write the credential file yourself**

```bash
install -m 700 -d .pi-data/agent
cat > .pi-data/agent/auth.json <<'JSON'
{
  "deepseek": {
    "type": "api_key",
    "key": "sk-your-deepseek-key"
  }
}
JSON
chmod 600 .pi-data/agent/auth.json
```

The provider name is the key of the object (`deepseek`, `opencode`, `openai`,
`anthropic`, …). Several providers can coexist in one file.

**Route C — environment variables (CI, or you do not want a file)**

```bash
DEEPSEEK_API_KEY=sk-... make run      # or OPENCODE_API_KEY, OPENAI_API_KEY, ...
```

Caveat: **`auth.json` wins over the environment**. If a stale entry exists
there, the env var is ignored — that is the classic "I set the key but it still
401s" trap. Remove the provider entry from `auth.json` (or fix it) instead.

**Choose the default model** so sessions start on it. Either press `Ctrl+S` on a
model in `/model` (saves it), or edit `.pi-data/agent/settings.json`:

```json
{
  "defaultProvider": "deepseek",
  "defaultModel": "deepseek-flash"
}
```

**Then verify before blaming the model:**

```bash
make check-keys
```

```
STATUS PROVIDER     KEY                  DETAIL
OK     deepseek     sk-e5f…e65a          HTTP 200
FAIL   opencode     sk-1eD…CMQX          HTTP 401 — key rejected
```

`check-keys` runs on the **host** (inside the container the preload shim blocks
`auth.json` by design) and never prints the key itself.

> **OpenCode note:** free-tier Zen keys only work inside OpenCode itself —
> pi gets `403 FreeTierError`. Use a paid Zen key, or stick to a provider whose
> API accepts your key (DeepSeek, OpenAI, Anthropic, Google).

**Propagating later:** instances created *after* this inherit the key
automatically. Instances that already exist need
`pictl sync` (see §5), and running containers need a restart.

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

`pictl` always names the instance after the workspace directory, so you rarely
need to think about it:

```bash
pictl ~/code/app-a     # -> PROJECT_NAME=pi-agent-app-a
                       #    data dir .pi-data-pi-agent-app-a
                       #    own Docker network, own container
pictl ~/code/app-b     # -> pi-agent-app-b, fully separate
```

Plain `make run` without a path is the exception: it uses the default
`.pi-data` and no project name.

### When you do need `-p/--project`

| Situation | Why the derived name is not enough |
|---|---|
| Two directories share a basename (`~/work/app`, `~/side/app`) | both derive `pi-agent-app`, so they would share a data dir **and** a Docker network |
| You want two sessions on the *same* directory (e.g. two branches) | same derived name; `-p` gives each its own sessions/settings |
| You want a stable name | the derived name changes if you rename or move the directory |

```bash
pictl -p app-work ~/work/app      # -> .pi-data-pi-agent-app-work
pictl -p app-side ~/side/app
```

`-p` changes the data dir and network name only — the workspace mount is
whatever directory you passed.

### Seeding and syncing

A new instance is **seeded from the default `.pi-data`** on first start, so
whatever provider login/settings the default dir has, the new instance inherits.
Changes made after that stay local.

To push the default config into instances that already exist:

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
