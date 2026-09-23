#!/usr/bin/env bash
#
# Tests for scripts/fetch-llm-wiki.sh.
#
# Uses an exported `npm` shell function as a stub, so no network and no real npm
# is touched. The stub records calls in $NPM_CALLS and fabricates the expected
# installed package directory.
#
# Run from anywhere: bash tests/test-fetch-llm-wiki.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH_SRC="$REPO_ROOT/scripts/fetch-llm-wiki.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }
contains() { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else no "$3"; fi; }

# --- stub npm ---------------------------------------------------------------
export NPM_CALLS="$TMP/npm.calls"
: > "$NPM_CALLS"
npm() {
  printf 'call\n' >> "$NPM_CALLS"
  if [ "${NPM_FAIL:-0}" = "1" ]; then
    return 1
  fi
  local dest="" arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) dest="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$dest/node_modules/@zosmaai/pi-llm-wiki"
  printf '{"name":"@zosmaai/pi-llm-wiki"}\n' \
    > "$dest/node_modules/@zosmaai/pi-llm-wiki/package.json"
  # Reproduce the upstream invalid-YAML prompt so the patch path is exercised.
  mkdir -p "$dest/node_modules/@zosmaai/pi-llm-wiki/prompts"
  printf -- '---\ndescription: Run the full wiki cycle: discover -> ingest -> lint. Optionally schedule.\n---\n' \
    > "$dest/node_modules/@zosmaai/pi-llm-wiki/prompts/wiki-run.md"
  return 0
}
export -f npm

calls() { wc -l < "$NPM_CALLS" | tr -d ' '; }

# --- first run installs -----------------------------------------------------
DEST="$TMP/vendor"
bash "$FETCH_SRC" 0.12.2 "$DEST" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "first run: exit 0"
eq "$(calls)" "1" "first run: npm invoked once"
eq "$(cat "$DEST/.pi-llm-wiki-version" 2>/dev/null)" "0.12.2" "first run: marker written"
if [ -f "$DEST/node_modules/@zosmaai/pi-llm-wiki/package.json" ]; then
  ok "first run: package present"
else
  no "first run: package present"
fi

# --- second run is a no-op --------------------------------------------------
out="$(bash "$FETCH_SRC" 0.12.2 "$DEST" 2>&1)"; rc=$?
eq "$rc" "0" "second run: exit 0"
eq "$(calls)" "1" "second run: npm not invoked again"
contains "$out" "up to date" "second run: reports up to date"

# --- patch is applied (and re-applied on the up-to-date path) ---------------
PROMPT="$DEST/node_modules/@zosmaai/pi-llm-wiki/prompts/wiki-run.md"
if grep -q '^description: "Run the full wiki cycle: ' "$PROMPT"; then
  ok "patch: wiki-run description quoted after install"
else
  no "patch: wiki-run description quoted after install"
fi
printf -- '---\ndescription: Run the full wiki cycle: discover -> ingest -> lint.\n---\n' > "$PROMPT"
bash "$FETCH_SRC" 0.12.2 "$DEST" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "patch reapply: exit 0"
if grep -q '^description: "Run the full wiki cycle: ' "$PROMPT"; then
  ok "patch: re-applied on up-to-date path"
else
  no "patch: re-applied on up-to-date path"
fi

# --- version change reinstalls ----------------------------------------------
bash "$FETCH_SRC" 0.12.3 "$DEST" >/dev/null 2>&1; rc=$?
eq "$rc" "0" "version change: exit 0"
eq "$(calls)" "2" "version change: npm invoked again"
eq "$(cat "$DEST/.pi-llm-wiki-version")" "0.12.3" "version change: marker updated"

# --- npm failure is fatal ---------------------------------------------------
NPM_FAIL=1 bash "$FETCH_SRC" 9.9.9 "$TMP/fail-dest" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "npm failure: non-zero exit"; else no "npm failure: non-zero exit"; fi
if [ -f "$TMP/fail-dest/.pi-llm-wiki-version" ]; then
  no "npm failure: no marker written"
else
  ok "npm failure: no marker written"
fi

# --- missing version is a usage error ---------------------------------------
bash "$FETCH_SRC" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "missing version: non-zero exit"; else no "missing version: non-zero exit"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
