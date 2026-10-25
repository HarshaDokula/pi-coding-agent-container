#!/usr/bin/env bash
#
# Static checks for the build hardening (SECURITY.md C2, C3, C4).
#
# No Docker needed: these assert the Dockerfile keeps the properties the review
# relies on, and validate the pinned SSH host keys against GitHub's published
# fingerprints.
#
# Run from anywhere: bash tests/test-build-hardening.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

DOCKERFILE="$(cat Dockerfile 2>/dev/null)"
KNOWN_HOSTS="$(cat src/github_known_hosts 2>/dev/null)"

# --- C2: no toolchain in the runtime image ---------------------------------
has "AS builder" "$DOCKERFILE" "a builder stage exists for compilation"
has "COPY --from=builder /out/gh" "$DOCKERFILE" "gh vault is copied from the builder"
has "COPY --from=builder /out/fs-vault.so" "$DOCKERFILE" "fs-vault.so is copied from the builder"

# The runtime apt install must not pull the compiler back in. Collect the whole
# (line-continued) RUN block of the first apt-get install in the runtime stage;
# the builder's install is allowed.
RUNTIME_APT="$(awk '
    /^FROM .* AS base/ { stage = 1 }
    stage && /apt-get install/ { capture = 1 }
    capture { print; if ($0 !~ /\\$/) exit }
' Dockerfile)"
if printf '%s' "$RUNTIME_APT" | grep -q 'build-essential'; then
    no "runtime stage does not install build-essential"
else
    ok "runtime stage does not install build-essential"
fi
if printf '%s' "$RUNTIME_APT" | grep -q 'python3-dev'; then
    no "runtime stage does not install python3-dev"
else
    ok "runtime stage does not install python3-dev"
fi
has "python3" "$RUNTIME_APT" "runtime keeps the python3 interpreter"
has "PI_WITH_TOOLCHAIN" "$DOCKERFILE" "toolchain escape hatch is documented in the build"
hasnt "chmod 4755" "$DOCKERFILE" "no setuid binary is installed"
has "chmod 0755 /usr/local/bin/gh" "$DOCKERFILE" "gh is installed 0755"

# --- C3: pinned, verified SSH host keys ------------------------------------
has "github.com ssh-ed25519" "$KNOWN_HOSTS" "known_hosts has an ed25519 key"
has "github.com ecdsa-sha2-nistp256" "$KNOWN_HOSTS" "known_hosts has an ecdsa key"
has "github.com ssh-rsa" "$KNOWN_HOSTS" "known_hosts has an rsa key"
has "COPY src/github_known_hosts /etc/ssh/ssh_known_hosts" "$DOCKERFILE" "image ships the pinned known_hosts"
has "ssh-keygen -lf /etc/ssh/ssh_known_hosts" "$DOCKERFILE" "build verifies the shipped fingerprints"
# Ignore comments: the file explains why ssh-keyscan was dropped.
if grep -v '^[[:space:]]*#' Dockerfile | grep -q 'ssh-keyscan'; then
    no "build no longer trusts ssh-keyscan (TOFU)"
else
    ok "build no longer trusts ssh-keyscan (TOFU)"
fi

# The pinned keys must match GitHub's published fingerprints.
if command -v ssh-keygen >/dev/null 2>&1; then
    GOT="$(ssh-keygen -lf src/github_known_hosts 2>/dev/null | awk '{print $2}')"
    for fp in \
        SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU \
        SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM \
        SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s; do
        if printf '%s\n' "$GOT" | grep -qxF -- "$fp"; then
            ok "fingerprint matches GitHub: ${fp:0:20}…"
        else
            no "fingerprint matches GitHub: $fp"
        fi
    done
else
    echo "SKIP  ssh-keygen not available; fingerprint check skipped"
fi

# --- C4: pinned base image and verified apt keyring ------------------------
BASE_LINE="$(grep -m1 '^ARG NODE_IMAGE=' Dockerfile)"
has "node:26-trixie-slim@sha256:" "$BASE_LINE" "base image is pinned by digest"
if printf '%s' "$BASE_LINE" | grep -qE 'sha256:[0-9a-f]{64}'; then
    ok "base image digest is a full sha256"
else
    no "base image digest is a full sha256"
fi
has 'FROM ${NODE_IMAGE} AS builder' "$DOCKERFILE" "builder stage uses the pinned base"
has 'FROM ${NODE_IMAGE} AS base' "$DOCKERFILE" "runtime stage uses the pinned base"
has "GH_KEYRING_SHA256" "$DOCKERFILE" "gh apt keyring checksum is pinned"
has "sha256sum -c -" "$DOCKERFILE" "the keyring checksum is actually verified"
hasnt "wget -qO- https://cli.github.com" "$DOCKERFILE" "keyring is not piped straight into apt"

echo
echo "build hardening tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
