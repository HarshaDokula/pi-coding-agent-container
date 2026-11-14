#!/usr/bin/env bash
#
# Tests for per-project toolchains (mise): image wiring, compose volume,
# entrypoint bootstrap behaviour, and the pictl flag.
#
# Hermetic: the entrypoint runs against a temp workspace with stub mise/pi
# binaries on PATH; no Docker, no network.
#
# Run from anywhere: bash tests/test-toolchains.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if [[ "$2" == *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
hasnt() { if [[ "$2" != *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

DOCKERFILE="$(cat Dockerfile)"
COMPOSE="$(cat docker-compose.yml)"
ENTRYPOINT="$REPO_ROOT/src/entrypoint.sh"

# --- 1. image: mise is installed, pinned and verified ---------------------
has "MISE_VERSION=v" "$DOCKERFILE" "mise version is pinned"
has "MISE_SHA256_AMD64=" "$DOCKERFILE" "amd64 artifact checksum is pinned"
has "MISE_SHA256_ARM64=" "$DOCKERFILE" "arm64 artifact checksum is pinned"
has "sha256sum -c -" "$DOCKERFILE" "the mise tarball is checksum-verified"
has 'dpkg --print-architecture' "$DOCKERFILE" "the archive is chosen per architecture"
has '/tmp/mise-extract/mise/bin/mise' "$DOCKERFILE" "the binary is installed from the archive layout"
has "mise --version" "$DOCKERFILE" "the build smoke-tests the binary"
# Every line but the last in a continued RUN must end with a backslash; a
# missing one splits the instruction and Docker then rejects the next line
# (e.g. "unknown instruction: arm64)").
MISE_RUN=$(awk '/^ARG MISE_SHA256_ARM64=/{seen=1} seen && /^RUN /{run=1} run{print; if ($0 !~ /\\$/) exit}' Dockerfile)
has 'esac; \' "$MISE_RUN" "the mise RUN is one continued instruction"
has 'arm64) arch=arm64' "$MISE_RUN" "the arm64 case branch is inside the mise RUN"

# --- 2. image: mise state lives on the volume, not on the read-only root ---
has "MISE_DATA_DIR=/home/node/.mise" "$DOCKERFILE" "MISE_DATA_DIR points at the volume"
has "MISE_CONFIG_DIR=/home/node/.mise/config" "$DOCKERFILE" "MISE_CONFIG_DIR points at the volume"
has "MISE_CACHE_DIR=/home/node/.mise/cache" "$DOCKERFILE" "MISE_CACHE_DIR points at the volume"
has "MISE_STATE_DIR=/home/node/.mise/state" "$DOCKERFILE" "MISE_STATE_DIR points at the volume"
has "MISE_TRUSTED_CONFIG_PATHS=/workspace" "$DOCKERFILE" "workspace configs are trusted"
has "/home/node/.mise/shims" "$DOCKERFILE" "shims are on PATH"
has "/home/node/.mise" "$(sed -n '/chown -R node:node/,/\.mise/p' Dockerfile)" "the volume dirs are chowned to node"

# --- 3. compose: volume + bootstrap switch -------------------------------
has "pi_toolchains:/home/node/.mise" "$COMPOSE" "the toolchain volume is mounted"
has "pi_toolchains:" "$COMPOSE" "the volume is declared"
has "MISE_BOOTSTRAP=" "$COMPOSE" "compose forwards MISE_BOOTSTRAP"

# --- 4. entrypoint: bootstrap only when asked ---------------------------
# Stubs must be executable, and /tmp is noexec inside the container, so the
# scratch dir lives in the repo (removed on exit).
TMP="$(mktemp -d "$REPO_ROOT/.tmp-toolchains.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/ws"
printf '#!/bin/sh\necho "mise $*" >> "%s/calls"\n' "$TMP" > "$TMP/bin/mise"
printf '#!/bin/sh\necho "pi $*" >> "%s/calls"\n' "$TMP" > "$TMP/bin/pi"
chmod +x "$TMP/bin/mise" "$TMP/bin/pi"

run_entry() { # env vars from the caller
  PATH="$TMP/bin:$PATH" PI_WORKSPACE_DIR="$TMP/ws" "$ENTRYPOINT" "$@" 2>&1
}

# no bootstrap flag -> pi runs, mise never does
: > "$TMP/calls"
OUT="$(MISE_BOOTSTRAP=0 run_entry --version)"
has "pi --version" "$(cat "$TMP/calls")" "pi is started"
hasnt "mise" "$(cat "$TMP/calls")" "mise is not touched without the flag"

# bootstrap flag but no manifest -> pi still runs, warning printed
: > "$TMP/calls"
OUT="$(MISE_BOOTSTRAP=1 run_entry)"
has "pi " "$(cat "$TMP/calls")" "pi still starts without a manifest"
has "no mise.toml" "$OUT" "the missing manifest is reported"
hasnt "mise install" "$(cat "$TMP/calls")" "no install without a manifest"

# bootstrap flag + mise.toml -> mise install runs, then pi
: > "$TMP/calls"
printf '[tools]\nnode = "22"\n' > "$TMP/ws/mise.toml"
OUT="$(MISE_BOOTSTRAP=1 run_entry)"
has "install" "$(cat "$TMP/calls")" "mise install runs for mise.toml"
has "-C $TMP/ws" "$(cat "$TMP/calls")" "mise is pointed at the manifest directory"
has "reshim" "$(cat "$TMP/calls")" "shims are refreshed"
has "pi " "$(cat "$TMP/calls")" "pi starts after the bootstrap"
has "bootstrapping toolchains for" "$OUT" "the bootstrap is announced"

# a failing install warns but does not block the session
: > "$TMP/calls"
printf '#!/bin/sh\ncase "$*" in *" install"*) exit 1 ;; *) exit 0 ;; esac\nexit 0\n' > "$TMP/bin/mise"
chmod +x "$TMP/bin/mise"
OUT="$(MISE_BOOTSTRAP=1 run_entry)"
has "WARNING - mise install failed" "$OUT" "a failed install is reported loudly"
has "pi " "$(cat "$TMP/calls")" "a failed install does not block pi"

# .tool-versions works too
printf '#!/bin/sh\necho "mise $*" >> "%s/calls"\n' "$TMP" > "$TMP/bin/mise"
chmod +x "$TMP/bin/mise"
rm -f "$TMP/ws/mise.toml"; printf 'nodejs 22\n' > "$TMP/ws/.tool-versions"
: > "$TMP/calls"
MISE_BOOTSTRAP=1 run_entry >/dev/null 2>&1
has "install" "$(cat "$TMP/calls")" ".tool-versions triggers the bootstrap"

# --- 5. pictl flag ------------------------------------------------------
if command -v make >/dev/null 2>&1; then
    OUT="$("$REPO_ROOT/bin/pictl" --dry-run --bootstrap /tmp 2>&1)"
    has "MISE_BOOTSTRAP=1" "$OUT" "pictl --bootstrap sets MISE_BOOTSTRAP"
    OUT="$("$REPO_ROOT/bin/pictl" --dry-run /tmp 2>&1)"
    hasnt "MISE_BOOTSTRAP" "$OUT" "without the flag nothing is set"
    has "MISE_BOOTSTRAP" "$(make -n run 2>/dev/null; grep -o 'MISE_BOOTSTRAP' Makefile | head -1)" "make exposes MISE_BOOTSTRAP"
else
    echo "SKIP  pictl/make flag wiring (make is not installed here)"
fi

# --- 6. egress allows what mise needs ------------------------------------
# Force the built-in default: a custom EGRESS_ALLOWLIST in .env is the user's
# choice and must not make this assertion fail.
ALLOW="$(EGRESS_ALLOWLIST= make -s --eval='print: ; @echo $(EGRESS_ALLOWLIST)' print 2>/dev/null | tail -1)"
if [[ -n "$ALLOW" ]]; then
    for host in mise.jdx.dev nodejs.org github.com pypi.org; do
        has "$host" "$ALLOW" "egress allowlist covers $host"
    done
else
    echo "SKIP  allowlist contents (make is not installed here)"
fi

# --- 7. entrypoint is wired into the image ------------------------------
has 'COPY src/entrypoint.sh /usr/local/bin/pi-entrypoint' "$DOCKERFILE" "entrypoint is copied in"
has 'ENTRYPOINT ["/usr/local/bin/pi-entrypoint"]' "$DOCKERFILE" "entrypoint replaced"
has 'exec pi "$@"' "$(cat "$ENTRYPOINT")" "entrypoint hands over to pi"

# --- 8. subdirectory manifests (multi-dir runs) -------------------------
mkdir -p "$TMP/ws/app-a" "$TMP/ws/app-b"
printf '[tools]
node = "22"
' > "$TMP/ws/app-a/mise.toml"
printf 'python 3.12
' > "$TMP/ws/app-b/.tool-versions"
: > "$TMP/calls"
MISE_BOOTSTRAP=1 run_entry >/dev/null 2>&1
has "-C $TMP/ws/app-a" "$(cat "$TMP/calls")" "nested mise.toml is bootstrapped"
has "-C $TMP/ws/app-b" "$(cat "$TMP/calls")" "nested .tool-versions is bootstrapped"
rm -rf "$TMP/ws/app-a" "$TMP/ws/app-b"

# --- 9. the toolchain volume lifecycle is documented --------------------
TOOLCHAINS="$(cat "$REPO_ROOT/docs/toolchains.md")"
has "per instance" "$TOOLCHAINS" "toolchain guide states they are per instance"
has "docker volume rm" "$TOOLCHAINS" "toolchain guide explains how to reset the cache"
has "survive" "$TOOLCHAINS" "toolchain guide explains rebuild survival"
USAGE="$(cat "$REPO_ROOT/USAGE.md")"
has "pi_toolchains" "$USAGE" "USAGE names the volume"
has "bootstrap" "$USAGE" "USAGE documents bootstrap"
COMPOSE="$(cat "$REPO_ROOT/docker-compose.yml")"
hasnt "name: pi_toolchains" "$COMPOSE" "the volume is NOT globally named (per-instance by default)"
OVERLAY="$REPO_ROOT/docker-compose.shared-toolchains.yml"
[ -f "$OVERLAY" ] && ok "a shared-toolchains overlay exists" || no "a shared-toolchains overlay exists"
has "name: pi_toolchains" "$(cat "$OVERLAY" 2>/dev/null)" "the overlay names one shared volume"

echo
echo "toolchain tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
