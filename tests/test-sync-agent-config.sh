#!/usr/bin/env bash
#
# Tests for scripts/sync-agent-config.sh.
#
# Run from anywhere:  bash tests/test-sync-agent-config.sh
#
# Note: this container mounts /tmp with noexec, so the copied script is always
# invoked through `bash "$SYNC"`, never executed directly.
#
# The sandbox also blocks any path named `auth.json`, even under /tmp. These
# tests therefore exercise the sync engine with the non-credential files
# (models.json / settings.json). auth.json uses the same code branch and the
# same 600-mode handling, but can only be verified on a real host; see README
# "Syncing config to other instances".

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SRC="$REPO_ROOT/scripts/sync-agent-config.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

ROOT="$TMP/repo"
SYNC="$ROOT/scripts/sync-agent-config.sh"
run() { bash "$SYNC" "$@"; }

setup() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/scripts" "$ROOT/.pi-data/agent" "$ROOT/.pi-data-pi-agent-one/agent" "$ROOT/.pi-data-pi-agent-two/agent"
  cp "$SYNC_SRC" "$SYNC"
  printf '{"models":"source"}\n'  > "$ROOT/.pi-data/agent/models.json"
  printf '{"setting":"source"}\n' > "$ROOT/.pi-data/agent/settings.json"
  printf '{"models":"old"}\n'     > "$ROOT/.pi-data-pi-agent-one/agent/models.json"
  printf '{"setting":"old"}\n'    > "$ROOT/.pi-data-pi-agent-one/agent/settings.json"
}

# 1. dry-run writes nothing and reports changes
setup
out="$(run --dry-run 2>&1)"; rc=$?
eq "$rc" "0" "dry-run exits 0"
eq "$(cat "$ROOT/.pi-data-pi-agent-one/agent/models.json")" '{"models":"old"}' "dry-run does not modify target"
[ ! -f "$ROOT/.pi-data-pi-agent-one/agent/models.json.bak" ] && ok "dry-run creates no backup" || no "dry-run created backup"
echo "$out" | grep -q "DRY RUN" && ok "dry-run announces itself" || no "dry-run did not announce"

# 2. real run copies content, sets modes, backs up, preserves source
out="$(run 2>&1)"; rc=$?
eq "$rc" "0" "sync exits 0"
eq "$(cat "$ROOT/.pi-data-pi-agent-one/agent/models.json")" '{"models":"source"}' "models.json content copied"
eq "$(cat "$ROOT/.pi-data-pi-agent-one/agent/settings.json")" '{"setting":"source"}' "settings.json content copied"
eq "$(stat -c '%a' "$ROOT/.pi-data-pi-agent-one/agent/models.json")" "600" "models.json is 600"
eq "$(stat -c '%a' "$ROOT/.pi-data-pi-agent-one/agent/settings.json")" "644" "settings.json is 644"
eq "$(cat "$ROOT/.pi-data-pi-agent-one/agent/models.json.bak")" '{"models":"old"}' "models.json backed up"
eq "$(cat "$ROOT/.pi-data-pi-agent-one/agent/settings.json.bak")" '{"setting":"old"}' "settings.json backed up"
eq "$(cat "$ROOT/.pi-data/agent/models.json")" '{"models":"source"}' "source left intact"
if compgen -G "$ROOT/.pi-data-pi-agent-one/agent/*.tmp.*" >/dev/null; then no "temp files left behind"; else ok "no temp files left behind"; fi

# 3. second run is idempotent
out="$(run 2>&1)"; rc=$?
eq "$rc" "0" "idempotent run exits 0"
echo "$out" | grep -q "already up to date" && ok "idempotent run reports up-to-date" || no "idempotent run did not report up-to-date"

# 4. explicit --to only touches that instance
setup
run --to "$ROOT/.pi-data-pi-agent-two" >/dev/null 2>&1
eq "$(cat "$ROOT/.pi-data-pi-agent-two/agent/models.json")" '{"models":"source"}' "--to updates requested target"
eq "$(cat "$ROOT/.pi-data-pi-agent-one/agent/models.json")" '{"models":"old"}' "--to leaves other targets alone"

# 5. --no-backup
setup
run --no-backup >/dev/null 2>&1
[ ! -f "$ROOT/.pi-data-pi-agent-one/agent/models.json.bak" ] && ok "--no-backup creates no backup" || no "--no-backup created a backup"

# 6. no targets -> exit 1
setup
rm -rf "$ROOT"/.pi-data-pi-agent-*
run >/dev/null 2>&1; eq "$?" "1" "no targets exits 1"

# 7. empty source -> exit 1
setup
rm -f "$ROOT/.pi-data/agent/models.json" "$ROOT/.pi-data/agent/settings.json"
run >/dev/null 2>&1; eq "$?" "1" "empty source exits 1"

# 8. unknown option -> exit 1
setup
run --bogus >/dev/null 2>&1; eq "$?" "1" "unknown option exits 1"

# 9. missing source dir -> exit 1
setup
run --from "$TMP/does-not-exist" >/dev/null 2>&1; eq "$?" "1" "missing source exits 1"

echo
printf 'sync tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
