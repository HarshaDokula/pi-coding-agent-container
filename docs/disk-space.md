# Disk space

Rebuilds are the main way this container grows on disk. Docker keeps the old
image after a rebuild (it becomes untagged, or "dangling"), and BuildKit keeps
build-cache records — including for `--no-cache` rebuilds. Docker does not prune
either automatically, so a small disk can fill up after a few updates.

## Reclaiming Docker space

```bash
make prune                  # dangling images + the whole BuildKit cache
make update                 # rebuild without cache, then run the prune above
make build                  # rebuild, then remove only dangling images
make update AUTO_PRUNE=0    # keep the build cache after an update
```

`make build` keeps the cache because it makes subsequent builds faster.
`make update` is already a no-cache rebuild, so it removes the cache too. Set
`AUTO_PRUNE=0` when the Docker daemon is shared with other projects that benefit
from its cache.

`make prune` never removes tagged images, containers, networks or volumes. It
does remove untagged images and cache daemon-wide, because Docker's build cache
is not scoped to this project.

Check what is using space before and after:

```bash
docker system df
docker image ls --filter dangling=true
docker builder du
```

Toolchain volumes (`pi_toolchains`) and agent data (`.pi-data*`) are retained on
purpose. Remove a toolchain volume only when you want to re-download its
versions:

```bash
docker volume ls | grep pi_toolchains
docker volume rm <volume-name>
```

Idle egress containers and unused project networks are separate from disk usage:

```bash
make net-clean
```

## Host caches outside Docker

Docker is not always the largest consumer. VS Code Remote keeps every server
version it has downloaded, and language tooling caches are often several GB.
Inspect first:

```bash
du -sh ~/.vscode-server ~/.cargo ~/.gradle ~/.npm 2>/dev/null
```

Safe cleanup (the tools re-download what they need):

```bash
# VS Code Remote: close all remote windows first
rm -rf ~/.vscode-server/cli/servers/* ~/.vscode-server/bin/*

# Rust
rm -rf ~/.cargo/registry/cache ~/.cargo/registry/src ~/.cargo/git/checkouts

# Gradle
rm -rf ~/.gradle/caches

# npm
npm cache clean --force
```

Old agent session transcripts also accumulate under
`.pi-data*/agent/sessions/*.jsonl`; prune them if you do not need old history:

```bash
find .pi-data* -path '*/agent/sessions/*.jsonl' -mtime +30 -delete
```

## If rebuilds are frequent

A 32/64 GB SD card leaves little headroom once the base image, build cache and
toolchain volumes are included. For frequent rebuilds, move Docker's data-root
to a larger disk or external SSD (the `data-root` setting in
`/etc/docker/daemon.json`), then restart Docker. Keep this checkout and the
bind-mounted workspaces on storage with enough free space for the image layers.

`make doctor` reports the free space on the filesystem that holds this checkout
and warns when it drops below 10%.
