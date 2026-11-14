#!/usr/bin/env bash
#
# verify-image.sh — assert the built image still honours the container contract.
#
# This is the post-build check: it starts the image (no network, no volumes,
# no secrets) and confirms the things that have broken before:
#   - pi is the pinned version and the TUI self-update notice is disabled
#   - the runtime still has the tools the agent needs, and no compiler
#   - git >= 2.48, ssh-over-proxy config, fs-vault preload, entrypoint
#
# Usage: verify-image.sh [--allow-missing]
#
# --allow-missing exits 0 (with SKIP) when Docker or the image is absent, so
# `make verify` can run before the first build.
#
# Environment:
#   PI_IMAGE=name:tag   image to inspect (default local/pi-coding-agent:latest)
#   PI_DOCKER=path      docker binary (default: docker; tests can stub it)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PI_IMAGE:-local/pi-coding-agent:latest}"
DOCKER="${PI_DOCKER:-docker}"
allow_missing=0

usage() {
    cat <<'EOF'
usage: verify-image.sh [--allow-missing]

Start the built image and check the runtime contract (pi version/tools/ssh/
firewall/entrypoint). --allow-missing skips cleanly when Docker or the image
is not present.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-missing) allow_missing=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify-image: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

pass=0
fail=0
skip=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skipt(){ printf 'SKIP  %s\n' "$1"; skip=$((skip + 1)); }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

if ! command -v "$DOCKER" >/dev/null 2>&1; then
    if [[ "$allow_missing" -eq 1 ]]; then
        skipt "docker not found — run this on the Docker host after 'make build'"
        exit 0
    fi
    no "docker not found — install Docker or run with --allow-missing"
    exit 1
fi

if ! "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; then
    if [[ "$allow_missing" -eq 1 ]]; then
        skipt "image $IMAGE not built yet"
        exit 0
    fi
    no "image $IMAGE not built — run 'make build' or 'make update' first"
    exit 1
fi

PINNED="$(cd "$ROOT" && make -s --eval='print: ; @echo $(PI_VERSION)' print 2>/dev/null | tail -1)"
TOOLCHAIN="${PI_WITH_TOOLCHAIN:-}"
if [[ -z "$TOOLCHAIN" ]]; then
    TOOLCHAIN="$(cd "$ROOT" && grep -E '^[[:space:]]*PI_WITH_TOOLCHAIN=' .env 2>/dev/null | tail -1 | sed -E 's/^[[:space:]]*PI_WITH_TOOLCHAIN=//' || true)"
fi
case "${TOOLCHAIN:-0}" in 1|true|yes|on) want_compiler=1 ;; *) want_compiler=0 ;; esac

REPORT="$("$DOCKER" run --rm --network none --entrypoint /bin/sh "$IMAGE" -c '
    echo "version=$(pi --version 2>/dev/null | tr -d "\r\n")"
    echo "skip=${PI_SKIP_VERSION_CHECK:-}"
    echo "git=$(git --version 2>/dev/null)"
    for b in make git ssh nc gh node python3 curl wget; do
        command -v "$b" >/dev/null 2>&1 && echo "have=$b" || echo "missing=$b"
    done
    command -v gcc >/dev/null 2>&1 && echo "compiler=yes" || echo "compiler=no"
    grep -q "ProxyCommand /usr/local/bin/ssh-netcat-proxy" /etc/ssh/ssh_config.d/90-pi-egress.conf 2>/dev/null \
        && echo "ssh_proxy=yes" || echo "ssh_proxy=no"
    grep -q "fs-vault" /etc/ld.so.preload 2>/dev/null \
        && echo "fs_vault=yes" || echo "fs_vault=no"
    test -x /usr/local/bin/pi-entrypoint && echo "entrypoint=yes" || echo "entrypoint=no"
' 2>/dev/null)"

if [[ -z "$REPORT" ]]; then
    no "could not run the image (docker run produced no output)"
    printf '\nimage verify: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
    exit 1
fi

value() { printf '%s\n' "$REPORT" | sed -n "s/^$1=//p" | head -1; }

eq "$(value version)" "$PINNED" "image runs the pinned pi version"
eq "$(value skip)" "1" "image disables the pi self-update notice (PI_SKIP_VERSION_CHECK=1)"

missing="$(printf '%s\n' "$REPORT" | sed -n 's/^missing=//p' | tr '\n' ' ')"
if [[ -z "$missing" ]]; then
    ok "image has make git ssh nc gh node python3 curl wget"
else
    no "image is missing: ${missing% }"
fi

if [[ "$want_compiler" -eq 1 ]]; then
    eq "$(value compiler)" "yes" "compiler present because PI_WITH_TOOLCHAIN=1"
else
    eq "$(value compiler)" "no" "image has no compiler (PI_WITH_TOOLCHAIN=0)"
fi

GIT_VERSION="$(value git | sed -n 's/^git version //p')"
if [[ "$(printf '%s\n2.48\n' "$GIT_VERSION" | sort -V | head -1)" == "2.48" ]]; then
    ok "image git is >= 2.48 ($GIT_VERSION)"
else
    no "image git is older than 2.48 ($GIT_VERSION)"
fi

eq "$(value ssh_proxy)" "yes" "image ships the ssh proxy config (git over SSH works with egress on)"
eq "$(value fs_vault)" "yes" "image preloads fs-vault (credential file guard)"
eq "$(value entrypoint)" "yes" "image entrypoint is installed"

printf '\nimage verify: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
