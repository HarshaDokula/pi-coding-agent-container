# pi coding agent (dockerized)

Almost secure, containerized environment for running the [pi coding agent](https://github.com/earendil-works/pi). Designed for local execution with strict file-system isolation, privilege drop, and persistent storage.

## Quick Start

**1. Configuration**
```bash
cp .env.example .env
# Edit .env with your Git identity (and optionally a GitHub token for gh API)
```

**2. Build**
Compiles the image from source and strips OS privilege escalation binaries.
```bash
make build
```

**3. Run**
Starts the agent in interactive TUI mode.
```bash
make run
```

---

## Run From Anywhere (the `pictl` command)

Tired of `cd`-ing into this project and typing `make run WORK_DIR=...` every
time? Install the `pictl` launcher once — it puts a `pictl` command on your
PATH that starts the agent on any workspace, from any directory:

```bash
make install        # symlinks bin/pictl -> ~/.local/bin/pictl
```

Then, from anywhere:

```bash
pictl                         # agent on the current directory
pictl ~/code/my-project       # agent on a specific project
pictl ~/code/app ~/code/lib   # app -> /workspace/app, lib -> /workspace/lib
pictl -d -a "fix the tests"   # one-off prompt, in the background
```

The launcher finds this project through its own symlink, so no paths are
hardcoded — it keeps working even if you move or rename the checkout. It
simply builds the same `make run`/`make run-args` command you would type
here, so every existing option (`.env`, `SSH_KEY`, `DETACHED`, ...) still
applies.

| Command | Meaning |
|---|---|
| `pictl [path ...]` | Workspace(s) to mount; defaults to the **current directory** |
| `pictl -a "prompt"` | Run a one-off prompt (`make run-args`) instead of the TUI |
| `pictl -d` | Detached (background) mode |
| `pictl -p NAME` | Explicit `PROJECT_NAME` for multi-instance runs |
| `pictl -w` | Opt in to the shared LLM Wiki KB for this session |
| `pictl -- VAR=value` | Anything after `--` is passed straight to `make` |
| `pictl --dry-run` | Print the `make` command without running it |

If `~/.local/bin` is not on your PATH, add it:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

To point the launcher at a different checkout (or if you copied the script
instead of symlinking it), set `PI_CONTAINER_DIR`:
```bash
PI_CONTAINER_DIR=/path/to/pi-coding-container pictl ~/code/my-project
```

Remove the launcher with `make uninstall`.

---

## Usage

**Passing Arguments**
Use the `run-args` target to pass specific flags, commands, or one-off prompts to the agent.
```bash
# Check version
make args="--version" run-args

# Trigger Copilot authentication
make args="/login" run-args

# Execute a direct prompt
make args="'Create a snake game in python'" run-args
```

**Workspace Directory**
By default, the container mounts `./workspace` (relative to this project) as the agent's workspace at `/workspace`. This is where `pi` runs and where any files the agent creates are written.

To mount a different directory (e.g., an existing project repo), use the `WORK_DIR` variable:
```bash
# Mount your project directly — no copying needed
make run WORK_DIR=/path/to/your/project

# Also works with shell and run-args
make shell WORK_DIR=/path/to/your/project
```

To mount more than one directory, pass a whitespace-separated list (the same
way most Unix commands accept multiple paths). Every directory is mounted side
by side at `/workspace/<folder-name>`, and the agent's working directory is
`/workspace`:
```bash
make run WORK_DIR="/path/to/app /path/to/lib"
# /path/to/app -> /workspace/app
# /path/to/lib -> /workspace/lib
# cwd -> /workspace   (both visible as siblings)

# pictl takes the directories as separate arguments
pictl /path/to/app /path/to/lib
```

> `/workspace` is a direct bind, not a named compose volume, so switching
> between single- and multi-directory runs never changes a volume config or
> prompts to recreate one. With several directories, `/workspace` is an empty,
> gitignored `.pi-workspace/` folder in this project, so only your mounted
> projects appear under it.
>
> The agent's per-project state (`PI_DATA_DIR`) follows the first directory,
> because `PROJECT_NAME` is derived from it. A multi-directory session therefore
> reuses the first directory's conversations and settings; the other
> directories' own `.pi-data-*` dirs are left untouched and are not mounted. Use
> `PI_DATA_DIR=...` (or `pictl -p NAME`) to point at a different state dir.

> Paths containing whitespace are not supported (make splits `WORK_DIR` on
> whitespace), so keep one directory per value or use symlinks.

You can also set it permanently in `.env`:
```bash
echo 'WORK_DIR=/path/to/your/project' >> .env
```

**Git over SSH**

The container routes all `https://github.com/` git URLs over SSH so the agent
uses a single SSH key from your host instead of the GitHub HTTPS token. Only the
one private key you specify is mounted read-only into the container (at
`/home/node/.ssh/git_key`) — not your whole `~/.ssh` directory. GitHub's host
key is pinned at build time, so no `known_hosts` mount is needed. `gh` remains
available for GitHub API operations when a `GITHUB_TOKEN` is configured (it
uses the vaulted token); git itself never needs the token.

Create a dedicated key with one command:

```bash
make ssh-key
# -> prints the public key; add it to https://github.com/settings/ssh/new
```

Then run as usual:

```bash
# Default: mounts $HOME/.ssh/pi_agent_ed25519
make run

# Override the key (e.g. an RSA key or a github-specific key)
make run SSH_KEY=/path/to/your/key

# Or set it permanently in .env
echo 'SSH_KEY=/path/to/your/key' >> .env
```

> **Note:** The agent still gets read access to that one private key (required
> for SSH auth), but no other keys, SSH config, or credentials are exposed.
> Point `SSH_KEY` at a dedicated, revocable key you trust the agent to use.

**What the SSH key can and cannot do**

The SSH key is only an **authentication** credential for git-over-SSH transport.
It lets git clone/pull/push/fetch against any repository your GitHub account can
access. It does **not**:
* access the GitHub REST/GraphQL API (issues, PRs, releases, settings),
* call the GitHub Actions API directly,
* act as the `gh` CLI token,
* or sign commits — commit signing is a separate key.

One nuance: pushing commits or tags is still just git, but a push can
*indirectly* trigger GitHub Actions workflows configured on `push` /
`pull_request` events. That is a side effect of the push itself, not an API
capability of the key.

Commit signing is controlled by the **GPG** settings (`GIT_GPG_KEY` /
`GIT_GPG_SIGN`) and is unrelated to the SSH auth key.

**Running Multiple Instances**

Each workspace gets its own isolated instance automatically. Pass `WORK_DIR`
on the command line and a project identity is derived from the folder name
(the first directory, when several are mounted):

```bash
make run WORK_DIR=/path/to/project-a
# behaves like: PROJECT_NAME=pi-agent-project-a
```

This gives each workspace its own compose project (network, volume names),
its own data dir `.pi-data-pi-agent-project-a` (seeded with the provider
config from `.pi-data`), and its own container. You can run several of these
at once — different workspaces never collide, because compose namespaces
networks/volumes under the derived project name instead of the repo folder
name.

For multiple agents on the *same* workspace, or any custom name, pass an
explicit `PROJECT_NAME`, which always wins over the derived one:

```bash
make run PROJECT_NAME=agent1 WORK_DIR=/path/to/project-a
make run PROJECT_NAME=agent2 WORK_DIR=/path/to/project-b
```

Each `PROJECT_NAME` becomes a separate docker compose project with its own
network and container naming. Agent state (sessions, settings, skills) is kept
in `.pi-data-<PROJECT_NAME>` by default, so instances do not interfere with each
other. A fresh data dir is automatically seeded with the agent config from the
default `.pi-data` (provider login, settings, model cache, skills, extensions),
so a new instance works out of the box with the same models — no re-login
needed. Sessions are never copied: each instance keeps its own history.
Override the data directory explicitly with `PI_DATA_DIR`:

```bash
make run PROJECT_NAME=agent1 PI_DATA_DIR=/tmp/agent1-data WORK_DIR=/path/to/a
```

If you use managed skills/extensions, build each instance with the same
`PROJECT_NAME` so skills are copied into that instance's data directory:

```bash
make build PROJECT_NAME=agent1
```

`PROJECT_NAME` must be a valid docker compose project name (letters, digits,
dashes, and underscores).

**Docker Network Address Pool**

Each project gets its own bridge network. By default Docker hands every new
network a whole `/16` from a pool of only ~15 blocks (`172.17.0.0/16` ..
`172.31.0.0/16`), so after a dozen or so projects the next run fails with:

```
failed to create network ...: Error response from daemon:
all predefined address pools have been fully subnetted
```

The Makefile/`pictl` avoid this by giving each project network an explicit `/24`
from a private block (`10.200.0.0/13` by default). By default this is fully
deterministic — the project name is hashed to a `/24` inside the base and **no
host state is read**. Keep the base clear of your LAN/VPN and nothing clashes.
Set `PI_NETWORK_DISCOVERY=1` to opt in to scanning Docker networks, host
addresses and host routes and picking the first free `/24` instead.

The recommended hardened setup is to pin the base explicitly (in `.env`) and
leave discovery off:

```bash
# pin the block project /24s are allocated from (anything /8../16)
PI_NETWORK_BASE=10.200.0.0/13
# deterministic, reads nothing from the host:
PI_NETWORK_DISCOVERY=0
# or pin one exact subnet (single-instance only — global in .env!):
# PI_NETWORK_SUBNET=10.200.7.0/24
```

If you do turn discovery on, check what is already taken before choosing a
block:

```bash
ip -4 route show table all             # LAN + VPN routes (e.g. Twingate)
ip -4 addr show                        # host interface subnets (sdwan0/tun0 = VPN)
docker network inspect "$(docker network ls -q)" \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}'
```

Networks created by older versions (before explicit subnets) are never removed
by `docker compose run --rm`, so they linger and hold addresses. Reclaim them
with `make net-clean` (see below).

**Syncing Config to Other Instances**

A login or config change made in the default `.pi-data` is copied into new
per-workspace data dirs automatically (seeding on first start), but **not** into
instances that already exist. To propagate it deliberately:

```bash
# preview what would change across every existing .pi-data-pi-agent-* dir
make sync SYNC_ARGS=--dry-run
pictl sync --dry-run            # equivalent

# apply
make sync
pictl sync

# target a single instance
pictl sync --to .pi-data-pi-agent-myproject
```

`sync` copies `auth.json`, `models.json`, `settings.json`, and
`models-store.json` from `.pi-data/agent/` into each existing
`.pi-data-pi-agent-*/agent/`. It backs up replaced files to `<file>.bak`, keeps
credential/model files at mode `600` (`settings.json` at `644`), never deletes
target files, and never modifies the source. Syncing is **manual by design** —
it is not part of `make setup`, so a running instance is never changed without
your say-so. Restart running containers (`pictl` / `make run`) afterward; they
load credentials at startup.

**Detached Mode**

By default `make run` and `make run-args` start the agent in the foreground
(interactive TUI). To run a container in the background instead, set
`DETACHED=true` (or `1`):

```bash
make run-args DETACHED=true args="'Create a snake game in python'"
```

Detached containers are still removed automatically when they exit (same
`--rm` behavior as foreground runs). Use `docker ps` to list running detached
containers and `docker logs <container-id>` to follow their output. Set
`DETACHED=true` in `.env` to make detached the default:

```bash
echo 'DETACHED=true' >> .env
```

**Maintenance & Debugging**
```bash
# Run the shell test suite
make test

# Vendor/refresh the opt-in LLM Wiki package (host, idempotent)
make wiki-setup

# Access the container shell (runs as user 1000)
make shell

# Stop and remove running containers/networks
make clean

# Remove unused *_pi_network bridges left behind by old runs (reclaims the pool)
make net-clean

# Force rebuild the image without cache
make update
```

---

## Offline Mode (llama.cpp)

To run the agent completely offline using local models, configure the following files in your `.pi-data/agent/` directory:

**.pi-data/agent/models.json**
```json
{
  "providers": {
    "llama-cpp": {
      "baseUrl": "http://127.0.0.1:1337/v1",
      "api": "openai-completions",
      "apiKey": "none",
      "models": [
        {
          "id": "gemma-4-26B-A4B-it-GGUF"
        }
      ]
    }
  }
}
```

**.pi-data/agent/settings.json**
```json
{
  "defaultProvider": "llama-cpp",
  "defaultModel": "gemma-4-26B-A4B-it-GGUF",
  "autocompleteMaxVisible": 7,
  "defaultThinkingLevel": "off"
}
```

---

---

## 📦 Managed Skills & Extensions

You can version-control custom **skills** and **extensions** in a separate git repository,
and have them automatically included in the Docker image at build time.

### How it works

1. Create (or fork) a git repo with the **pi-package** structure.
2. Add your custom skills to `skills/` and extensions to `extensions/`.
3. Pass the repo URL when building the image.

At **build time**, the `Makefile` clones the repo, installs npm dependencies,
and copies skills/extensions directly into `.pi-data/agent/skills/` and
`.pi-data/agent/extensions/` on the host. Since `.pi-data/` is bind-mounted
into the container at `/home/node/.pi/`, these are immediately available
to the agent at runtime — no entrypoint wrappers needed.

Your managed repo should follow the **pi-package** structure — a `package.json` with a `pi` manifest
pointing to `skills/` and `extensions/` directories.

```json
{
  "name": "my-pi-skills-extensions",
  "keywords": ["pi-package"],
  "pi": {
    "skills": ["./skills"],
    "extensions": ["./extensions"]
  }
}
```

See the [pi packages documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/packages.md) for details.

### Build with Managed Repo

Set the URL in your `.env` file (recommended):
```bash
# In .env
MANAGED_REPO_URL=https://github.com/your-org/pi-skills-extensions
MANAGED_REPO_REF=v1.0.0
```

Then just run:
```bash
make build
```

Or pass it directly on the command line:
```bash
make build MANAGED_REPO_URL=https://github.com/your-org/pi-skills-extensions
```

If `MANAGED_REPO_URL` is not set (neither in `.env` nor on the command line),
the build proceeds as before with no managed content.

**Note:** Skills/extensions are cloned fresh on every `make build`.
Local changes to `.pi-data/agent/skills/` or `.pi-data/agent/extensions/`
will be overwritten. For dynamic installs at runtime without a rebuild,
use `pi install git:github.com/your-org/pi-skills-extensions` inside the container.

## 🧠 LLM Wiki (opt-in, shared KB)

An optional, **shared** knowledge base built with
[`@zosmaai/pi-llm-wiki`](https://pi.dev/packages/@zosmaai/pi-llm-wiki) — the
Karpathy "LLM wiki" pattern: immutable source capture, automated ingestion,
search, linting, and an Obsidian-compatible vault.

It is **off by default**. Plain `pictl` / `make run` are unchanged. Enable it
for a single session with `pictl -w` (or `make run WIKI=true ...`). The package
is loaded for that run only via `pi -e`, so nothing is written to
`settings.json` and seeding/syncing other instances is unaffected.

### One-time setup (host, needs network)

```bash
make wiki-setup
```

This vendors the pinned package into `vendor/pi-llm-wiki` and creates the shared
vault root. Re-running is a no-op; bump `LLM_WIKI_VERSION` in `.env` to upgrade.
The step also applies a small, idempotent patch to one upstream prompt file
(`prompts/wiki-run.md`) whose frontmatter is invalid YAML — without it,
`/wiki-run` fails to load. You may see a `Patched prompts/wiki-run.md` line.

### Use

```bash
pictl -w ~/code/project-a      # this session has the wiki
pictl ~/code/project-b         # no wiki (unchanged)

# equivalent:
make run WIKI=true WORK_DIR=~/code/project-a
```

Inside the session: `/wiki-init "AI Engineering"`, then capture/ingest/query.
Project A, project B, etc. all use the **same** vault, so knowledge accumulates
across workspaces.

| Setting | Default | Meaning |
|---|---|---|
| `LLM_WIKI_DIR` | `$HOME/pi-llm-wiki` | Host dir; the vault is `<dir>/.llm-wiki/` |
| `LLM_WIKI_VERSION` | `0.12.2` | Pinned package version (keep in step with the image's `pi`) |

- Vault on the host: `~/pi-llm-wiki/.llm-wiki/`
- Vault in the container: `/home/node/llm-wiki/.llm-wiki/`
- If a workspace already contains its own `.llm-wiki/`, that **project vault
  wins** over the shared one. To keep one common KB, don't `/wiki-init` inside a
  workspace.

  > **Symptom: Obsidian shows an empty vault, or the agent seems to ignore the
  > shared KB.** A stray `<workspace>/.llm-wiki/` is shadowing the shared vault:
  > the agent's knowledge is landing in the project vault, which Syncthing does
  > not share. Fix: stop the session, delete the stray `<workspace>/.llm-wiki/`,
  > and restart with `pictl -w`. The shared vault at `~/pi-llm-wiki/.llm-wiki/`
  > is the only one that reaches the Mac. `.llm-wiki/` is gitignored so a
  > project vault can never be committed.

### Sync to a Mac and open in Obsidian

The host vault is plain markdown plus source artifacts, so any file sync works.
[Syncthing](https://syncthing.net) is the recommended LAN option (continuous,
peer-to-peer, no cloud):

1. **Host:** install Syncthing and share the vault folder itself,
   `~/pi-llm-wiki/.llm-wiki` (its contents are the whole vault).
2. **Mac:** install Syncthing, accept the share, and set the local folder path
   to a plain **local** folder such as `~/vaults/llm-wiki`. Keep it out of any
   cloud-synced area:
   - Obsidian's iCloud container:
     `~/Library/Mobile Documents/iCloud~md~obsidian/`.
   - `~/Documents` and `~/Desktop` when **iCloud → iCloud Drive → Desktop &
     Documents Folders** is on (they become iCloud-backed). Enable the folder
     only when Off:
     `ls -ld ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents 2>/dev/null`
     — if that path exists, Desktop & Documents is on, so do **not** use
     `~/Documents`.

   Never run Syncthing, Obsidian Sync, and iCloud on the same vault — they will
   fight.
3. **Mac (Syncthing UI):** add ignore patterns `.obsidian/` and `.DS_Store` so
   Obsidian's local config does not appear as un-synced local changes in the
   Receive Only folder.
4. **Obsidian (Mac):** *Open another vault → Open folder as vault*. The macOS
   folder picker is sandboxed and may not browse into every home folder, and
   Finder/Spotlight may not list a folder a sync daemon created. Press
   **Cmd+Shift+G** in the picker, paste the absolute path
   (`/Users/<you>/vaults/llm-wiki`), then Open. Obsidian remembers it after.

> Prefer a plain folder like `~/vaults/llm-wiki` over one named `~/Obsidian`,
> which is easy to confuse with Obsidian's app/iCloud folders. Finder *browsing*
> works once the vault is open; Finder *search* relies on Spotlight, which may
> not index a synced folder.

Optional `.stignore` in the shared folder (host side) to skip regenerable/heavy
indexes while keeping pages and sources:

```
meta/qmd/
```

Alternatives to Syncthing:

- **rsync (pull-only, run on the Mac):**
  `rsync -av --delete host:~/pi-llm-wiki/.llm-wiki/ ~/vaults/llm-wiki/`
- **git:** `git init` inside `.llm-wiki/`, push to a private remote, and use the
  Obsidian Git plugin on the Mac.

> The container host is the writer and the Mac is a reader. Edit on the Mac only
> while no container is running, or two-way sync can conflict.

The vault is created automatically the first time you run `pictl -w`. Do **not**
run `/wiki-init` in a workspace — that creates a project vault which shadows the
shared one. To set the topic, edit `~/pi-llm-wiki/.llm-wiki/config.json` or use
`/wiki-settings`.

`make wiki-setup` installs the package with `npm --ignore-scripts` to avoid a C
toolchain, so the optional native `@tobilu/qmd` indexing (semantic/embedding
features) is not built. Capture, ingest, keyword search, recall, and linting all
work without it.

## 🔒 Security model

This container keeps the agent away from **your host** — its files, its
privileges, its Docker daemon. It does **not** keep the agent away from its own
credentials, and it should not be described as if it did. The sections below
separate what the kernel enforces from what is only a speed bump. The full
threat model and the remediation backlog live in [SECURITY.md](SECURITY.md).

### 1. Guards that are enforced

* **Privilege and filesystem isolation come from Docker, not from scripts in
  this repo.** The container runs as your `HOST_UID` (`make` now refuses to run
  as `uid 0`), with `cap_drop: ALL`, `no-new-privileges`, a read-only root
  filesystem, `noexec` tmpfs for `/tmp`, `~/.config` and `~/.npm`, a
  `pids_limit`, and no Docker socket. Only the workspace and `.pi-data` are
  writable.
* **Binary purge:** `su`, `mount`, `passwd`, `login`, `unshare`, `nsenter`, …
  are deleted at build time and every remaining setuid/setgid bit is stripped
  (`chmod a-s`) — including `gh`, which is **no longer setuid**.
* **Git transport:** push/pull/fetch use SSH with one dedicated key mounted at
  `/home/node/.ssh/git_key`. The GitHub token is only used by `gh` for API
  calls, never for git transport.

### 2. `gh` guardrail (always on, no switch)

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

### 3. Credential handling — the honest version

* The GitHub token is a Docker secret mounted at `/run/secrets/gh_*` with mode
  `0444`: readable by the container user, which is the same user the agent runs
  as. Docker secrets keep it out of `docker inspect`, out of the image and out
  of `docker-compose.yml`; they do **not** put it out of the agent's reach.
* The wrapper passes the token to the `gh` child in the environment, so a
  same-UID process can read it from `/proc/<pid>/environ`.
* LLM provider keys live in `auth.json` (mode `0600`) in the data dir, and are
  copied into every per-project `.pi-data-*` directory by seeding/`make sync`.
  `.env` (which may hold the GitHub token) is tightened to `0600` by `make
  setup`.

### 4. Execution firewalls — speed bumps, not boundaries

`src/fs-vault.c` (an `LD_PRELOAD` shim, activated via `/etc/ld.so.preload`) and
`src/app-firewall.js` (a `NODE_OPTIONS=--require` shim) deny reads of
`auth.json`, `.secrets` and `/run/secrets/gh_*` from *casual* child processes
such as `cat`, `grep` or `python`. They are useful: they stop accident-prone
exploration and they keep the agent from stumbling into a key by reflex.

They are **not** a security boundary:

* `LD_PRELOAD` is user space, not kernel interception. Statically linked
  binaries (the image ships `gcc`), raw syscalls and `AT_SECURE` executables
  bypass it. `/workspace` is writable and executable, and `/tmp` being
  `noexec` does not prevent building a binary there.
* The shim's allowlist lets any process whose command line contains `pi` read
  `auth.json` — including pi's own `read` tool, which is the agent's primary
  way to read files.
* `NODE_OPTIONS` can be cleared (`env -u NODE_OPTIONS …`) or avoided by any
  non-Node tool, and `app-firewall.js` matches path substrings, so it also
  blocks harmless files (e.g. `.env.example`).

### 5. What this means for your data

A built-in extension (`src/redact-secrets.ts`, installed into the data dir by
`make setup`) strips common credential shapes — GitHub PATs and tokens,
`sk-` API keys, AWS access key IDs, `Bearer`/`Basic` authorization values and
PEM private-key blocks — from every tool result before it is persisted.

Two things are **not** covered: a secret the agent types inline in a command is
still recorded as that command's input (redacting it there would change what
executes), and nothing here filters network egress, so a secret already in the
agent's hands can still leave the container. Treat `.pi-data*` as
secret-bearing: restrict its permissions, exclude it from unencrypted backups,
prune it, and rotate any credential that has already appeared in an old
session. Both gaps are tracked in [SECURITY.md](SECURITY.md) (A1 residual, B5).

### 6. Outbound egress allowlist (opt-in)

Run with `EGRESS=true` (or set it in `.env`) to put the agent on an
`internal: true` Docker network whose only route out is a sidecar proxy
(`src/egress-proxy.js`). The proxy forwards **only** to hosts in
`EGRESS_ALLOWLIST` (comma-separated `host[:port]`, `*.host` matches
subdomains); every other host gets a 403 and the connection is dropped. LLM
requests ride `HTTPS_PROXY`, and SSH git is tunneled through the same CONNECT
proxy with netcat, so `github.com:22` must remain in the list for push/pull.

```bash
make run EGRESS=true
make run EGRESS=true EGRESS_ALLOWLIST=api.deepseek.com,github.com,github.com:22,registry.npmjs.org
```

This is the control that actually contains credential exfiltration: even if the
agent reads a secret, it cannot send it to a host that is not on the list. It
is **off by default** and, unlike the rest of this file, has not been exercised
against a live Docker daemon in this development environment — enable it,
confirm the agent still reaches your model provider and `git push` works, then
leave it on.
