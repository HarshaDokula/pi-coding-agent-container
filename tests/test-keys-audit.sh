#!/usr/bin/env bash
#
# Tests for scripts/keys-audit.mjs — the per-instance credential audit/prune.
#
# Hermetic. Fixtures use --auth-name so the filename is not "auth.json": inside
# the hardened container that name is denied to non-pi processes, which is also
# why the audit itself must run on the host.
#
# Run from anywhere: bash tests/test-keys-audit.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_ROOT/scripts/keys-audit.mjs"

command -v node >/dev/null 2>&1 || { echo "SKIP  node not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if [[ "$2" == *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
hasnt() { if [[ "$2" != *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

# --- fixtures --------------------------------------------------------------
R="$TMP/root"
mkdir -p "$R/.pi-data/agent" "$R/.pi-data-pi-agent-alpha/agent" "$R/.pi-data-pi-agent-beta/agent"

cat > "$R/.pi-data/agent/creds.json" <<'EOF'
{
  "deepseek": { "type": "api_key", "key": "sk-deadbeefdeadbeefdeadbeef00e65a" },
  "opencode": { "type": "api_key", "key": "oc_sk_96eefe9127b2_Mc0zJjKT" }
}
EOF
cat > "$R/.pi-data/agent/models.json" <<'EOF'
{ "providers": { "deepseek": { "apiKey": "!cat /run/secrets/llm_key" } } }
EOF
cat > "$R/.pi-data/agent/settings.json" <<'EOF'
{ "defaultProvider": "deepseek", "defaultModel": "deepseek-flash" }
EOF
cat > "$R/.pi-data-pi-agent-alpha/agent/creds.json" <<'EOF'
{ "deepseek": { "type": "api_key", "key": "sk-oldoldoldoldoldoldoldold00d524" } }
EOF
cat > "$R/.pi-data-pi-agent-beta/agent/models.json" <<'EOF'
{ "providers": { "deepseek": { "apiKey": "!cat /run/secrets/llm_key" } } }
EOF

run_audit() { (cd "$R" && node "$AUDIT" --root "$R" --auth-name creds.json "$@" 2>&1); }

# --- 1. audit reports every instance and the effective source --------------
OUT="$(run_audit)"; RC=$?
eq "$RC" "0" "audit exits 0"
has ".pi-data-pi-agent-alpha" "$OUT" "audit lists instance alpha"
has ".pi-data-pi-agent-beta" "$OUT" "audit lists instance beta"
has "auth.json ****d524" "$OUT" "audit shows the auth.json key tail for alpha"
has "models.json !cat /run/secrets/llm_key" "$OUT" "audit shows the secret indirection"
has "shadows models.json secret" "$OUT" "audit flags auth.json shadowing the secret"
has "deepseek/deepseek-flash (default)" "$OUT" "audit marks the default provider/model"
has "make check-keys" "$OUT" "audit points at the verification command"

# --- 2. key values never leak --------------------------------------------
hasnt "deadbeefdeadbeefdeadbeef" "$OUT" "audit never prints a full key"
hasnt "oc_sk_96eefe9127b2" "$OUT" "audit masks non-auth.json keys too"

# --- 3. prune is a dry run by default ------------------------------------
BEFORE="$(cat "$R/.pi-data/agent/creds.json")"
OUT="$(run_audit --prune --provider deepseek)"; RC=$?
eq "$RC" "0" "prune dry-run exits 0"
has "would remove" "$OUT" "prune dry-run reports what it would do"
eq "$(cat "$R/.pi-data/agent/creds.json")" "$BEFORE" "prune dry-run changes nothing"
has "Re-run with --apply" "$OUT" "prune dry-run explains how to apply"

# --- 4. prune --apply removes only that provider -------------------------
OUT="$(run_audit --prune --provider deepseek --apply)"; RC=$?
eq "$RC" "0" "prune --apply exits 0"
hasnt "deepseek" "$(cat "$R/.pi-data/agent/creds.json")" "provider removed from the default dir"
has "opencode" "$(cat "$R/.pi-data/agent/creds.json")" "other providers are kept"
hasnt "deepseek" "$(cat "$R/.pi-data-pi-agent-alpha/agent/creds.json")" "provider removed from alpha"
eq "$(stat -c '%a' "$R/.pi-data/agent/creds.json")" "600" "rewritten credentials stay 600"
node -e "JSON.parse(require('fs').readFileSync('$R/.pi-data/agent/creds.json','utf8'))" \
    && ok "rewritten file is valid JSON" || no "rewritten file is not valid JSON"
has "opencode" "$(cat "$R/.pi-data/agent/creds.json")" "providers list preserved"
if compgen -G "$R/.pi-data/agent/creds.json.tmp.*" >/dev/null; then no "no temp files left"; else ok "no temp files left"; fi

# --- 5. audit after prune: no more shadowing ----------------------------
OUT="$(run_audit)"
hasnt "shadows" "$OUT" "after prune nothing shadows the secret"

# --- 6. pruning a provider that is not configured -----------------------
OUT="$(run_audit --prune --provider anthropic --apply)"; RC=$?
eq "$RC" "0" "prune of an absent provider exits 0"
has "not present in any" "$OUT" "prune says the provider is absent"

# --- 7. usage errors ----------------------------------------------------
OUT="$(run_audit --prune)"; RC=$?
eq "$RC" "2" "--prune without --provider is a usage error"
OUT="$(run_audit --apply)"; RC=$?
eq "$RC" "2" "--apply without --prune is a usage error"

# --- 8. unreadable credentials fail loudly, never silently --------------
UNREAD="$TMP/unreadable"
mkdir -p "$UNREAD/.pi-data/agent"
printf '{ "deepseek": { "type": "api_key", "key": "sk-x" } }' > "$UNREAD/.pi-data/agent/creds.json"
chmod 000 "$UNREAD/.pi-data/agent/creds.json"
OUT="$(node "$AUDIT" --root "$UNREAD" --auth-name creds.json 2>&1)"; RC=$?
eq "$RC" "1" "an unreadable auth file exits 1"
has "cannot read" "$OUT" "an unreadable auth file is reported"
hasnt "no credentials" "$OUT" "an unreadable file is not reported as having no credentials"
chmod 600 "$UNREAD/.pi-data/agent/creds.json"

# --- 9. wired into make -------------------------------------------------
if command -v make >/dev/null 2>&1; then
    has "keys-audit.mjs" "$(cd "$REPO_ROOT" && make -n keys-audit 2>/dev/null)" "make keys-audit runs the audit"
    has "keys-audit.mjs" "$(cd "$REPO_ROOT" && make -n keys-prune PROVIDER=deepseek 2>/dev/null)" "make keys-prune runs the audit"
else
    echo "SKIP  make targets (make is not installed here)"
fi

echo
echo "keys-audit tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
