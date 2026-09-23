#!/usr/bin/env bash
#
# fetch-llm-wiki.sh — vendor a pinned @zosmaai/pi-llm-wiki into a directory
# that is mounted read-only into opted-in agent containers.
#
# Usage:
#   scripts/fetch-llm-wiki.sh <version> [dest]
#
#   version   npm version/tag of @zosmaai/pi-llm-wiki (e.g. 0.12.2)
#   dest      install directory (default: <repo>/vendor/pi-llm-wiki)
#
# Idempotent: if <dest>/.pi-llm-wiki-version already equals <version> and the
# package directory exists, it exits 0 without touching the network.
#
# Run this on the HOST (it is called by `make wiki-setup`), never inside the
# container: the container's root FS is read-only and /tmp is noexec.
#
# --ignore-scripts is deliberate. The package's only native dependency chain
# (@tobilu/qmd -> tree-sitter-*, better-sqlite3, node-llama-cpp, sqlite-vec) is
# imported *lazily* by the extension and is only needed for optional semantic
# indexing. Skipping lifecycle scripts keeps core capture/ingest/search/recall
# working without a C toolchain. (Native/qmd features are unavailable until the
# deps are built; see README.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-}"
DEST="${2:-$REPO_ROOT/vendor/pi-llm-wiki}"

if [ -z "$VERSION" ]; then
  echo "fetch-llm-wiki: missing version (usage: fetch-llm-wiki.sh <version> [dest])" >&2
  exit 1
fi

PKG="@zosmaai/pi-llm-wiki"
PKG_DIR="$DEST/node_modules/@zosmaai/pi-llm-wiki"
MARKER="$DEST/.pi-llm-wiki-version"

# Local, idempotent fixes for known issues in the vendored package. Safe to run
# on every invocation (including the up-to-date path) so new patches apply
# without changing LLM_WIKI_VERSION.
apply_patches() {
  local prompt="$PKG_DIR/prompts/wiki-run.md"
  [ -f "$prompt" ] || return 0
  # 0.12.2 ships `description:` with an unquoted ": " (e.g. "cycle: discover"),
  # which is invalid YAML. pi then refuses to load the /wiki-run prompt. Quote
  # the scalar so it parses. Guarded so it only rewrites the buggy form.
  if grep -q '^description: Run the full wiki cycle: ' "$prompt" 2>/dev/null; then
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/llm-wiki-patch.XXXXXX")"
    awk '/^description: Run the full wiki cycle: /{ sub(/^description: /, "description: \""); print $0 "\""; next } { print }' \
      "$prompt" > "$tmp"
    mv "$tmp" "$prompt"
    echo "==> Patched prompts/wiki-run.md (quoted description for valid YAML)"
  fi
}

if [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$VERSION" ] && [ -f "$PKG_DIR/package.json" ]; then
  echo "==> $PKG@$VERSION already vendored at $DEST (up to date)"
  apply_patches
  exit 0
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "fetch-llm-wiki: npm not found on PATH - install Node.js/npm on the host first" >&2
  exit 1
fi

echo "==> Vendoring $PKG@$VERSION into $DEST ..."
mkdir -p "$DEST"

# --no-save keeps the vendored dir free of a package.json/lockfile so the
# version marker is the single source of truth for idempotency.
if ! npm install \
    --prefix "$DEST" \
    --no-save \
    --omit=dev \
    --ignore-scripts \
    --no-audit \
    --no-fund \
    "$PKG@$VERSION"; then
  echo "fetch-llm-wiki: npm install failed for $PKG@$VERSION" >&2
  exit 1
fi

if [ ! -f "$PKG_DIR/package.json" ]; then
  echo "fetch-llm-wiki: expected package missing after install: $PKG_DIR/package.json" >&2
  exit 1
fi

apply_patches

# Write the marker last and atomically, so an interrupted install is retried.
printf '%s' "$VERSION" > "$MARKER.tmp"
mv "$MARKER.tmp" "$MARKER"

echo "==> Vendored $PKG@$VERSION at $DEST"
