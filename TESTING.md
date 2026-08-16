# Testing the pi coding agent container

This guide covers what a plain `make run` does today and how to verify every
feature that has been built so far: SSH git transport, single-key isolation,
optional GitHub token, multiple instances, and detached mode.

---

## 1. What `make run` does now (no flags)

```text
make run
  └─ setup
  │    mkdir -p .pi-data .secrets workspace src
  │    write .secrets/github_token.txt  (token from .env, or the "unset" placeholder)
  │    warn if SSH_KEY does not exist
  └─ docker compose run --rm pi-agent
```

| Aspect | Value |
|---|---|
| Mode | **Foreground**, interactive TUI |
| Lifecycle | **Ephemeral** — removed automatically on exit (`--rm`) |
| Workspace | `WORK_DIR` (default `./workspace`) → `/workspace` |
| Agent state | `PI_DATA_DIR` (default `.pi-data`) → `/home/node/.pi` |
| SSH key | `SSH_KEY` (default `~/.ssh/pi_agent_ed25519`) → `/home/node/.ssh/git_key` (read-only) |
| Token secret | `.secrets/github_token.txt` → `/run/secrets/gh_<random>` (or `unset` placeholder) |
| User | Runs as your host `uid:gid` |
| Rootfs | `read_only: true`, with tmpfs for `/tmp`, `~/.config`, `~/.npm` |
| Container name | Auto-generated (no fixed `container_name`), so multiple instances can run |

A plain `make run` does **not** build the image. Build first:

```bash
make build        # or: make update  (no-cache rebuild)
```

---

## 2. Prerequisites

1. Docker + Docker Compose are installed and the daemon is running.
2. Build the image once: `make build`.
3. Create a dedicated SSH key and add it to GitHub:

```bash
make ssh-key
# prints the public key → add it at https://github.com/settings/ssh/new
```

4. (Optional) If you also want `gh` API access, set `GITHUB_TOKEN` in `.env`.
   Git itself never needs the token.

---

## 3. Test matrix

### 3.1 Dry-run validation (no Docker needed)

These print the exact commands without executing anything:

```bash
make -n run
make -n run DETACHED=true PROJECT_NAME=agent1
make -n run-args DETACHED=true args="'create a file hello.txt'"
make -n ssh-key
make -n build PROJECT_NAME=agent1
```

Expected: the `docker compose run` lines include `--rm` (foreground) or
`-d --rm` (when `DETACHED=true`), and the right `SSH_KEY` / `PI_DATA_DIR`.

---

### 3.2 Build

```bash
make build
```

Expected: the image builds successfully, installs `openssh-client`, seeds the
GitHub host key, and pins the git SSH command.

---

### 3.3 `make ssh-key` helper

```bash
make ssh-key
```

Expected:
- Generates `~/.ssh/pi_agent_ed25519` (default path).
- Prints the public key.
- Running it again prints "already exists" instead of overwriting.

---

### 3.4 Basic run (foreground TUI)

```bash
make run
```

Expected: the interactive pi TUI starts, bound to `./workspace`. Ctrl-C/quit
stops it, and the container is removed (check with `docker ps -a`).

---

### 3.5 Git over SSH

Open a shell inside the container:

```bash
make shell
```

Then, inside the container:

```bash
# 1. Verify the URL rewrite is active
git config --system --list | grep -E 'url\.|sshcommand'
#   url.git@github.com:.insteadof=https://github.com/
#   core.sshcommand=ssh -i /home/node/.ssh/git_key -o IdentitiesOnly=yes

# 2. Verify the key authenticates directly
ssh -T -i /home/node/.ssh/git_key -o IdentitiesOnly=yes git@github.com
#   -> "Hi <your-user>! You've successfully authenticated..."

# 3. Verify git works over SSH (use any repo your account can access)
git ls-remote git@github.com:YOUR_ORG/YOUR_REPO.git
#   -> lists refs

# 4. Verify an HTTPS remote is transparently rewritten to SSH
git ls-remote https://github.com/YOUR_ORG/YOUR_REPO.git
#   -> also lists refs (same result as #3)
```

Expected: all four succeed without prompting for a password/token.

---

### 3.6 SSH key isolation (only one key exposed)

Inside `make shell`:

```bash
ls -la /home/node/.ssh
```

Expected: only `git_key` is present — no `id_ed25519`, no `config`, no
`known_hosts`, no other keys. The whole `~/.ssh` is **not** mounted.

---

### 3.7 Optional GitHub token

**Without a token** (comment out `GITHUB_TOKEN` in `.env`):

```bash
make shell
gh api user
```

Expected: fails fast with
`[SYSTEM BLOCK] No GitHub token configured. Set GITHUB_TOKEN in .env to enable gh API operations...`

**With a token** (set `GITHUB_TOKEN` in `.env`):

```bash
make shell
gh api user
```

Expected: returns your GitHub user JSON.

---

### 3.8 Multiple instances at the same time

Use two terminals:

```bash
# terminal 1
make run PROJECT_NAME=agent1 WORK_DIR=/path/to/project-a

# terminal 2
make run PROJECT_NAME=agent2 WORK_DIR=/path/to/project-b
```

In a third terminal:

```bash
docker ps                       # expect two pi-agent containers
ls -d .pi-data-agent1 .pi-data-agent2   # expect both data dirs
```

Expected: both run concurrently; each has its own network/name and its own
agent state. (Without `PROJECT_NAME`, `docker compose run` also generates
unique container names, but `PROJECT_NAME` gives full isolation.)

---

### 3.9 Detached mode

```bash
make run-args DETACHED=true args="'create a file hello.txt containing hi in the workspace'"
```

Expected:
- Prints a container ID and returns to your shell immediately.
- `docker ps` shows the container running.
- `docker logs <container-id>` shows the agent's output.
- The container auto-removes when it exits (same `--rm` behavior).

Also verify the flag is off by default:

```bash
make run          # still foreground/interactive
```

---

### 3.10 Cleanup

```bash
make clean                    # docker compose down (removes network/containers)
docker ps -a                  # confirm nothing left behind
```

For a specific project: `make clean PROJECT_NAME=agent1`.

---

## 4. Quick checklist

- [ ] `make build` succeeds
- [ ] `make ssh-key` creates the dedicated key
- [ ] `make run` starts the foreground TUI
- [ ] `git ls-remote git@github.com:...` works inside `make shell`
- [ ] `git ls-remote https://github.com/...` also works (rewrite active)
- [ ] `/home/node/.ssh` contains only `git_key`
- [ ] `gh api user` without a token fails with a clear message
- [ ] `gh api user` with a token returns user info
- [ ] Two `PROJECT_NAME` instances run at once
- [ ] `DETACHED=true` runs in the background and `docker logs` works
