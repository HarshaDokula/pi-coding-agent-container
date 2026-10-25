#!/usr/bin/env bash
#
# Tests for scripts/check-keys.sh (SECURITY.md A6).
#
# Hermetic: curl is replaced with a stub via PI_CHECK_KEYS_CURL, so no network
# and no real credentials are involved.
#
# Note: fixtures are passed with --auth-file and deliberately avoid a filename
# containing "auth.json" — inside the hardened container the fs-vault preload
# shim blocks that path for non-pi processes, which would break this test.
#
# Run from anywhere: bash tests/test-check-keys.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check-keys.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

make_auth() { # <file> <provider> <key>
    printf '{ "%s": { "type": "api_key", "key": "%s" } }\n' "$2" "$3" > "$1"
}

FAKE_CURL="$REPO_ROOT/tests/helpers/fake-curl.sh"

run() { # <auth-file> [extra args...]
    local auth="$1"; shift
    PI_CHECK_KEYS_CURL="$FAKE_CURL" "$SCRIPT" --auth-file "$auth" "$@" 2>&1
}

# --- 1. healthy key -------------------------------------------------------
A="$TMP/creds-ok.json"; make_auth "$A" deepseek "sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OUT="$(FAKE_CODE=200 run "$A")"; RC=$?
has "OK" "$OUT" "200 response reports OK"
has "deepseek" "$OUT" "provider name is shown"
[ "$RC" -eq 0 ] && ok "healthy key exits 0" || no "healthy key exits 0 (rc=$RC)"

# --- 2. rejected key ------------------------------------------------------
OUT="$(FAKE_CODE=401 run "$A")"; RC=$?
has "FAIL" "$OUT" "401 reports FAIL"
has "key rejected" "$OUT" "401 explains the key was rejected"
[ "$RC" -eq 1 ] && ok "rejected key exits 1" || no "rejected key exits 1 (rc=$RC)"

# --- 3. network failure (curl prints 000) ---------------------------------
OUT="$(FAKE_CODE=000 run "$A")"; RC=$?
has "no response" "$OUT" "curl 000 reports a network failure"
[ "$RC" -eq 1 ] && ok "network failure exits 1" || no "network failure exits 1 (rc=$RC)"

# --- 4. OpenCode free tier special case -----------------------------------
Z="$TMP/creds-zen.json"; make_auth "$Z" opencode "sk-ffffffffffffffffffffffffffffffff"
OUT="$(FAKE_CODE=403 FAKE_BODY='{"error":{"type":"FreeTierError"}}' run "$Z")"
has "OpenCode free tier" "$OUT" "FreeTierError gets a specific explanation"

# --- 5. unknown provider is skipped, not failed ---------------------------
B="$TMP/creds-unknown.json"; make_auth "$B" mycustom "abc123"
OUT="$(FAKE_CODE=200 run "$B")"; RC=$?
has "SKIP" "$OUT" "unknown provider is skipped"
has "no probe defined" "$OUT" "skip reason is explained"
[ "$RC" -eq 2 ] && ok "only-unknown provider exits 2 (nothing probeable)" \
                || no "only-unknown provider exits 2 (rc=$RC)"

# --- 6. mixed providers: one OK, one skipped ------------------------------
C="$TMP/creds-mixed.json"
printf '{ "deepseek": { "type": "api_key", "key": "sk-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },\n  "mycustom": { "type": "api_key", "key": "zzz" } }\n' > "$C"
OUT="$(FAKE_CODE=200 run "$C")"; RC=$?
has "OK" "$OUT" "mixed: known provider probed"
has "SKIP" "$OUT" "mixed: unknown provider skipped"
[ "$RC" -eq 0 ] && ok "mixed providers exit 0" || no "mixed providers exit 0 (rc=$RC)"

# --- 7. masking: the full key never appears -------------------------------
SECRET="sk-cccccccccccccccccccccccccccccc"
D="$TMP/creds-mask.json"; make_auth "$D" deepseek "$SECRET"
OUT="$(FAKE_CODE=200 run "$D")"
hasnt "$SECRET" "$OUT" "full key is never printed"
has "sk-ccc…" "$OUT" "masked fingerprint is printed"

# --- 8. --provider filter -------------------------------------------------
E="$TMP/creds-two.json"
printf '{ "deepseek": { "type": "api_key", "key": "sk-dddddddddddddddddddddddddddddddd" },\n  "openai": { "type": "api_key", "key": "sk-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" } }\n' > "$E"
OUT="$(FAKE_CODE=200 run "$E" --provider deepseek)"
has "deepseek" "$OUT" "--provider selects the provider"
hasnt "openai" "$OUT" "--provider filters other providers out"

# --- 9. missing credentials file -----------------------------------------
OUT="$(PI_CHECK_KEYS_CURL="$FAKE_CURL" "$SCRIPT" --auth-file "$TMP/does-not-exist" 2>&1)"; RC=$?
has "no credential file" "$OUT" "missing file is explained"
[ "$RC" -eq 2 ] && ok "missing file exits 2" || no "missing file exits 2 (rc=$RC)"

# --- 10. no api_key entry ------------------------------------------------
F="$TMP/creds-tokenstore.json"
printf '{ "github": { "type": "oauth", "access": "x" } }\n' > "$F"
OUT="$(FAKE_CODE=200 run "$F")"; RC=$?
has "no api_key entry" "$OUT" "non-api_key provider is skipped"

# --- 11. wired into make --------------------------------------------------
MAKE_TARGET="$(cd "$REPO_ROOT" && make -n check-keys 2>/dev/null)"
has "check-keys.sh" "$MAKE_TARGET" "make check-keys runs the script"
MAKE_HELP="$(cd "$REPO_ROOT" && make -n help 2>/dev/null || true)"

echo
echo "check-keys tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
