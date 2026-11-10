#!/usr/bin/env bash
#
# Tests for scripts/seed-agent-config.sh.
#
# A fresh per-project instance must inherit the SAME provider configuration as
# the canonical .pi-data, including models.json - the file that points
# `apiKey` at `/run/secrets/llm_key` (`!cat /run/secrets/llm_key`). Without it a
# new instance resolves the key from auth.json only and can silently use a
# different (stale) key than every existing instance, which surfaces as a
# provider error such as 403 "Model access is disabled" only in the new one.
#
# This sandbox blocks files named auth.json, so the tests drive the "target has
# no auth yet -> seed" branch (the one that matters here) and use models.json /
# settings.json / models-store.json for the assertions.
#
# Run from anywhere: bash tests/test-seed-agent-config.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_SRC="$REPO_ROOT/scripts/seed-agent-config.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/repo"
SEED="$ROOT/scripts/seed-agent-config.sh"
TARGET="$ROOT/.pi-data-pi-agent-wiki"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }

setup() {
    rm -rf "$ROOT"
    mkdir -p "$ROOT/scripts" "$ROOT/.pi-data/agent" "$TARGET"
    cp "$SEED_SRC" "$SEED"
    printf '{\n  "providers": {\n    "deepseek": {\n      "apiKey": "!cat /run/secrets/llm_key"\n    }\n  }\n}\n' \
        > "$ROOT/.pi-data/agent/models.json"
    printf '{\n  "defaultProvider": "deepseek",\n  "defaultModel": "deepseek-flash"\n}\n' \
        > "$ROOT/.pi-data/agent/settings.json"
    printf '{"deepseek":{"models":[]}}\n' > "$ROOT/.pi-data/agent/models-store.json"
}
run_seed() { (cd "$ROOT" && bash "$SEED" "$TARGET" ".pi-data"); }

# --- 1. a fresh instance gets models.json ---------------------------------
setup
OUT="$(run_seed)"; RC=$?
eq "$RC" "0" "seeding exits 0"
has "$TARGET" "$OUT" "the seed target is announced"
if [ -f "$TARGET/agent/models.json" ]; then
    ok "fresh instance receives models.json"
else
    no "fresh instance receives models.json"
fi
if cmp -s "$ROOT/.pi-data/agent/models.json" "$TARGET/agent/models.json"; then
    ok "models.json is copied verbatim"
else
    no "models.json is copied verbatim"
fi
has '!cat /run/secrets/llm_key' "$(cat "$TARGET/agent/models.json" 2>/dev/null)" \
    "the secret-based key reference survives seeding"
[ -f "$TARGET/agent/settings.json" ] && ok "settings.json still seeded" || no "settings.json still seeded"
[ -f "$TARGET/agent/models-store.json" ] && ok "models-store.json still seeded" || no "models-store.json still seeded"

# --- 2. the canonical .pi-data is never modified --------------------------
BEFORE="$(cksum "$ROOT/.pi-data/agent/models.json")"
run_seed >/dev/null 2>&1
eq "$BEFORE" "$(cksum "$ROOT/.pi-data/agent/models.json")" "seeding does not modify .pi-data"

# --- 3. a stale target key is replaced by the canonical one ---------------
printf '{"providers":{"deepseek":{"apiKey":"!cat /stale/key"}}}\n' > "$TARGET/agent/models.json"
run_seed >/dev/null 2>&1
has 'run/secrets/llm_key' "$(cat "$TARGET/agent/models.json")" \
    "an unauthenticated instance is re-seeded with the canonical models.json"
hasnt_ok=1
printf '%s' "$(cat "$TARGET/agent/models.json")" | grep -qF '/stale/key' && hasnt_ok=0
[ "$hasnt_ok" -eq 1 ] && ok "the stale key reference is gone" || no "the stale key reference is gone"

# --- 4. no models.json in .pi-data: seeding still works -------------------
setup
rm -f "$ROOT/.pi-data/agent/models.json"
RC=0; run_seed >/dev/null 2>&1 || RC=$?
eq "$RC" "0" "seeding tolerates a missing models.json"
[ ! -f "$TARGET/agent/models.json" ] && ok "no models.json is invented" || no "no models.json is invented"

# --- 5. skills/extensions are not clobbered ------------------------------
setup
mkdir -p "$ROOT/.pi-data/agent/skills" "$TARGET/agent/skills"
printf 'canonical\n' > "$ROOT/.pi-data/agent/skills/one.md"
printf 'mine\n'      > "$TARGET/agent/skills/one.md"
run_seed >/dev/null 2>&1
eq "mine" "$(cat "$TARGET/agent/skills/one.md")" "an existing skills dir is left alone"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
