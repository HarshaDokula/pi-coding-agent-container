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
cleanup() {
  rm -rf "$ROOT"
  rm -rf "$SCRATCH/$TAG-alpha" "$SCRATCH/$TAG-beta" "$SCRATCH/$TAG-gamma" \
         "$SCRATCH/$TAG-lib"
}
trap cleanup EXIT

# --- make with multiple workspaces -----------------------------------------
MAKE_MULTI="$(make -n run WORK_DIR="$ALPHA $BETA" 2>/dev/null)"
has   "WORK_DIR=$SCRATCH" "$MAKE_MULTI" "make multi: /workspace root is the scratch dir"
has   "-v \"$ALPHA:/workspace/$TAG-alpha\"" "$MAKE_MULTI" "make multi: first dir at /workspace/<name>"
has   "-v \"$BETA:/workspace/$TAG-beta\""   "$MAKE_MULTI" "make multi: second dir at /workspace/<name>"
has   ".pi-data-pi-agent-$TAG-alpha"         "$MAKE_MULTI" "make multi: project identity derived from first dir"
if [[ -d "$SCRATCH/$TAG-beta" ]]; then
  ok "make multi: mount points pre-created in the scratch root"
else
  no "make multi: mount points pre-created in the scratch root"
fi

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
