#!/usr/bin/env bash
#
# verify.sh — one fast command to check this repo before trusting a build.
#
# It runs, in order:
#   1. the hermetic test suite (`make test`; no Docker needed)
#   2. shell syntax for every first-party script
#   3. `docker compose config` for the base file and every overlay
#   4. the built image's runtime contract (scripts/verify-image.sh)
#
# Docker checks are skipped cleanly when Docker or the image is absent, so the
# command is safe before the first build. This is not Bazel: the product is a
# Docker image plus shell glue, and these checks exercise exactly that.
#
# Usage: verify.sh [--quick]
#   --quick  skip the post-build image contract check
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
quick=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) quick=1; shift ;;
        -h|--help)
            echo "usage: verify.sh [--quick]"
            exit 0
            ;;
        *) echo "verify: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

pass=0
fail=0
skip=0
ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()   { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skipt(){ printf 'SKIP  %s\n' "$1"; skip=$((skip + 1)); }
warn() { printf 'WARN  %s\n' "$1"; }

# --- 1. hermetic test suite -------------------------------------------------
if command -v make >/dev/null 2>&1; then
    echo "== make test =="
    if make test; then
        ok "hermetic test suite"
    else
        no "hermetic test suite"
    fi
else
    skipt "make not installed — cannot run the test suite"
fi

# --- 2. shell syntax --------------------------------------------------------
bad=""
while IFS= read -r f; do
    if ! bash -n "$f" 2>/dev/null; then
        bad="$bad $f"
    fi
done < <(find . -type f \( -name '*.sh' -o -path './bin/pictl' \) \
    -not -path './.git/*' -not -path './vendor/*' -not -path './.pi-data*/*' \
    -not -path './.pi-workspace/*' -not -path './workspace/*' -not -path './.verify-test.*' | sort)
if [[ -z "$bad" ]]; then
    ok "shell syntax (first-party scripts)"
else
    no "shell syntax:$bad"
fi

# --- 3. compose config ------------------------------------------------------
if [[ ! -f .secrets/github_token.txt || ! -f .secrets/llm_key ]]; then
    skipt "compose config skipped (run 'make setup' to create secret placeholders)"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    for files in \
        "-f docker-compose.yml" \
        "-f docker-compose.yml -f docker-compose.egress.yml" \
        "-f docker-compose.yml -f docker-compose.wiki.yml" \
        "-f docker-compose.yml -f docker-compose.shared-toolchains.yml"; do
        if docker compose $files config -q >/dev/null 2>&1; then
            ok "compose config: $files"
        else
            no "compose config: $files"
        fi
    done
else
    skipt "docker compose not available — compose config not checked"
fi

# --- 4. optional linters ----------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning scripts/*.sh bin/pictl src/*.sh 2>/dev/null; then
        ok "shellcheck (scripts, bin/pictl, src)"
    else
        warn "shellcheck reported warnings (advisory)"
    fi
else
    skipt "shellcheck not installed (optional)"
fi

if command -v hadolint >/dev/null 2>&1; then
    if hadolint Dockerfile >/dev/null 2>&1; then
        ok "hadolint (Dockerfile)"
    else
        warn "hadolint reported warnings (advisory)"
    fi
else
    skipt "hadolint not installed (optional)"
fi

# --- 5. image contract ------------------------------------------------------
if [[ "$quick" -eq 1 ]]; then
    skipt "image contract check skipped (--quick)"
else
    echo "== image contract =="
    if scripts/verify-image.sh --allow-missing; then
        ok "image contract"
    else
        no "image contract"
    fi
fi

printf '\nverify: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
