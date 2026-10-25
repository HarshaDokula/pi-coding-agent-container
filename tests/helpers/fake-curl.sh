#!/usr/bin/env bash
#
# Stub curl for tests/check-keys tests. Responds from FAKE_CODE / FAKE_BODY so
# the suite stays hermetic (no network, no real credentials).
#
# Lives in the repo rather than a temp dir because /tmp is mounted noexec inside
# the hardened container.
#
# Understands the subset of curl that scripts/check-keys.sh uses:
#   -s -o FILE -w FMT [-H ...] [--max-time N] URL
set -u

out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="${2:-}"; shift 2 ;;
        -w) shift 2 ;;
        -H|--max-time) shift 2 ;;
        *) shift ;;
    esac
done

[[ -n "$out" ]] && printf '%s' "${FAKE_BODY:-}" > "$out"
printf '%s' "${FAKE_CODE:-200}"
