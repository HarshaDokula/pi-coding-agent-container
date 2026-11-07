#!/usr/bin/env bash
#
# setup-subagents.sh — install the pinned @tintinweb/pi-subagents pi package
# into a per-instance pi data dir (experimental, branch experimental/subagents).
#
# Usage: scripts/setup-subagents.sh <version> [pi-data-dir]
#
#   version       npm version of @tintinweb/pi-subagents (e.g. 0.22.0)
#   pi-data-dir   pi data dir, i.e. the host dir behind /home/node/.pi
#                 (default: <repo>/.pi-data)
#
# The install runs inside a throwaway container from the same image a normal
# run uses, so npm resolves against the pi version the image pins and the result
# lands in the mounted data dir:
#   <dir>/agent/npm/node_modules/@tintinweb/pi-subagents   (package + deps)
#   <dir>/agent/settings.json                              (packages entry)
# Pi loads declared packages on every later run of that data dir, so this is a
# one-time step per instance — there is no per-run flag like the wiki's `-w`.
#
# Idempotent: a matching settings declaration plus an installed tree at the same
# version exits 0 without touching the network. Bumping the version reinstalls
# and drops the previous declaration first, so settings never carries two
# entries for the same package.
#
# Requires Docker and network. Normally called through `make subagents-setup`.
# DRY_RUN=1 prints what would run instead of invoking Docker (used by tests).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-}"
DATA="${2:-$REPO_ROOT/.pi-data}"

PKG="@tintinweb/pi-subagents"
SPEC="npm:${PKG}@${VERSION}"
SETTINGS="$DATA/agent/settings.json"
INSTALLED="$DATA/agent/npm/node_modules/$PKG/package.json"

if [ -z "$VERSION" ]; then
  echo "setup-subagents: missing version (usage: setup-subagents.sh <version> [pi-data-dir])" >&2
  exit 2
fi

version_matches() {
  [ -f "$INSTALLED" ] && node -e '
    process.exit(require(process.argv[1]).version === process.argv[2] ? 0 : 1)
  ' "$INSTALLED" "$VERSION"
}

declared() {
  [ -f "$SETTINGS" ] && grep -qF "\"$SPEC\"" "$SETTINGS"
}

# Already installed at this version and still declared: nothing to do.
if version_matches && declared; then
  echo "==> $PKG@$VERSION already installed in $DATA"
  exit 0
fi

# Drop stale declarations of the same package (any other version), so pi does
# not keep (or try to load) an older copy next to the one we are about to add.
if [ "${DRY_RUN:-}" != "1" ] && ! command -v docker >/dev/null 2>&1; then
  echo "setup-subagents: docker not found on PATH - run 'make subagents-setup' on the host" >&2
  exit 1
fi

if [ -f "$SETTINGS" ]; then
  cp -p "$SETTINGS" "$SETTINGS.bak"
  node -e '
    const fs = require("fs");
    const [file, pkgName] = process.argv.slice(1);
    const settings = JSON.parse(fs.readFileSync(file, "utf8"));

    // Package sources look like "npm:@scope/name@1.2.3" or { source: "..." }.
    // Compare the bare name: strip "npm:", then cut the version that follows
    // the name (the leading "@" belongs to the scope).
    const nameOf = (entry) => {
      const src = typeof entry === "string" ? entry : entry && entry.source;
      if (typeof src !== "string" || !src.startsWith("npm:")) return null;
      const rest = src.slice("npm:".length);
      const at = rest.indexOf("@", 1);
      return at === -1 ? rest : rest.slice(0, at);
    };

    if (!Array.isArray(settings.packages)) process.exit(0);
    const kept = settings.packages.filter((entry) => nameOf(entry) !== pkgName);
    if (kept.length === settings.packages.length) process.exit(0);

    settings.packages = kept;
    fs.writeFileSync(file, JSON.stringify(settings, null, 2) + "\n");
    console.log(`==> Dropped previous ${pkgName} declaration (backup: ${file}.bak)`);
  ' "$SETTINGS" "$PKG"
fi

if [ "${DRY_RUN:-}" = "1" ]; then
  echo "==> [dry run] docker compose run --rm pi-agent install $SPEC"
  exit 0
fi

echo "==> Installing $SPEC into $DATA ..."
docker compose run --rm pi-agent install "$SPEC"

if ! version_matches; then
  echo "setup-subagents: $PKG@$VERSION not found after install ($INSTALLED)" >&2
  exit 1
fi
if ! declared; then
  echo "setup-subagents: $SPEC is missing from $SETTINGS after install" >&2
  exit 1
fi

echo "==> Installed $SPEC in $DATA"
