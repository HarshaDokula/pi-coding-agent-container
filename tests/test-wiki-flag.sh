#!/usr/bin/env bash
#
# Tests for the opt-in LLM Wiki switch: `make run WIKI=true` and `pictl -w`.
#
# No Docker or network required - everything is observed with `make -n` and
# `pictl --dry-run`, plus static greps of the compose overlay.
#
# Run from anywhere: bash tests/test-wiki-flag.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

MAKE_PLAIN="$(make -n run 2>/dev/null)"
MAKE_WIKI="$(make -n run WIKI=true 2>/dev/null)"
OVERLAY="$(cat docker-compose.wiki.yml 2>/dev/null)"

# --- default path stays pristine -------------------------------------------
hasnt "docker-compose.wiki.yml" "$MAKE_PLAIN" "plain run: no wiki overlay"
hasnt "/opt/pi-llm-wiki"        "$MAKE_PLAIN" "plain run: no wiki package loaded"

# --- opt-in path ------------------------------------------------------------
has "docker-compose.wiki.yml" "$MAKE_WIKI" "WIKI=true: wiki overlay used"
has "/opt/pi-llm-wiki/node_modules/@zosmaai/pi-llm-wiki" "$MAKE_WIKI" \
    "WIKI=true: pi -e loads the vendored package"

# --- compose overlay contents ----------------------------------------------
has "WIKI_HOME=/home/node/llm-wiki" "$OVERLAY" "overlay sets WIKI_HOME"
has "\${LLM_WIKI_DIR}:/home/node/llm-wiki" "$OVERLAY" "overlay mounts the shared vault"
has "\${LLM_WIKI_PKG_DIR}:/opt/pi-llm-wiki:ro" "$OVERLAY" "overlay mounts the package read-only"

# --- pictl flag -------------------------------------------------------------
PICTL_PLAIN="$(bin/pictl --dry-run /tmp 2>/dev/null)"
PICTL_WIKI="$(bin/pictl -w --dry-run /tmp 2>/dev/null)"
PICTL_COMBO="$(bin/pictl -w -d -p demo /tmp --dry-run 2>/dev/null)"

hasnt "WIKI=true" "$PICTL_PLAIN" "pictl plain: no WIKI=true"
has   "WIKI=true" "$PICTL_WIKI"  "pictl -w: passes WIKI=true"
has   "/tmp"      "$PICTL_WIKI"  "pictl -w: keeps the workspace"
has   "WIKI=true"         "$PICTL_COMBO" "pictl -w -d -p: passes WIKI=true"
has   "DETACHED=true"     "$PICTL_COMBO" "pictl -w -d -p: keeps detached"
has   "PROJECT_NAME=demo" "$PICTL_COMBO" "pictl -w -d -p: keeps project name"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
