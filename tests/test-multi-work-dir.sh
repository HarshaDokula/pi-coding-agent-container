#!/usr/bin/env bash
#
# Tests for mounting multiple workspaces: `make run WORK_DIR="a b"` and
# `pictl a b`. With one directory it is /workspace; with several, each is
# mounted side by side at /workspace/<basename>.
#
# No Docker or network required - everything is observed with `make -n` and
# `pictl --dry-run`.
#
# Run from anywhere: bash tests/test-multi-work-dir.sh

set -u

# These assertions drive `make`; skip cleanly where make is not installed
# (e.g. running the tests inside the container instead of on the host).
command -v make >/dev/null 2>&1 || { echo "SKIP  make not installed — run this suite on the host"; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Isolate from the parent Makefile's exported instance config, which would
# otherwise shadow the values derived here from WORK_DIR.
unset PI_DATA_DIR PROJECT_NAME COMPOSE_PROJECT_NAME

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

ROOT="$(mktemp -d)"
# Unique basenames so the repo-local mount points this test creates cannot
# collide with anything else, and can be cleaned up safely.
TAG="pi-mwtest-$$"
ALPHA="$ROOT/$TAG-alpha"
BETA="$ROOT/$TAG-beta"
GAMMA="$ROOT/$TAG-gamma"
mkdir -p "$ALPHA" "$BETA" "$GAMMA"
# Resolve the same way the Makefile/pictl do, so grep comparisons match.
ALPHA="$(cd "$ALPHA" && pwd)"
BETA="$(cd "$BETA" && pwd)"
GAMMA="$(cd "$GAMMA" && pwd)"
SCRATCH="$REPO_ROOT/.pi-workspace"
# The mount-point sync prunes nothing while running inside a container (no
# Docker CLI to prove a mount point is unused). The assertions below are about
# the pruning itself, so force it on and test the container default separately.
export PI_MOUNT_SYNC_FORCE=1
cleanup() {
  rm -rf "$ROOT"
  rm -rf "$SCRATCH/$TAG-"*
}
trap cleanup EXIT

# --- make with multiple workspaces -----------------------------------------
MAKE_MULTI="$(make -n run WORK_DIR="$ALPHA $BETA" 2>/dev/null)"
has   "WORK_DIR=$SCRATCH" "$MAKE_MULTI" "make multi: /workspace root is the scratch dir"
has   "-v \"$ALPHA:/workspace/$TAG-alpha\"" "$MAKE_MULTI" "make multi: first dir at /workspace/<name>"
has   "-v \"$BETA:/workspace/$TAG-beta\""   "$MAKE_MULTI" "make multi: second dir at /workspace/<name>"
has   ".pi-data-pi-agent-$TAG-alpha"         "$MAKE_MULTI" "make multi: project identity derived from first dir"
has   "sync-workspace-mounts.sh" "$MAKE_MULTI" \
      "make multi: mount points are prepared when the run starts, not at parse time"
mkdir -p "$SCRATCH/$TAG-parse-stale"
make -n run WORK_DIR="$ALPHA $BETA" >/dev/null 2>&1
[[ -d "$SCRATCH/$TAG-parse-stale" ]] \
  && ok "make -n: does not prune mount points at parse time" \
  || no "make -n: does not prune mount points at parse time"
rm -rf "$SCRATCH/$TAG-parse-stale"

MAKE_THREE="$(make -n run WORK_DIR="$ALPHA $BETA $GAMMA" 2>/dev/null)"
has   "-v \"$BETA:/workspace/$TAG-beta\""   "$MAKE_THREE" "make three: second dir mounted"
has   "-v \"$GAMMA:/workspace/$TAG-gamma\"" "$MAKE_THREE" "make three: third dir mounted"

# --- single workspace stays backward compatible ----------------------------
MAKE_SINGLE="$(make -n run WORK_DIR="$ALPHA" 2>/dev/null)"
has   "WORK_DIR=$ALPHA" "$MAKE_SINGLE" "make single: workspace root is the dir itself"
hasnt "-v \""           "$MAKE_SINGLE" "make single: no extra -v mounts"
hasnt "-w \""           "$MAKE_SINGLE" "make single: no -w override"

# --- shell target also gets the extra mounts -------------------------------
MAKE_SHELL="$(make -n shell WORK_DIR="$ALPHA $BETA" 2>/dev/null)"
has   "-v \"$BETA:/workspace/$TAG-beta\"" "$MAKE_SHELL" "make shell: second dir mounted"

# --- pictl accepts multiple paths, space-separated -------------------------
PICTL_MULTI="$(bin/pictl --dry-run "$ALPHA" "$BETA" 2>/dev/null)"
has   "make run" "$PICTL_MULTI"   "pictl multi: runs the make target"
has   "$ALPHA"   "$PICTL_MULTI"   "pictl multi: passes first path"
has   "$BETA"    "$PICTL_MULTI"   "pictl multi: passes second path"

PICTL_SINGLE="$(bin/pictl --dry-run "$ALPHA" 2>/dev/null)"
has   "WORK_DIR=$ALPHA" "$PICTL_SINGLE" "pictl single: keeps the workspace"

# --- pictl rejects a missing workspace -------------------------------------
if bin/pictl --dry-run "$ROOT/does-not-exist" >/dev/null 2>&1; then
  no "pictl: missing workspace is rejected"
else
  ok "pictl: missing workspace is rejected"
fi

# --- pictl rejects colliding basenames -------------------------------------
mkdir -p "$ROOT/one/$TAG-lib" "$ROOT/two/$TAG-lib"
if bin/pictl --dry-run "$ALPHA" "$ROOT/one/$TAG-lib" "$ROOT/two/$TAG-lib" >/dev/null 2>&1; then
  no "pictl: colliding basenames are rejected"
else
  ok "pictl: colliding basenames are rejected"
fi

# --- make rejects colliding basenames --------------------------------------
if make -n run WORK_DIR="$ALPHA $ROOT/one/$TAG-lib $ROOT/two/$TAG-lib" >/dev/null 2>&1; then
  no "make: colliding basenames are rejected"
else
  ok "make: colliding basenames are rejected"
fi

# --- stale mount points from earlier runs are pruned -----------------------
# .pi-workspace is the /workspace root of every multi-directory run, so a
# directory left behind by a previous combo stayed visible in the container as a
# project that is not mounted - and accepted writes that missed the real
# project. Empty leftovers are now removed; anything holding files is kept.
SYNC="$REPO_ROOT/scripts/sync-workspace-mounts.sh"
SCRATCH_T="$ROOT/scratch"
mkdir -p "$SCRATCH_T/$TAG-keep" "$SCRATCH_T/$TAG-stale"
"$SYNC" "$SCRATCH_T" "$TAG-keep" >/dev/null 2>&1
[[ -d "$SCRATCH_T/$TAG-keep" ]] \
  && ok "sync: mount point for the current run is kept" \
  || no "sync: mount point for the current run is kept"
[[ ! -e "$SCRATCH_T/$TAG-stale" ]] \
  && ok "sync: empty leftover mount point is removed" \
  || no "sync: empty leftover mount point is removed"

"$SYNC" "$SCRATCH_T" "$TAG-keep" "$TAG-fresh" >/dev/null 2>&1
[[ -d "$SCRATCH_T/$TAG-fresh" ]] \
  && ok "sync: mount point for a new directory is created" \
  || no "sync: mount point for a new directory is created"

# Content is never deleted: it may be work an agent wrote into the wrong path.
mkdir -p "$SCRATCH_T/$TAG-full"
printf 'work\n' > "$SCRATCH_T/$TAG-full/file.txt"
SYNC_OUT="$(PI_MOUNT_SYNC_FORCE=1 "$SYNC" "$SCRATCH_T" "$TAG-keep" 2>&1)"
[[ -f "$SCRATCH_T/$TAG-full/file.txt" ]] \
  && ok "sync: leftover mount point holding files is left alone" \
  || no "sync: leftover mount point holding files is left alone"

# --check reports without touching anything (used by scripts/doctor.sh).
mkdir -p "$SCRATCH_T/$TAG-check"
CHECK_OUT="$(PI_MOUNT_SYNC_FORCE=1 "$SYNC" --check "$SCRATCH_T" 2>&1)"
[[ -d "$SCRATCH_T/$TAG-check" ]] \
  && ok "sync --check: reports without pruning" \
  || no "sync --check: reports without pruning"
has   "stale " "$CHECK_OUT" "sync --check: names the stale mount point"
has   "not-empty" "$CHECK_OUT" "sync --check: distinguishes leftovers holding files"

# A mount point a running container is using must never be pruned. The stub
# reports its container's mounts, so the leaf name under /workspace survives.
FAKE2="$ROOT/fakebin2"
mkdir -p "$FAKE2"
cat > "$FAKE2/docker" <<'STUB'
#!/bin/sh
case "$1" in
  ps)      echo abc123 ;;
  inspect) printf '/workspace/%s\n/run/secrets/llm_key\n' "$MOUNT_LEAF" ;;
  *)       exit 1 ;;
esac
STUB
chmod +x "$FAKE2/docker"
mkdir -p "$SCRATCH_T/$TAG-live"
PATH="$FAKE2:$PATH" MOUNT_LEAF="$TAG-live" "$SYNC" "$SCRATCH_T" "$TAG-keep" >/dev/null 2>&1
[[ -d "$SCRATCH_T/$TAG-live" ]] \
  && ok "sync: mount point of a running container is kept" \
  || no "sync: mount point of a running container is kept"

# A Docker CLI that exists but does not answer cannot rule out a live
# container, so prune nothing.
FAKEBIN="$ROOT/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/docker"
chmod +x "$FAKEBIN/docker"
mkdir -p "$SCRATCH_T/$TAG-noprune"
PATH="$FAKEBIN:$PATH" "$SYNC" "$SCRATCH_T" "$TAG-keep" >/dev/null 2>&1
[[ -d "$SCRATCH_T/$TAG-noprune" ]] \
  && ok "sync: prunes nothing when the docker daemon cannot be queried" \
  || no "sync: prunes nothing when the docker daemon cannot be queried"
rm -rf "$SCRATCH_T/$TAG-noprune"

# No Docker CLI at all is not proof that nothing is mounted: the container may
# have been started by another user/context. Fail closed and prune nothing.
if [[ ! -f /.dockerenv && ! -f /run/.containerenv ]]; then
  NODOCKER="$ROOT/nodocker"
  mkdir -p "$NODOCKER"
  for c in bash env stat basename ls mkdir rmdir cat printf; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$NODOCKER/$c"
  done
  mkdir -p "$SCRATCH_T/$TAG-nodocker"
  PATH="$NODOCKER" "$SYNC" "$SCRATCH_T" "$TAG-keep" >/dev/null 2>&1
  [[ -d "$SCRATCH_T/$TAG-nodocker" ]] \
    && ok "sync: prunes nothing when docker is not installed" \
    || no "sync: prunes nothing when docker is not installed"
  rm -rf "$SCRATCH_T/$TAG-nodocker"
fi

# Inside the container the sync declines by default (no Docker CLI to prove a
# mount point is unused), so `make doctor` there never mutates anything.
if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
  mkdir -p "$SCRATCH_T/$TAG-ctr"
  env -u PI_MOUNT_SYNC_FORCE "$SYNC" "$SCRATCH_T" "$TAG-keep" >/dev/null 2>&1
  [[ -d "$SCRATCH_T/$TAG-ctr" ]] \
    && ok "sync: inside a container, default run prunes nothing" \
    || no "sync: inside a container, default run prunes nothing"
fi

# A dry run must never mutate the scratch root: it used to prune at parse
# time, which could remove a mount point a running container was using.
mkdir -p "$SCRATCH/$TAG-make-stale"
make -n run WORK_DIR="$ALPHA $BETA" >/dev/null 2>&1
[[ -d "$SCRATCH/$TAG-make-stale" ]] \
  && ok "make -n: leftover mount point is not pruned" \
  || no "make -n: leftover mount point is not pruned"
rm -rf "$SCRATCH/$TAG-make-stale"

# The real target prunes on execution. Use a scratch root the test owns so it
# cannot touch the repo's live .pi-workspace.
mkdir -p "$SCRATCH_T/$TAG-make-stale"
make prepare-workspaces WORK_DIR="$ALPHA $BETA" WORK_DIR_ABS="$SCRATCH_T" >/dev/null 2>&1
[[ ! -e "$SCRATCH_T/$TAG-make-stale" ]] \
  && ok "make prepare-workspaces: leftover mount point pruned" \
  || no "make prepare-workspaces: leftover mount point pruned"
[[ -d "$SCRATCH_T/$TAG-alpha" && -d "$SCRATCH_T/$TAG-beta" ]] \
  && ok "make prepare-workspaces: current mount points present" \
  || no "make prepare-workspaces: current mount points present"

# Mounting over a directory that still holds work hides it. Refuse instead of
# warning: that is the difference between a visible error and a silent
# "I edited the wrong copy".
mkdir -p "$SCRATCH_T/$TAG-hold"
printf 'work\n' > "$SCRATCH_T/$TAG-hold/file.txt"
if PI_MOUNT_SYNC_FORCE=1 "$SYNC" "$SCRATCH_T" "$TAG-hold" >/dev/null 2>&1; then
  no "sync: refuses to mount over files"
else
  ok "sync: refuses to mount over files"
fi
[[ -f "$SCRATCH_T/$TAG-hold/file.txt" ]] \
  && ok "sync: leaves files at a refused mount point" \
  || no "sync: leaves files at a refused mount point"
rm -rf "$SCRATCH_T/$TAG-hold"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
