#!/usr/bin/env bash
#
# Tests for the verification entry points (`make verify`, scripts/verify.sh,
# scripts/verify-image.sh). Hermetic: no Docker daemon or image is required.
#
# Run from anywhere: bash tests/test-verify.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Keep the fake docker inside the repo: /tmp is mounted noexec in the container.
TMP="$(mktemp -d "$REPO_ROOT/.verify-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

VERIFY="scripts/verify.sh"
VERIFY_IMAGE="scripts/verify-image.sh"
chmod +x "$VERIFY" "$VERIFY_IMAGE" 2>/dev/null || true

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

# --- 1. syntax --------------------------------------------------------------
if bash -n "$VERIFY" 2>/dev/null && bash -n "$VERIFY_IMAGE" 2>/dev/null; then
    ok "verify scripts have valid shell syntax"
else
    no "verify scripts have valid shell syntax"
fi

# --- 2. make wiring ---------------------------------------------------------
if command -v make >/dev/null 2>&1; then
    VCMD="$(make -n verify 2>/dev/null)"
    has "scripts/verify.sh" "$VCMD" "make verify runs scripts/verify.sh"

    HELP="$(make -n help 2>/dev/null)"
    has "make verify" "$HELP" "make help lists verify"
else
    echo "SKIP  make not installed — skipping make wiring assertions"
fi

# --- 3. image verifier degrades cleanly without Docker ----------------------
OUT="$(PI_DOCKER="$REPO_ROOT/no-such-docker" bash "$VERIFY_IMAGE" --allow-missing 2>&1)"; RC=$?
eq "$RC" "0" "verify-image --allow-missing skips without Docker"
has "SKIP" "$OUT" "verify-image --allow-missing reports the skip"

OUT="$(PI_DOCKER="$REPO_ROOT/no-such-docker" bash "$VERIFY_IMAGE" 2>&1)"; RC=$?
eq "$RC" "1" "verify-image fails without Docker when not allowed to skip"
has "FAIL" "$OUT" "verify-image explains the failure"

# --- 3b. the image verifier's contract logic (fake docker) -----------------
PIN="$(sed -n 's/^ARG PI_VERSION=//p' Dockerfile | head -1)"
FAKE="$TMP/fake-docker"
make_stub() {
    cat > "$FAKE" <<EOF
#!/bin/sh
case "\$1" in
    image) exit 0 ;;
    run)
        cat <<REPORT
version=$1
skip=1
git=git version 2.56.1
have=make
have=git
have=ssh
have=nc
have=gh
have=node
have=python3
have=curl
have=wget
compiler=$2
ssh_proxy=yes
fs_vault=yes
entrypoint=yes
REPORT
        ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$FAKE"
}

make_stub "$PIN" no
OUT="$(PI_DOCKER="$FAKE" bash "$VERIFY_IMAGE" 2>&1)"; RC=$?
eq "$RC" "0" "verify-image accepts a contract-compliant image"
has "image runs the pinned pi version" "$OUT" "verify-image checks the pi pin"

make_stub "0.0.0" no
OUT="$(PI_DOCKER="$FAKE" bash "$VERIFY_IMAGE" 2>&1)"; RC=$?
eq "$RC" "1" "verify-image rejects a wrong pi version"
has "FAIL" "$OUT" "verify-image reports the version mismatch"

make_stub "$PIN" yes
OUT="$(PI_DOCKER="$FAKE" PI_WITH_TOOLCHAIN=1 bash "$VERIFY_IMAGE" 2>&1)"; RC=$?
eq "$RC" "0" "verify-image allows a compiler for PI_WITH_TOOLCHAIN=1"

# --- 4. the image verifier keeps the contract checks ------------------------
IMG="$(cat "$VERIFY_IMAGE" 2>/dev/null)"
has 'PI_SKIP_VERSION_CHECK' "$IMG" "verify-image checks the self-update notice"
has 'pi --version' "$IMG" "verify-image checks the pi version"
has 'ProxyCommand /usr/local/bin/ssh-netcat-proxy' "$IMG" "verify-image checks the ssh proxy config"
has 'fs-vault' "$IMG" "verify-image checks the fs-vault preload"
has 'command -v gcc' "$IMG" "verify-image checks the compiler guard"
has 'git version' "$IMG" "verify-image checks the git version"

# --- 5. the orchestrator covers the right layers ----------------------------
V="$(cat "$VERIFY" 2>/dev/null)"
has 'make test' "$V" "verify runs the hermetic suite"
has 'bash -n' "$V" "verify checks shell syntax"
has 'docker compose' "$V" "verify validates compose config"
has 'verify-image.sh' "$V" "verify runs the image contract check"
has '--quick' "$V" "verify offers a quick mode"

printf '\nverify tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
