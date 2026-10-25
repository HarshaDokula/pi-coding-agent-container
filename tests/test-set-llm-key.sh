#!/usr/bin/env bash
#
# Tests for scripts/set-llm-key.sh and the models.json indirection in
# scripts/check-keys.sh (SECURITY.md A5, A7).
#
# Hermetic: no keychain, no network, no real credentials.
#
# Run from anywhere: bash tests/test-set-llm-key.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET_KEY="$REPO_ROOT/scripts/set-llm-key.sh"
CHECK_KEYS="$REPO_ROOT/scripts/check-keys.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
# Pure-bash matching: no external grep, so these tests do not depend on the
# container's binary policy (the fs-vault shim and the tool sandbox can both
# deny a subprocess).
has()   { if [[ "$2" == *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
hasnt() { if [[ "$2" != *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }
eqmode(){ if [ "$(stat -c '%a' "$1" 2>/dev/null)" = "$2" ]; then ok "$3"; else no "$3"; fi; }

KEY="sk-unit-test-0123456789abcdef"

# --- 1. writes the secret 0400 and the models.json stanza ------------------
D="$TMP/one"
mkdir -p "$D/agent"
printf '%s\n' "$KEY" | "$SET_KEY" --provider deepseek --data-dir "$D" --secret "$D/llm_key" >/dev/null 2>&1
RC=$?
eq "$RC" "0" "set-llm-key exits 0"
eqmode "$D/llm_key" "400" "secret file is mode 400"
eq "$(cat "$D/llm_key")" "$KEY" "secret file holds the key"
eq "$(stat -c '%a' "$D/agent/models.json")" "600" "models.json is mode 600"
has '"apiKey": "!cat /run/secrets/llm_key"' "$(cat "$D/agent/models.json")" \
    "models.json uses the secret reference"
has '"deepseek"' "$(cat "$D/agent/models.json")" "models.json names the provider"

# --- 2. the key is never echoed -------------------------------------------
OUT="$(printf '%s\n' "$KEY" | "$SET_KEY" --provider deepseek --data-dir "$D" --secret "$D/llm_key" 2>&1)"
hasnt "$KEY" "$OUT" "set-llm-key never prints the key"
has "sk-uni…cdef" "$OUT" "set-llm-key prints a masked fingerprint"

# --- 3. stdin/file/env sources --------------------------------------------
D2="$TMP/two"; mkdir -p "$D2/agent"
printf '%s\n' "$KEY" > "$TMP/keyfile"
"$SET_KEY" --provider openai --data-dir "$D2" --secret "$D2/llm_key" --from "file:$TMP/keyfile" >/dev/null 2>&1
eq "$(cat "$D2/llm_key")" "$KEY" "--from file reads the key"
has '"openai"' "$(cat "$D2/agent/models.json")" "--from file uses the given provider"

D3="$TMP/three"; mkdir -p "$D3/agent"
PI_TEST_KEY="$KEY" "$SET_KEY" --provider google --data-dir "$D3" --secret "$D3/llm_key" --from env:PI_TEST_KEY >/dev/null 2>&1
eq "$(cat "$D3/llm_key")" "$KEY" "--from env reads the key"

# --- 4. bad input is refused ---------------------------------------------
D4="$TMP/four"; mkdir -p "$D4/agent"
OUT="$(printf '' | "$SET_KEY" --provider deepseek --data-dir "$D4" --secret "$D4/llm_key" 2>&1)"; RC=$?
eq "$RC" "1" "empty key exits 1"
has "empty key" "$OUT" "empty key is explained"
[ ! -f "$D4/llm_key" ] && ok "empty key writes no secret file" || no "empty key wrote a secret file"

OUT="$(printf 'short\n' | "$SET_KEY" --provider deepseek --data-dir "$D4" --secret "$D4/llm_key" 2>&1)"; RC=$?
eq "$RC" "1" "too-short key exits 1"

OUT="$(printf '%s\n' "$KEY" | "$SET_KEY" --provider deepseek --data-dir "$D4" --secret "$D4/llm_key" --from nope:1 2>&1)"; RC=$?
eq "$RC" "1" "unknown --from source exits 1"

OUT="$("$SET_KEY" --data-dir "$D4" --secret "$D4/llm_key" 2>&1)"; RC=$?
eq "$RC" "1" "missing --provider exits 1"

# --- 5. an existing unrelated models.json is not clobbered ----------------
D5="$TMP/five"; mkdir -p "$D5/agent"
printf '{ "providers": { "ollama": { "baseUrl": "http://localhost:11434/v1" } } }\n' > "$D5/agent/models.json"
BEFORE="$(cat "$D5/agent/models.json")"
OUT="$(printf '%s\n' "$KEY" | "$SET_KEY" --provider deepseek --data-dir "$D5" --secret "$D5/llm_key" 2>&1)"
eq "$(cat "$D5/agent/models.json")" "$BEFORE" "existing models.json is left untouched"
has "already exists" "$OUT" "user is told to merge by hand"
has '"deepseek"' "$OUT" "the stanza is printed for the user"

# --- 6. re-running is idempotent -----------------------------------------
OUT="$(printf '%s\n' "$KEY" | "$SET_KEY" --provider deepseek --data-dir "$D" --secret "$D/llm_key" 2>&1)"
has "already points at" "$OUT" "re-run reports the models.json is already wired"

# --- 7. --print-models writes nothing ------------------------------------
OUT="$("$SET_KEY" --provider deepseek --print-models 2>&1)"
has '"apiKey": "!cat /run/secrets/llm_key"' "$OUT" "--print-models shows the stanza"

# --- 8. warn when auth.json would win ------------------------------------
#     (creating auth.json is blocked by the fs-vault shim inside the container)
D6="$TMP/six"; mkdir -p "$D6/agent"
if printf '{}' > "$D6/agent/auth.json" 2>/dev/null; then
    printf '{ "deepseek": { "type": "api_key", "key": "sk-plaintext-0123456789" } }\n' > "$D6/agent/auth.json"
    OUT="$(printf '%s\n' "$KEY" | "$SET_KEY" --provider deepseek --data-dir "$D6" --secret "$D6/llm_key" 2>&1)"
    has "takes precedence" "$OUT" "warns that auth.json would win"
else
    echo "SKIP  auth.json precedence warning (blocked in container; run on host)"
fi

# --- 9. check-keys resolves the indirection ------------------------------
#     Fake curl so nothing leaves the machine.
FAKE_CURL="$REPO_ROOT/tests/helpers/fake-curl.sh"
D7="$TMP/seven"; mkdir -p "$D7/agent" "$D7/secrets"
printf '%s\n' "$KEY" > "$D7/secrets/llm_key"
printf '{\n  "providers": {\n    "deepseek": {\n      "apiKey": "!cat /run/secrets/llm_key"\n    }\n  }\n}\n' > "$D7/agent/models.json"
OUT="$(PI_CHECK_KEYS_CURL="$FAKE_CURL" FAKE_CODE=200 "$CHECK_KEYS" --data-dir "$D7" --secret-dir "$D7/secrets" 2>&1)"; RC=$?
has "OK" "$OUT" "check-keys probes a models.json secret"
has "secret /run/secrets/llm_key" "$OUT" "check-keys reports where the key came from"
hasnt "$KEY" "$OUT" "check-keys never prints the key"
eq "$RC" "0" "check-keys exits 0 for a healthy secret"

OUT="$(printf 'unset\n' > "$D7/secrets/llm_key"; PI_CHECK_KEYS_CURL="$FAKE_CURL" "$CHECK_KEYS" --data-dir "$D7" --secret-dir "$D7/secrets" 2>&1)"
has "placeholder" "$OUT" "placeholder secret is skipped with a hint"

OUT="$(rm -f "$D7/secrets/llm_key"; PI_CHECK_KEYS_CURL="$FAKE_CURL" "$CHECK_KEYS" --data-dir "$D7" --secret-dir "$D7/secrets" 2>&1)"
has "not found" "$OUT" "missing secret is reported"

# --- 10. auth.json wins over models.json ---------------------------------
D8="$TMP/eight"; mkdir -p "$D8/agent" "$D8/secrets"
printf '%s\n' "$KEY" > "$D8/secrets/llm_key"
printf '{\n  "providers": {\n    "deepseek": {\n      "apiKey": "!cat /run/secrets/llm_key"\n    }\n  }\n}\n' > "$D8/agent/models.json"
if printf '{}' > "$D8/agent/auth.json" 2>/dev/null; then
    printf '{ "deepseek": { "type": "api_key", "key": "sk-authwins-0123456789ab" } }\n' > "$D8/agent/auth.json"
    OUT="$(PI_CHECK_KEYS_CURL="$FAKE_CURL" FAKE_CODE=200 "$CHECK_KEYS" --data-dir "$D8" --secret-dir "$D8/secrets" 2>&1)"
    hasnt "secret /run/secrets/llm_key" "$OUT" "auth.json entry suppresses the models.json probe"
else
    echo "SKIP  auth.json precedence (blocked in container; run on host)"
fi

# --- 11. compose + setup wiring ------------------------------------------
COMPOSE="$(cat "$REPO_ROOT/docker-compose.yml" 2>/dev/null)"
has "source: llm_key" "$COMPOSE" "compose mounts the llm_key secret"
has "/run/secrets/llm_key" "$COMPOSE" "compose targets /run/secrets/llm_key"
MAKE_SETUP="$(cd "$REPO_ROOT" && make -n setup 2>/dev/null)"
has ".secrets/llm_key" "$MAKE_SETUP" "make setup creates the secret placeholder"
MAKE_SETKEY="$(cd "$REPO_ROOT" && make -n set-key 2>/dev/null)"
has "set-llm-key.sh" "$MAKE_SETKEY" "make set-key runs the script"

echo
echo "set-llm-key tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
