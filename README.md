# pi coding agent (dockerized)

Almost secure, containerized environment for running the [pi coding agent](https://github.com/earendil-works/pi). Designed for local execution with strict file-system isolation, privilege drop, and persistent storage.

**Start here:** [USAGE.md](USAGE.md) is the hands-on walkthrough (install → run →
network modes → credentials → troubleshooting). This file is the feature
reference; [SECURITY.md](SECURITY.md) is the threat model and remediation
tracker. `make help` prints the short version.

| Doc | Purpose |
|---|---|
| [USAGE.md](USAGE.md) | start here: install, run, network modes, credentials, troubleshooting |
| README.md (this file) | feature reference for every component and option |
| [SECURITY.md](SECURITY.md) | threat model, controls, residuals, and remediation tracker |

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
| `pictl wiki` | The shared LLM Wiki KB with **no project** mounted |
| `pictl -r`, `--research` | Allow arbitrary public web for this session (egress research mode) |
| `pictl --no-egress` | Disable the egress proxy for this session (unfiltered network) |
| `pictl -b` | Run in a detached tmux session (survives logout / SSH drops) |
| `pictl --bootstrap` | Run `mise install` for the project's declared toolchain first |
| `pictl --shared-toolchains` | Share one toolchain cache across projects (opt-in) |
| `pictl ls` | List background sessions and the workspace each is on |
| `pictl attach [name]` | Reattach to a background session |
| `pictl stop [name]` | Stop a background session (its container exits with it) |
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

The derived name comes from the **basename only**, so two directories with the
same name (`~/work/app` and `~/side/app`) both become `pi-agent-app` and would
share a data dir and network. Give them explicit names in that case:

```bash
make run PROJECT_NAME=app-work WORK_DIR=~/work/app
make run PROJECT_NAME=app-side WORK_DIR=~/side/app
pictl -p app-work ~/work/app          # same thing via the launcher
```

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

`docker compose run --rm` removes the agent container but not what it started:
its `egress` sidecar keeps running and stays attached to the project's
`*_pi_network`, so that `/24` (and the `*_pi_egress_upstream` bridge) is never
reclaimed on its own. `make net-clean` (or `pictl net-clean`) reaps egress
sidecars whose session has ended, then removes the now-unused bridges. It is
safe at any time — anything belonging to a live session is kept — so run it
whenever you finish for the day, not after every session.

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

**Setting keys**

The three routes and the precedence order live in [USAGE §1a](USAGE.md):
`make set-key SET_KEY_ARGS="…"` keeps the key outside the data dirs (or uses
`--ephemeral` to keep only a reference), while `/login` remains the plaintext
fallback. The sections below are verification, audit, and rotation.

**Verifying Keys**

Pi stores API keys without validating them, so a revoked key still looks
like "logged in" and only fails on the first request. Check before you
blame the model:

```bash
make check-keys                          # probe every provider in .pi-data
make check-keys CHECK_KEYS_ARGS="--provider deepseek"
make check-keys PI_DATA_DIR=.pi-data-pi-agent-myproject
```

Each known provider gets one cheap read-only call; keys are never printed,
only a masked fingerprint and the HTTP status. Exit code 1 means a key is
dead. Run it on the host — inside the container the fs-vault shim blocks
the credential file by design.

**Which key is each instance using?**

Each per-project instance can keep its own `auth.json` (seeded once from
`.pi-data`). When present, that file beats the `models.json` secret — so after a
key rotation some projects keep failing while others work:

```bash
make keys-audit                          # per-instance provider + source, masked
make keys-audit PROVIDER=deepseek
make keys-prune PROVIDER=deepseek        # dry run: what would be removed
make keys-prune PROVIDER=deepseek APPLY=1
pictl sync                               # push models.json/settings to instances
```

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
# Diagnose "why is it not working": docker, image tools, secrets, keys, egress
make doctor

# Verify the provider keys still work (run on the host)
make check-keys

# Refresh the pinned GitHub SSH host keys from GitHub's own metadata
make refresh-known-hosts

# Run the shell + Node test suite
make test

# Vendor/refresh the opt-in LLM Wiki package (host, idempotent)
make wiki-setup

# Install/upgrade the pinned subagents package in this data dir (needs Docker)
make subagents-setup

# Access the container shell (runs as user 1000)
make shell

# Stop and remove running containers/networks
make clean

# Remove idle egress sidecars (they pin their project's subnet) and the unused
# *_pi_network / *_pi_egress_upstream bridges left behind by old runs. Safe while
# sessions are running: anything in use is kept.
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

> **Run with `EGRESS=false` when the model server is on the host.** The egress
> mode puts the container on an `internal: true` network with no route to the
> host, so a llama.cpp/Ollama/LM Studio server listening on the host is
> unreachable even though the URL says `127.0.0.1`. Either disable the proxy for
> that session (`pictl --no-egress`) or run the server in a container on the same
> network. A server *inside* the agent container keeps working with egress on,
> because `127.0.0.1` is in `NO_PROXY`.

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

### Use without a project

The vault does not belong to any workspace, so the KB can be used on its own —
no checkout mounted, no project data dir touched:

```bash
pictl wiki                     # the wiki, no project attached
pictl wiki -b                  # ... in the background (pictl attach wiki)
make run WIKI_ONLY=true        # the same from the Makefile

# spelled out:
pictl -w --no-workspace
```

The container still needs something at `/workspace`, so this pins it to a
dedicated **empty scratch dir**, `LLM_WIKI_SESSION_DIR` (default `~/pi-wiki`).
It is not a project: nothing from it reaches the vault, and every `pictl wiki`
run shares one instance (`.pi-data-pi-agent-wiki`, override with
`PROJECT_NAME=`), so `/resume` carries the same history from session to session.
Everything worth keeping lives in the shared vault.

A path contradicts "no project", so both of these are refused rather than
silently ignored:

```bash
pictl wiki ~/code/x            # error: use `pictl -w ~/code/x` instead
make run WIKI_ONLY=true WORK_DIR=~/code/x   # error
```

| Setting | Default | Meaning |
|---|---|---|
| `LLM_WIKI_DIR` | `$HOME/pi-llm-wiki` | Host dir; the vault is `<dir>/.llm-wiki/` |
| `LLM_WIKI_SESSION_DIR` | `$HOME/pi-wiki` | Empty dir mounted at `/workspace` for `pictl wiki` |
| `LLM_WIKI_VERSION` | `0.12.2` | Pinned package version (keep in step with the image's `pi`) |
| `WIKI_ONLY` | off | `pictl wiki` / `make run WIKI_ONLY=true`: wiki, no project |

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

The vault is created automatically the first time you run `pictl -w` or
`pictl wiki`. Do **not** run `/wiki-init` in a workspace — that creates a
project vault which shadows the shared one. To set the topic, edit
`~/pi-llm-wiki/.llm-wiki/config.json` or use `/wiki-settings`.

`make wiki-setup` installs the package with `npm --ignore-scripts` to avoid a C
toolchain, so the optional native `@tobilu/qmd` indexing (semantic/embedding
features) is not built. Capture, ingest, keyword search, recall, and linting all
work without it.

## Per-project toolchains (mise)

The image ships one Node and one Python. Projects rarely agree on versions, so
rather than baking every language in (or building an image per project), a
project declares what it needs and `mise` installs exactly that.

```toml
# <project>/mise.toml
[tools]
node = "22.11"
python = "3.12"
uv = "latest"
```

```bash
pictl --bootstrap ~/code/project-a   # mise install, then pi starts
# or inside a session:
mise install && mise use node@20
```

### What actually happens, and when

| Moment | What happens |
|---|---|
| `make build` / `make update` | **Only mise itself** is downloaded (pinned version + SHA-256 verified). No node/python/etc. |
| First `pictl --bootstrap` on a project with a manifest | The entrypoint runs `mise install` per manifest directory, downloads the declared versions into the toolchain volume (~200-400 MB for a node+python stack), refreshes shims, then starts pi. |
| Every later run of that project | `mise install` runs again but is a **no-op**: versions are already in the volume. Nothing is downloaded. |
| Container rebuild (`make update`) | The volume is untouched → no re-download. |
| A **different** project directory | Its own instance and its **own** toolchain volume → installs again. This is the safe default; see below. |
| `docker compose down` / `make clean` | Volume survives (no `-v`). |
| `docker volume rm pi-agent-<name>_pi_toolchains` | Cache gone; the next bootstrap re-downloads. |
| No `--bootstrap` and no manifest | Nothing happens. `mise` is available; run `mise install` yourself when you want. |

Set `MISE_BOOTSTRAP=1` in `.env` to bootstrap automatically on every run (still
a no-op once installed). A failed install prints a warning and still starts the
session — retry from inside with `mise -C <dir> install`.

Manifests are picked up at the workspace root **and one level down**, so a
multi-directory run (`pictl ~/a ~/b`) bootstraps each project.

### Where the tools live

`/home/node/.mise` — a **named Docker volume**, mounted writable while the rest
of the root filesystem stays read-only. `/home/node/.mise/shims` is first on
`PATH`, so `node`/`python` resolve to the version your current directory
declares.

Compose prefixes volume names with the project name, so by default each instance
has its own (`pi-agent-<name>_pi_toolchains`) — **per instance, not shared**.

**Sharing one cache across projects** (fewer downloads, weaker isolation — the
volume is writable and first on `PATH`, so a project you do not trust could
shadow `git`/`node` for the others):

```bash
pictl --shared-toolchains ~/code/app     # or: make run SHARED_TOOLCHAINS=1
```

that mounts one volume named `pi_toolchains` for every project.

Supported out of the box: anything mise's registry knows (node, python, go, rust,
java, ruby, terraform, …). Egress already allows `mise.jdx.dev`, `nodejs.org`,
`github.com`, `pypi.org`, `astral.sh`; add a host with `EGRESS_ALLOWLIST` if a
tool needs one.

**Not** done on purpose: per-language images. A variant matrix multiplies build
time and attack surface; a version manager keeps one image and moves the choice
into the repo. Heavy outliers (Android SDK, CUDA) still fit the overlay pattern:
`docker-compose.<stack>.yml` + `PI_IMAGE=…`.

## Subagents

[`@tintinweb/pi-subagents`](https://pi.dev/packages/@tintinweb/pi-subagents) adds
Claude Code-style delegation: the `Agent` tool (foreground or background),
`SubagentWorkflow` (deterministic fan-out scripts), `get_subagent_result`,
`steer_subagent`, and the `/agents` fleet UI.

It is a **declared pi package**, not a per-run `-e` load: installing it writes a
`settings.json` entry plus `agent/npm/` in the data dir, so every later run of
that instance has it and instances that never opted in stay lean.

```bash
make subagents-setup                       # one-time, per data dir (needs network)
make subagents-setup PROJECT_NAME=agent1   # a specific instance
make subagents-setup SUBAGENTS_VERSION=0.23.0
```

The install runs `pi install` inside a throwaway container from this image, so
npm resolves against the pinned pi (`PI_VERSION`). Idempotent; a version bump
drops the previous declaration first.

### When to delegate (and when not to)

Each subagent is a **separate pi process with its own context window**. You get
isolation and parallelism, not free speed: tokens are spent per child, memory is
~200-400 MB each (against `pids_limit: 150`), and nothing is shared except what
you merge back.

| Use a subagent when | Keep it in the main agent when |
|---|---|
| 3+ **independent** units with a merge step ("summarise these 6 modules") | steps depend on each other (plan → implement → verify) |
| the work would **blow the main context** (repo-wide research, long sweeps) | it is a one-file edit |
| you want **parallel review** from different angles | you need the reasoning visible turn by turn |
| a job is **long-running** and you want to keep working meanwhile (`background`) | the task is exploratory and you are still deciding |

Rule of thumb: if you can write the job as *"N independent tasks + how to
combine them"*, delegate. If it reads as a sequence, don't.

### Where things live

- Custom agents: `<PI_DATA_DIR>/agent/agents/<name>.md` (inside the container
  that is `~/.pi/agent/agents/`) or `.pi/agents/<name>.md` in the workspace.
  Frontmatter picks the model, thinking level, and tool scope per agent.
- Subagents run **inside the same container**, so they inherit its egress
  allowlist, read-only root FS, secret redaction, and the same provider keys.
  Delegation widens what the orchestrator can reach (each child has its own
  `tools:`), which is why it stays opt-in.
- Child sessions are persisted like any other; remove the package with
  `pi remove npm:@tintinweb/pi-subagents`.

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
  `pids_limit`, and no Docker socket. Only the workspace, `.pi-data`, and the
  per-instance toolchain volume are writable; `/tmp`, `~/.config`, and `~/.npm`
  are `noexec` tmpfs, and the rest of the root filesystem is read-only.
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
* LLM provider keys have three storage levels (USAGE §1a): plaintext
  `auth.json` (mode `0600`) in the data dir, one `.secrets/llm_key` file
  (`0400`) referenced from `models.json`, or a reference-only `PI_KEY_SOURCE`
  materialised into tmpfs per run. Seeding/`make sync` copy `auth.json` and the
  `models.json` reference; the default secret route keeps the key itself out of
  the data dirs. `.env` (which may hold the GitHub token or a key reference) is
  tightened to `0600` by `make setup`.

### 4. Execution firewalls — speed bumps, not boundaries

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

### 5. What this means for your data

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
[SECURITY.md](SECURITY.md) (A1, B5).

### 6. Outbound egress control

The agent runs arbitrary code and can read its own provider keys, so its
outbound network is controlled. `pi_network` is an `internal: true` Docker
network and the `egress` sidecar (`src/egress-proxy.js`, loaded from
[`docker-compose.egress.yml`](docker-compose.egress.yml)) is the only route
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
