#!/usr/bin/env bash
#
# Tests for pictl background sessions (feat/pictl-sessions).
#
# Hermetic: tmux is replaced by tests/helpers/fake-tmux.sh via PI_TMUX_BIN, so no
# real sessions are created. The fake records its argv in $FAKE_TMUX_LOG and
# answers has-session / list-sessions from files the test controls.
#
# Run from anywhere: bash tests/test-pictl-sessions.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICTL="$REPO_ROOT/bin/pictl"
FAKE_TMUX="$REPO_ROOT/tests/helpers/fake-tmux.sh"

command -v "$FAKE_TMUX" >/dev/null 2>&1 || chmod +x "$FAKE_TMUX" 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work/app-a" "$TMP/work/app-b" "$TMP/state"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if [[ "$2" == *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
hasnt() { if [[ "$2" != *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

# docker is stubbed too: pictl checks for it before it gets to tmux.
run_pictl() {
  PATH="$REPO_ROOT/tests/helpers/bin:$PATH" \
  PI_TMUX_BIN="$FAKE_TMUX" FAKE_TMUX_LOG="$TMP/log" FAKE_TMUX_STATE="$TMP/state" \
  "$PICTL" "$@" 2>&1
}

# --- 1. --dry-run shows the tmux command without running anything ---------
OUT="$("$PICTL" --dry-run -b "$TMP/work/app-a" 2>&1)"
has "tmux new-session -d -s" "$OUT" "--dry-run shows the tmux invocation"
has "pi-app-a" "$OUT" "the session name is derived from the workspace basename"
hasnt "pictl: running in background" "$OUT" "--dry-run does not actually start it"

OUT="$("$PICTL" --dry-run "$TMP/work/app-a" 2>&1)"
hasnt "new-session" "$OUT" "without -b there is no tmux invocation"

# --- 2. -b starts a detached session with the make command ---------------
rm -f "$TMP/log"
OUT="$(run_pictl -b "$TMP/work/app-a")"; RC=$?
eq "$RC" "0" "pictl -b exits 0"
LOG="$(cat "$TMP/log" 2>/dev/null)"
has "new-session" "$LOG" "tmux new-session was invoked"
has "-d" "$LOG" "the session is detached"
has "-s pi-app-a" "$LOG" "the session name is pi-<basename>"
has "make run WORK_DIR=" "$LOG" "the session runs the make command"
has "attach:" "$OUT" "the user is told how to attach"
has "pictl ls" "$OUT" "the user is told how to list"

# --- 3. session name is sanitised ---------------------------------------
OUT="$(run_pictl -b "$TMP/work/app-b")"
has "-s pi-app-b" "$(cat "$TMP/log")" "a second workspace gets its own session name"

# --- 4. an existing session is not clobbered ---------------------------
touch "$TMP/state/pi-app-a.exists"
OUT="$(run_pictl -b "$TMP/work/app-a")"; RC=$?
eq "$RC" "1" "starting a duplicate session exits 1"
has "already exists" "$OUT" "the duplicate is explained"
has "pictl attach app-a" "$OUT" "the fix is suggested"

# --- 5. ls lists pi-* sessions only ------------------------------------
printf 'pi-app-a\npi-app-b\nother-thing\n' > "$TMP/state/sessions"
OUT="$(run_pictl ls)"
has "pi-app-a" "$OUT" "ls shows pi-app-a"
has "pi-app-b" "$OUT" "ls shows pi-app-b"
hasnt "other-thing" "$OUT" "ls hides non-pi sessions"
has "WORKSPACE" "$OUT" "ls shows the workspace column"

OUT="$(rm -f "$TMP/state/sessions"; run_pictl ls)"
has "no background sessions" "$OUT" "ls explains when nothing is running"

# --- 6. attach: single session attaches, several list, none fails ------
printf 'pi-app-a\n' > "$TMP/state/sessions"
rm -f "$TMP/log"
OUT="$(run_pictl attach)"; RC=$?
eq "$RC" "0" "attach with one session succeeds"
has "attach-session -t pi-app-a" "$(cat "$TMP/log")" "attach targets the only session"

printf 'pi-app-a\npi-app-b\n' > "$TMP/state/sessions"
OUT="$(run_pictl attach)"; RC=$?
eq "$RC" "1" "attach with several sessions asks which one"
has "pictl attach pi-app-a" "$OUT" "the choices are printed"

OUT="$(run_pictl attach app-b)"; RC=$?
has "attach-session -t pi-app-b" "$(cat "$TMP/log")" "attach accepts a short name"

OUT="$(rm -f "$TMP/state/sessions"; run_pictl attach)"; RC=$?
eq "$RC" "1" "attach with no session fails"
has "no background sessions" "$OUT" "attach explains there is nothing to attach"

# --- 7. stop kills the session ----------------------------------------
printf 'pi-app-a\n' > "$TMP/state/sessions"
rm -f "$TMP/log"
OUT="$(run_pictl stop app-a)"; RC=$?
eq "$RC" "0" "stop exits 0"
has "kill-session -t pi-app-a" "$(cat "$TMP/log")" "stop kills the right session"
has "container exits with it" "$OUT" "stop explains the container follows"

OUT="$(rm -f "$TMP/state/sessions"; run_pictl stop app-a)"; RC=$?
eq "$RC" "1" "stopping a missing session exits 1"

OUT="$(run_pictl stop)"; RC=$?
eq "$RC" "1" "stop without a name is a usage error"
has "usage: pictl stop" "$OUT" "the usage line is printed"

# --- 8. missing tmux is reported, not a stack trace -------------------
OUT="$(PATH="$REPO_ROOT/tests/helpers/bin:$PATH" PI_TMUX_BIN="$TMP/definitely-not-tmux" "$PICTL" -b "$TMP/work/app-a" 2>&1)"; RC=$?
eq "$RC" "1" "missing tmux exits 1"
has "tmux not found" "$OUT" "missing tmux is explained"
has "install" "$OUT" "the fix is suggested"

# --- 9. sessions are documented ---------------------------------------
HELP="$("$PICTL" -h 2>&1)"
has "--background" "$HELP" "-h documents --background"
has "pictl attach" "$HELP" "-h documents attach"

echo
echo "pictl sessions tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
