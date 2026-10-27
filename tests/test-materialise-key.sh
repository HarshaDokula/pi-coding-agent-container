#!/usr/bin/env bash
#
# Tests for keeping the LLM key out of persistent files (SECURITY.md A7):
#   scripts/materialise-key.sh  — fetch the key per run into tmpfs
#   scripts/set-llm-key.sh --ephemeral — store only the reference
#
# Hermetic: sources are files, XDG_RUNTIME_DIR points at a temp dir, and .env is
# redirected with --env-file.
#
# Run from anywhere: bash tests/test-materialise-key.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAT="$REPO_ROOT/scripts/materialise-key.sh"
SETKEY="$REPO_ROOT/scripts/set-llm-key.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if [[ "$2" == *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
hasnt() { if [[ "$2" != *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

KEY="sk-materialise-0123456789abcd"
printf '%s\n' "$KEY" > "$TMP/keyfile"
mkdir -p "$TMP/runtime" "$TMP/data/agent"

# --- 1. no source: the static file path is printed, nothing else ----------
OUT="$(PI_KEY_SOURCE= "$MAT" 2>/dev/null)"
eq "$OUT" "$REPO_ROOT/.secrets/llm_key" "without PI_KEY_SOURCE the static file is used"
OUT_ERR="$(PI_KEY_SOURCE= "$MAT" --show 2>&1 >/dev/null)"
has "no PI_KEY_SOURCE" "$OUT_ERR" "the fallback is explained on stderr"

# --- 2. with a source: the key lands in tmpfs, path on stdout -------------
OUT="$(PI_KEY_SOURCE="file:$TMP/keyfile" XDG_RUNTIME_DIR="$TMP/runtime" "$MAT" 2>/dev/null)"
case "$OUT" in
    "$TMP/runtime"/*) ok "the key is materialised under XDG_RUNTIME_DIR" ;;
    *) no "the key is materialised under XDG_RUNTIME_DIR (got '$OUT')" ;;
esac
eq "$(cat "$OUT")" "$KEY" "the materialised file holds the key"
eq "$(stat -c '%a' "$OUT")" "400" "the materialised file is mode 400"
hasnt "$KEY" "$(PI_KEY_SOURCE="file:$TMP/keyfile" XDG_RUNTIME_DIR="$TMP/runtime" "$MAT" 2>&1)" \
    "the key itself is never printed"

# --- 3. a second run overwrites, does not accumulate ---------------------
printf 'sk-second-0123456789abcdef\n' > "$TMP/keyfile2"
OUT2="$(PI_KEY_SOURCE="file:$TMP/keyfile2" XDG_RUNTIME_DIR="$TMP/runtime" "$MAT" 2>/dev/null)"
eq "$OUT" "$OUT2" "the path is stable across runs (same file, rewritten)"
eq "$(cat "$OUT2")" "sk-second-0123456789abcdef" "the new key replaced the old one"

# --- 4. broken sources fail loudly --------------------------------------
OUT="$(PI_KEY_SOURCE="file:$TMP/nope" XDG_RUNTIME_DIR="$TMP/runtime" "$MAT" 2>&1 >/dev/null)"; RC=$?
eq "$RC" "1" "an unreadable source exits 1"
has "cannot read" "$OUT" "an unreadable source is explained"

OUT="$(PI_KEY_SOURCE="carrier-pigeon:coop" "$MAT" 2>&1 >/dev/null)"; RC=$?
eq "$RC" "1" "an unknown source scheme exits 1"
has "unknown PI_KEY_SOURCE" "$OUT" "an unknown scheme is explained"

OUT="$(PI_KEY_SOURCE="env:PI_NOT_SET_ANYWHERE" "$MAT" 2>&1 >/dev/null)"; RC=$?
eq "$RC" "1" "an empty env source exits 1"

# --- 5. no tmpfs available: falls back to the static file with a warning --
OUT="$(PI_KEY_SOURCE="file:$TMP/keyfile" XDG_RUNTIME_DIR= PI_TEST_NO_SHM=1 "$MAT" 2>/dev/null)"
has "/dev/shm" "$OUT" "falls back to /dev/shm when XDG_RUNTIME_DIR is unset"

# --- 6. --ephemeral stores the reference, never the key ------------------
ENVF="$TMP/env"
printf 'GIT_NAME=tester\n' > "$ENVF"
SEC="$TMP/stored_llm_key"
printf 'sk-previously-stored-000000\n' > "$SEC"
OUT="$("$SETKEY" --provider deepseek --data-dir "$TMP/data" --secret "$SEC" --env-file "$ENVF" \
        --from "file:$TMP/keyfile" --ephemeral 2>&1)"; RC=$?
eq "$RC" "0" "--ephemeral succeeds"
has "PI_KEY_SOURCE=file:$TMP/keyfile" "$(cat "$ENVF")" "the reference is recorded in .env"
has "GIT_NAME=tester" "$(cat "$ENVF")" "the rest of .env is preserved"
eq "$(cat "$SEC")" "unset" "a previously stored key is scrubbed"
hasnt "$KEY" "$(cat "$ENVF")" "the key is not written to .env"
hasnt "$KEY" "$OUT" "the key is not printed"
has '"apiKey": "!cat /run/secrets/llm_key"' "$(cat "$TMP/data/agent/models.json")" \
    "models.json points at the secret"
eq "$(stat -c '%a' "$ENVF")" "600" ".env stays private"

# --- 7. the reference is refreshed, not duplicated ----------------------
"$SETKEY" --provider deepseek --data-dir "$TMP/data" --secret "$SEC" --env-file "$ENVF" \
    --from "file:$TMP/keyfile2" --ephemeral --quiet >/dev/null 2>&1
eq "$(grep -c '^PI_KEY_SOURCE=' "$ENVF" 2>/dev/null || echo 0)" "1" "PI_KEY_SOURCE appears exactly once"
has "keyfile2" "$(cat "$ENVF")" "the reference is updated in place"

# --- 8. --ephemeral refuses a source it cannot re-read -------------------
OUT="$("$SETKEY" --provider deepseek --data-dir "$TMP/data" --secret "$SEC" --env-file "$ENVF" \
        --ephemeral --quiet <<<"$KEY" 2>&1)"; RC=$?
eq "$RC" "1" "--ephemeral with stdin is refused"
has "re-readable" "$OUT" "the refusal explains why"

# --- 9. wiring: make uses the materialised path, compose honours it ------
if command -v make >/dev/null 2>&1; then
    RUN="$(cd "$REPO_ROOT" && make -n run 2>/dev/null)"
    has "materialise-key.sh" "$RUN" "make run materialises the key"
else
    echo "SKIP  make wiring (make is not installed here)"
fi
COMPOSE="$(cat "$REPO_ROOT/docker-compose.yml")"
has 'file: ${LLM_KEY_FILE:-.secrets/llm_key}' "$COMPOSE" "compose takes the key path from LLM_KEY_FILE"

echo
echo "materialise-key tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
