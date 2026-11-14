# pi coding agent (dockerized)

Almost secure, containerized environment for running the [pi coding agent](https://github.com/earendil-works/pi). Designed for local execution with strict file-system isolation, privilege drop, and persistent storage.

**Platforms:** Linux and macOS (Docker Desktop) are supported directly. On
Windows, use **WSL2** with Docker Desktop's WSL integration; native PowerShell,
Git Bash, and MSYS2 are not supported. See [USAGE §1](USAGE.md).

**Start here:** [USAGE.md](USAGE.md) is the hands-on walkthrough (install → run →
network modes → credentials → troubleshooting). This file is the core feature
reference; detailed optional features live in [docs/](docs/README.md), and
[SECURITY.md](SECURITY.md) is the threat model and remediation tracker.
`make help` prints the short version.

| Doc | Purpose |
|---|---|
| [USAGE.md](USAGE.md) | start here: install, run, network modes, credentials, troubleshooting |
| README.md (this file) | core feature reference: launcher, workspaces, instances, keys, maintenance |
| [docs/](docs/README.md) | detailed guides for optional features |
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
> projects appear under it. Mount points are created, and empty leftovers from
> earlier combinations pruned, only when a run starts the container. `make
> help`, `make doctor`, and dry runs never touch them. The sync fails closed
> when it cannot ask Docker which mount points a container is using, and it
> refuses to start if one of the requested mount points still holds files
> (mounting would hide them).
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

# One check before trusting a change: test suite + shell/compose syntax +
# the built image's runtime contract (skips Docker checks when unavailable)
make verify

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

# Reclaim disk from rebuilds: dangling images + the BuildKit cache
make prune

# Upgrade pi to the latest release (pins it in .env), then rebuild without
# cache (also prunes old images/cache)
make update

# Rebuild at the currently pinned pi version (no pi lookup, no upgrade)
make build
```

---

## Feature guides

Detailed guides for the optional features live in [docs/](docs/README.md):

| Guide | Purpose |
|---|---|
| [Offline mode](docs/offline-mode.md) | local model server, no cloud provider |
| [Managed skills & extensions](docs/managed-skills.md) | build-time pi package repo |
| [LLM Wiki](docs/llm-wiki.md) | opt-in shared knowledge base and Obsidian sync |
| [Per-project toolchains](docs/toolchains.md) | mise-managed Node/Python/etc. versions |
| [Subagents](docs/subagents.md) | delegate work to child pi processes |
| [Security model](docs/security-model.md) | enforced guards, speed bumps, and residuals |
| [Disk space](docs/disk-space.md) | reclaim Docker images/cache and host tool caches |
