#!/usr/bin/env bash
#
# Tests for scripts/prune-docker.sh and its wiring into make build/update/prune.
#
# Hermetic: docker is replaced by tests/helpers/fake-docker.sh via PI_DOCKER,
# which only records the calls, so nothing real is pruned.
#
# Run from anywhere: bash tests/test-docker-prune.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRUNE="$REPO_ROOT/scripts/prune-docker.sh"
FAKE_DOCKER="$REPO_ROOT/tests/helpers/fake-docker.sh"
chmod +x "$PRUNE" "$FAKE_DOCKER" 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
LOG="$TMP/log"
mkdir -p "$STATE"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

run_prune() {
    PI_DOCKER="$FAKE_DOCKER" FAKE_DOCKER_LOG="$LOG" FAKE_DOCKER_STATE="$STATE" \
        bash "$PRUNE" "$@" 2>&1
}

reset_state() {
    rm -f "$LOG"
    : > "$STATE/containers"
}

# --- 1. default: images and the whole build cache -------------------------
reset_state
OUT="$(run_prune)"; RC=$?
LOG_AFTER="$(cat "$LOG" 2>/dev/null)"
eq "$RC" "0" "default prune exits 0"
has "image prune -f" "$LOG_AFTER" "default prune removes dangling images"
has "builder prune -f" "$LOG_AFTER" "default prune removes build cache"
hasnt "until=" "$LOG_AFTER" "default cache prune has no age filter"

# --- 2. --images-only leaves the cache alone ------------------------------
reset_state
OUT="$(run_prune --images-only)"; RC=$?
LOG_AFTER="$(cat "$LOG" 2>/dev/null)"
eq "$RC" "0" "--images-only exits 0"
has "image prune -f" "$LOG_AFTER" "--images-only removes dangling images"
hasnt "builder prune" "$LOG_AFTER" "--images-only keeps build cache"

# --- 3. --cache-age is passed as a Docker filter --------------------------
reset_state
OUT="$(run_prune --cache-age 24h)"; RC=$?
LOG_AFTER="$(cat "$LOG" 2>/dev/null)"
eq "$RC" "0" "--cache-age exits 0"
has "builder prune -f --filter until=24h" "$LOG_AFTER" "--cache-age limits the cache prune"

reset_state
OUT="$(run_prune --cache-age=168h)"; RC=$?
LOG_AFTER="$(cat "$LOG" 2>/dev/null)"
has "builder prune -f --filter until=168h" "$LOG_AFTER" "--cache-age=VALUE is accepted"

# --- 4. --dry-run changes nothing ----------------------------------------
reset_state
OUT="$(run_prune --dry-run)"; RC=$?
eq "$RC" "0" "--dry-run exits 0"
has "would run:" "$OUT" "dry-run reports what it would do"
has "image prune -f" "$OUT" "dry-run reports the image prune"
has "builder prune -f" "$OUT" "dry-run reports the cache prune"
if [ -s "$LOG" ]; then no "dry-run invokes no docker commands"; else ok "dry-run invokes no docker commands"; fi

# --- 5. missing docker is not fatal --------------------------------------
OUT="$(PI_DOCKER="$TMP/no-such-docker" bash "$PRUNE" 2>&1)"; RC=$?
eq "$RC" "0" "missing docker is not fatal"
has "not found" "$OUT" "missing docker is explained"

# --- 6. bad arguments fail with usage ------------------------------------
OUT="$(run_prune --bogus 2>&1)"; RC=$?
eq "$RC" "2" "unknown argument exits 2"
has "usage:" "$OUT" "unknown argument prints usage"

OUT="$(run_prune --cache-age 2>&1)"; RC=$?
eq "$RC" "2" "missing cache age exits 2"

# --- 7. make wiring -------------------------------------------------------
if command -v make >/dev/null 2>&1; then
    makefile_run() { (cd "$REPO_ROOT" && unset WIKI WIKI_ONLY PROJECT_NAME COMPOSE_PROJECT_NAME PI_DATA_DIR WORK_DIR; make -n "$@" 2>/dev/null); }

    PRUNE_CMD="$(makefile_run prune)"
    has "prune-docker.sh" "$PRUNE_CMD" "make prune runs the prune script"

    BUILD_CMD="$(makefile_run build)"
    has "prune-docker.sh --images-only" "$BUILD_CMD" "make build prunes dangling images"

    UPDATE_CMD="$(makefile_run update)"
    has "prune-docker.sh" "$UPDATE_CMD" "make update prunes after building"
    hasnt "--images-only" "$UPDATE_CMD" "make update also prunes build cache"

    NOAUTO="$(makefile_run update AUTO_PRUNE=0)"
    hasnt "prune-docker.sh" "$NOAUTO" "AUTO_PRUNE=0 disables update cleanup"

    HELP="$(makefile_run help)"
    has "make prune" "$HELP" "make help lists prune"
else
    echo "SKIP  make not installed — skipping make wiring assertions"
fi

printf '\ndocker prune tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
