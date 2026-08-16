#!/bin/bash
# Fetches skills and extensions from a managed git repo into the pi data dir.
# Called by the Makefile during build/update.
# Usage: ./scripts/fetch-managed.sh <repo-url> [ref] [target-dir]

set -e

REPO_URL="$1"
REPO_REF="${2:-}"
TARGET_DIR="${3:-.pi-data}"

if [ -z "$REPO_URL" ]; then
  exit 0
fi

echo "==> Cloning managed skills/extensions from $REPO_URL ..."

tmpdir="$(mktemp -d)"

if [ -n "$REPO_REF" ]; then
  git clone --depth 1 --single-branch --branch "$REPO_REF" "$REPO_URL" "$tmpdir"
else
  git clone --depth 1 --single-branch "$REPO_URL" "$tmpdir"
fi

mkdir -p "$TARGET_DIR/agent/skills" "$TARGET_DIR/agent/extensions"

if [ -d "$tmpdir/skills" ]; then
  cp -r "$tmpdir/skills/"* "$TARGET_DIR/agent/skills/" 2>/dev/null || true
  echo "  ==> Copied skills to $TARGET_DIR/agent/skills/"
fi

if [ -d "$tmpdir/extensions" ]; then
  cp -r "$tmpdir/extensions/"* "$TARGET_DIR/agent/extensions/" 2>/dev/null || true
  echo "  ==> Copied extensions to $TARGET_DIR/agent/extensions/"
fi

rm -rf "$tmpdir"
echo "==> Done."
