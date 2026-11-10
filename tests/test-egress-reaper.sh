#!/usr/bin/env bash
#
# Tests for scripts/reap-idle-egress.sh and its wiring into `make net-clean`.
#
# `docker compose run` leaves the egress sidecar (a declared dependency) running
# after the agent container exits. A lingering sidecar stays attached to its
# project's *_pi_network, so `docker network rm` cannot reclaim that subnet.
# The reaper removes only sidecars whose project has no live pi-agent container.
#
# Hermetic: docker is replaced by tests/helpers/fake-docker.sh via PI_DOCKER, so
# nothing real is touched. The `make -n` assertions are skipped when make is
# absent (e.g. running the suite inside the container).
#
# Run from anywhere: bash tests/test-egress-reaper.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAPER="$REPO_ROOT/scripts/reap-idle-egress.sh"
FAKE_DOCKER="$REPO_ROOT/tests/helpers/fake-docker.sh"
chmod +x "$REAPER" "$FAKE_DOCKER" 2>/dev/null || true

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

run_reaper() {
    PI_DOCKER="$FAKE_DOCKER" FAKE_DOCKER_LOG="$LOG" FAKE_DOCKER_STATE="$STATE" \
        bash "$REAPER" "$@" 2>&1
}

reset_state() {
    rm -f "$LOG"
    : > "$STATE/containers"
}

# --- 1. idle sidecar is reaped, live sidecar is kept -----------------------
reset_state
cat > "$STATE/containers" <<'EOF'
aaa111|proj-idle|egress
bbb222|proj-live|egress
ccc333|proj-live|pi-agent
EOF
OUT="$(run_reaper)"
LOG_AFTER="$(cat "$LOG" 2>/dev/null)"
has "removed idle egress: proj-idle" "$OUT" "idle sidecar is reported as removed"
has "rm aaa111" "$LOG_AFTER" "idle sidecar was removed"
hasnt "rm bbb222" "$LOG_AFTER" "live project's sidecar was kept"
hasnt "proj-live" "$OUT" "live project is not mentioned as removed"
if grep -q 'bbb222' "$STATE/containers"; then
    ok "live sidecar still registered"
else
    no "live sidecar still registered"
fi

# --- 2. --dry-run changes nothing -----------------------------------------
reset_state
printf 'ddd444|proj-idle|egress\n' > "$STATE/containers"
OUT="$(run_reaper --dry-run)"
has "would remove idle egress: proj-idle (ddd444)" "$OUT" "dry-run names the sidecar"
hasnt "rm ddd444" "$(cat "$LOG" 2>/dev/null)" "dry-run removes nothing"
has "ddd444" "$(cat "$STATE/containers")" "dry-run keeps the container"

# --- 3. nothing to do ------------------------------------------------------
reset_state
OUT="$(run_reaper)"
has "No egress sidecars running." "$OUT" "no sidecars: says so"

# --- 4. every sidecar belongs to a live session ---------------------------
reset_state
cat > "$STATE/containers" <<'EOF'
eee555|proj-a|egress
fff666|proj-a|pi-agent
EOF
OUT="$(run_reaper)"
has "All egress sidecars belong to live sessions." "$OUT" "all live: says so"
has "eee555" "$(cat "$STATE/containers")" "all live: nothing removed"

# --- 5. ignored when docker is not available ------------------------------
OUT="$(PI_DOCKER="$TMP/no-such-docker" bash "$REAPER" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "missing docker is not fatal" || no "missing docker is not fatal (rc=$RC)"
has "not found" "$OUT" "missing docker is explained"

# --- 6. make net-clean wiring --------------------------------------------
if command -v make >/dev/null 2>&1; then
    CLEAN="$(cd "$REPO_ROOT" && unset WIKI WIKI_ONLY PROJECT_NAME COMPOSE_PROJECT_NAME PI_DATA_DIR WORK_DIR; make -n net-clean 2>/dev/null)"
    has "reap-idle-egress.sh"        "$CLEAN" "make net-clean: reaps idle egress first"
    has "docker network rm"          "$CLEAN" "make net-clean: removes networks"
    has "pi_network"        "$CLEAN" "make net-clean: covers *_pi_network"
    has "pi_egress_upstream" "$CLEAN" "make net-clean: covers *_pi_egress_upstream"

    PICTL_CLEAN="$(cd "$REPO_ROOT" && bin/pictl net-clean --dry-run 2>&1)"
    has "reap-idle-egress.sh" "$PICTL_CLEAN" "pictl net-clean: dispatches to the reaper"
else
    echo "SKIP  make not installed — skipping net-clean wiring assertions"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
