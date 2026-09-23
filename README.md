# pi coding agent (dockerized)

Almost secure, containerized environment for running the [pi coding agent](https://github.com/badlogic/pi-mono). Designed for local execution with strict file-system isolation, privilege drop, and persistent storage.

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
pictl -d -a "fix the tests"   # one-off prompt, in the background
```

The launcher finds this project through its own symlink, so no paths are
hardcoded — it keeps working even if you move or rename the checkout. It
simply builds the same `make run`/`make run-args` command you would type
here, so every existing option (`.env`, `SSH_KEY`, `DETACHED`, ...) still
applies.

| Command | Meaning |
|---|---|
| `pictl [path]` | Workspace to mount; defaults to the **current directory** |
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
on the command line and a project identity is derived from the folder name:

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

See the [pi packages documentation](https://github.com/badlogic/pi-mono/blob/main/docs/packages.md) for details.

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

### Sync to a Mac and open in Obsidian

The host vault is plain markdown plus source artifacts, so any file sync works.
[Syncthing](https://syncthing.net) is the recommended LAN option (continuous,
peer-to-peer, no cloud):

1. **Host:** install Syncthing and share the vault folder itself,
   `~/pi-llm-wiki/.llm-wiki` (its contents are the whole vault).
2. **Mac:** install Syncthing, accept the share, and set the local folder path
   to e.g. `~/Obsidian/llm-wiki` (choose any non-hidden name).
3. **Obsidian (Mac):** *Open folder as vault* → select `~/Obsidian/llm-wiki`.
   No hidden-folder tricks needed.

Optional `.stignore` in the shared folder to skip regenerable/heavy indexes
while keeping pages and sources:

```
meta/qmd/
```

Alternatives to Syncthing:

- **rsync (pull-only, run on the Mac):**
  `rsync -av --delete host:~/pi-llm-wiki/.llm-wiki/ ~/Obsidian/llm-wiki/`
- **git:** `git init` inside `.llm-wiki/`, push to a private remote, and use the
  Obsidian Git plugin on the Mac.

> The container host is the writer and the Mac is a reader. Edit on the Mac only
> while no container is running, or two-way sync can conflict.

The vault is created automatically the first time you run `pictl -w`; use
`/wiki-init "<topic>"` inside the session to name it and lay out its pages.

`make wiki-setup` installs the package with `npm --ignore-scripts` to avoid a C
toolchain, so the optional native `@tobilu/qmd` indexing (semantic/embedding
features) is not built. Capture, ingest, keyword search, recall, and linting all
work without it.

## 🔒 Security Architecture & Paranoid Mode

This container implements a defense-in-depth architecture to sandbox the AI agent, ensuring it cannot leak credentials, modify its own access limits, or escalate privileges on your host machine.

### 1. Paranoid Mode (Active by Default)
The container uses a guardrail wrapper (`gh-guard.sh`) around the GitHub CLI. When `PARANOID_MODE=true` (set in `.env`), the agent is strictly blocked from executing dangerous repository or identity commands:
* **Blocked:** `gh auth`, `gh repo`, `gh secret`, `gh ssh-key`, `gh gpg-key`.
* This prevents a rogue agent from injecting a persistent backdoor key into your GitHub account.

### 2. Git Transport Isolation
Git transport to `github.com` runs over **SSH** using a single host key
(mounted read-only at `/home/node/.ssh/git_key`) instead of the HTTPS token.
Only that one key is exposed to the agent. The GitHub token remains isolated
and is only used by the `gh` CLI for API operations.

### 3. The Micro-Vault (Token Isolation, optional)
`GITHUB_TOKEN` is **optional** — it is only needed for `gh` API operations
(issues, PRs, releases, `gh api`). Git transport uses SSH and does not require
it. When configured, the token is **never** exposed in environment variables
where the agent can read it via `process.env`.
* The token is mapped as a Docker Secret into RAM (`tmpfs`) and locked to host permissions `000`.
* The container runs as a standard user (`UID 1000`).
* A custom C binary (`gh-vault`) uses SetUID to briefly elevate to root, read the token, pass it to the GitHub CLI, and immediately drop privileges. The agent natively receives `Permission Denied` if it attempts to read the file.

### 4. Dual Execution Firewalls
To prevent the agent from reading your Copilot `auth.json` or `.env` files, we implemented firewalls at both the OS and Application layers:
* **OS Syscall Firewall (`LD_PRELOAD`):** A custom C library (`fs-vault.so`) intercepts `open()` and `fopen()` syscalls at the Linux kernel level. If the agent spawns native child processes (like `cat`, `grep`, or `python`) to snoop on config directories, the kernel forces an `EACCES` permission error.
* **V8 Application Firewall:** A Node.js monkeypatch (`app-firewall.js`) intercepts the internal `fs` module. It analyzes the execution stack trace in real-time. If a file read/write request originates from the AI agent's tool directory, it throws a hard `[SYSTEM BLOCK]`. It only allows the core application (like the `/login` prompt) to touch credentials.

### 5. OS Binary Purge
During the Docker build phase, all native Linux privilege escalation vectors are physically deleted from the image:
* Removed: `su`, `mount`, `passwd`, `chsh`, `login`, `newgrp`, `unshare`, etc.
* The SetUID/SetGID execution bits are globally stripped (`chmod a-s`) from all remaining binaries on the filesystem.

### 6. Safe Persistence & Writable Space
* **UID/GID Mapping:** The `Makefile` dynamically passes your host User ID and Group ID into the container. Any files the agent writes to the mounted workspace (`WORK_DIR`, defaulting to `./workspace`) will be owned by your host user, preventing root permission lockouts.
* **Anti-Compilation:** Writable temporary directories (`/tmp`, `/.npm`, `/.config`) are mounted using `tmpfs` with the `noexec` flag. This prevents the agent from downloading and executing statically compiled binaries to bypass the `LD_PRELOAD` firewall.
