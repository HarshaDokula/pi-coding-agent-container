#!/bin/bash
# Fetches skills and extensions from a managed git repo into .pi-data/agent/
# Called by the Makefile during build/update.
# Usage: ./scripts/fetch-managed.sh <repo-url> [ref]

set -e

REPO_URL="$1"
REPO_REF="${2:-}"

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

mkdir -p .pi-data/agent/skills .pi-data/agent/extensions

if [ -d "$tmpdir/skills" ]; then
  cp -r "$tmpdir/skills/"* .pi-data/agent/skills/ 2>/dev/null || true
  echo "  ==> Copied skills to .pi-data/agent/skills/"
fi

if [ -d "$tmpdir/extensions" ]; then
  cp -r "$tmpdir/extensions/"* .pi-data/agent/extensions/ 2>/dev/null || true
  echo "  ==> Copied extensions to .pi-data/agent/extensions/"
fi

rm -rf "$tmpdir"
echo "==> Done."
