#!/usr/bin/env bash
#
# Tests for the experimental subagents setup: `make subagents-setup`
# (scripts/setup-subagents.sh) on branch experimental/subagents.
#
# No Docker or network required - the Docker invocation is either only printed
# (`make -n`, DRY_RUN=1) or never reached (idempotent path), and everything else
# is observed on a throwaway data dir under $TMPDIR.
#
# Run from anywhere: bash tests/test-subagents-setup.sh

set -u

# These assertions drive `make`; skip cleanly where make is not installed
# (e.g. running the tests inside the container instead of on the host).
command -v make >/dev/null 2>&1 || { echo "SKIP  make not installed — run this suite on the host"; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

SCRIPT="scripts/setup-subagents.sh"
PKG="@tintinweb/pi-subagents"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Makefile wiring --------------------------------------------------------
MAKE_SETUP="$(make -n subagents-setup 2>/dev/null)"
has "\"0.22.0\""        "$MAKE_SETUP" "subagents-setup: default version is pinned"
has "setup-subagents.sh" "$MAKE_SETUP" "subagents-setup: calls the setup script"

MAKE_OVERRIDE="$(make -n subagents-setup SUBAGENTS_VERSION=9.9.9 2>/dev/null)"
has '"9.9.9"' "$MAKE_OVERRIDE" "subagents-setup: SUBAGENTS_VERSION override wins"

hasnt "setup-subagents" "$(make -n run 2>/dev/null)" "plain run: subagents install stays opt-in"
has "subagents-setup" "$(sed -n 1p Makefile)" ".PHONY lists subagents-setup"

# --- script: argument handling ---------------------------------------------
bash -n "$SCRIPT" 2>/dev/null && ok "script: parses (bash -n)" || no "script: parses (bash -n)"

"$SCRIPT" >/dev/null 2>&1
[ $? -eq 2 ] && ok "script: missing version exits 2" || no "script: missing version exits 2"

# --- script: already installed at the requested version is a no-op ----------
DATA="$TMP/installed"
mkdir -p "$DATA/agent/npm/node_modules/$PKG"
printf '{"version":"0.22.0"}\n' > "$DATA/agent/npm/node_modules/$PKG/package.json"
printf '{\n  "packages": [\n    "npm:%s@0.22.0"\n  ]\n}\n' "$PKG" > "$DATA/agent/settings.json"
BEFORE="$(cat "$DATA/agent/settings.json")"
OUT="$("$SCRIPT" 0.22.0 "$DATA" 2>&1)"
RC=$?
[ $RC -eq 0 ] && ok "script: idempotent re-run exits 0" || no "script: idempotent re-run exits 0 (got $RC)"
has "already installed" "$OUT" "script: idempotent re-run says so"
[ "$(cat "$DATA/agent/settings.json")" = "$BEFORE" ] && ok "script: idempotent re-run leaves settings untouched" \
  || no "script: idempotent re-run leaves settings untouched"
[ ! -f "$DATA/agent/settings.json.bak" ] && ok "script: idempotent re-run writes no backup" \
  || no "script: idempotent re-run writes no backup"

# --- script: a stale declaration is dropped before (dry-run) install --------
DATA2="$TMP/stale"
mkdir -p "$DATA2/agent"
printf '{\n  "theme": "dark",\n  "packages": [\n    "npm:%s@0.21.0"\n  ]\n}\n' "$PKG" > "$DATA2/agent/settings.json"
OUT2="$(DRY_RUN=1 "$SCRIPT" 0.22.0 "$DATA2" 2>&1)"
RC2=$?
[ $RC2 -eq 0 ] && ok "script: dry run exits 0 without docker" || no "script: dry run exits 0 without docker (got $RC2)"
has "npm:$PKG@0.22.0" "$OUT2" "script: dry run prints the pinned install"
hasnt "@0.21.0" "$(cat "$DATA2/agent/settings.json")" "script: stale package declaration dropped"
has '"theme": "dark"' "$(cat "$DATA2/agent/settings.json")" "script: unrelated settings preserved"
[ -f "$DATA2/agent/settings.json.bak" ] && ok "script: previous settings backed up" || no "script: previous settings backed up"

# --- script: no docker means fail fast, settings untouched ------------------
DATA3="$TMP/nodocker"
mkdir -p "$DATA3/agent"
printf '{\n  "packages": []\n}\n' > "$DATA3/agent/settings.json"
BEFORE3="$(cat "$DATA3/agent/settings.json")"
if command -v docker >/dev/null 2>&1; then
  ok "script: docker present, fail-fast path not exercised"
else
  "$SCRIPT" 0.22.0 "$DATA3" >/dev/null 2>&1
  [ $? -eq 1 ] && ok "script: missing docker exits 1" || no "script: missing docker exits 1"
  [ "$(cat "$DATA3/agent/settings.json")" = "$BEFORE3" ] && ok "script: missing docker leaves settings untouched" \
    || no "script: missing docker leaves settings untouched"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
