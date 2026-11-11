# Per-project toolchains (mise)

> **Purpose:** Install the Node/Python/etc. versions a project declares, using a persistent mise cache.
>
> Back to [README](../README.md) · [documentation index](README.md).


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

## What actually happens, and when

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

## Where the tools live

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

## Related: the git version

A worktree is only usable inside a container when git understands relative
worktree paths, so the image builds git from source (`2.56.1`, at
`/usr/local/git`) rather than using the distro's `2.47.3`. See
[security model §7](security-model.md#7-git-is-built-from-source-and-pinned) for
the pinning details.
