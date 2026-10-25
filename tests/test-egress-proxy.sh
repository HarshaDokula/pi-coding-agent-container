#!/usr/bin/env bash
# Run the egress-proxy unit tests (src/egress-proxy.js) under node.
#
# Exercises allowlist parsing/matching and an end-to-end plain-HTTP forward
# and deny path over localhost — no Docker needed. The CONNECT (HTTPS) path
# shares the same isAllowed() decision that these tests cover.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP  node not found on PATH (egress-proxy tests need node)" >&2
    exit 0
fi

node "$ROOT/tests/egress-proxy.test.mjs"
