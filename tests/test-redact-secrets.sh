#!/usr/bin/env bash
# Run the secret-redaction unit tests (src/redact-secrets.ts) under node.
#
# Node 22.18+/23+ strips TypeScript types natively, so the extension's pure
# redactText/redactValue functions are imported directly from the .ts source
# without a build step. The default export (the pi extension) is defined but
# not invoked here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIP  node not found on PATH (redact-secrets tests need node)" >&2
    exit 0
fi

node "$ROOT/tests/redact-secrets.test.mjs"
