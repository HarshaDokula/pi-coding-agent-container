#!/usr/bin/env bash
#
# Tests for a wiki session with no project attached:
# `make run WIKI_ONLY=true` and `pictl wiki` (== `pictl -w --no-workspace`).
#
# The container always needs something at /workspace, so "no project" means a
# dedicated empty scratch dir (LLM_WIKI_SESSION_DIR) instead of a checkout. The
# shared vault (LLM_WIKI_DIR) is unchanged, so the KB works with nothing mounted.
#
# No Docker or network required - everything is observed with `make -n` and
# `pictl --dry-run`.
#
# Run from anywhere: bash tests/test-wiki-standalone.sh

set -u

# These assertions drive `make`; skip cleanly where make is not installed
# (e.g. running the tests inside the container instead of on the host).
command -v make >/dev/null 2>&1 || { echo "SKIP  make not installed — run this suite on the host"; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Isolate from the parent Makefile's exported instance config, which would
# otherwise shadow the values derived here.
unset PI_DATA_DIR PROJECT_NAME COMPOSE_PROJECT_NAME WIKI WIKI_ONLY WORK_DIR \
      LLM_WIKI_SESSION_DIR DETACHED

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
SCRATCH="$ROOT/wiki-scratch"   # deliberately missing: make must create it
PROJECT="$ROOT/project"
mkdir -p "$PROJECT"
PROJECT="$(cd "$PROJECT" && pwd)"

# --- make: the wiki loads with no project ----------------------------------
MAKE_WIKI_ONLY="$(make -n run WIKI_ONLY=true LLM_WIKI_SESSION_DIR="$SCRATCH" 2>/dev/null)"
has   "docker-compose.wiki.yml" "$MAKE_WIKI_ONLY" "WIKI_ONLY=true: wiki overlay used"
has   "/opt/pi-llm-wiki/node_modules/@zosmaai/pi-llm-wiki" "$MAKE_WIKI_ONLY" \
      "WIKI_ONLY=true: pi -e loads the vendored package"
has   "WORK_DIR=$SCRATCH" "$MAKE_WIKI_ONLY" "WIKI_ONLY=true: /workspace is the session dir"
hasnt "WORK_DIR=$REPO_ROOT/workspace" "$MAKE_WIKI_ONLY" "WIKI_ONLY=true: repo workspace not mounted"
hasnt "$PROJECT" "$MAKE_WIKI_ONLY" "WIKI_ONLY=true: no project path leaks in"
if [[ -d "$SCRATCH" ]]; then
  ok "WIKI_ONLY=true: session dir created on the host"
else
  no "WIKI_ONLY=true: session dir created on the host"
fi

# --- make: a stable, isolated instance of its own ---------------------------
has   "PI_DATA_DIR=$REPO_ROOT/.pi-data-pi-agent-wiki" "$MAKE_WIKI_ONLY" \
      "WIKI_ONLY=true: own instance data dir"
MAKE_NAMED="$(make -n run WIKI_ONLY=true PROJECT_NAME=custom LLM_WIKI_SESSION_DIR="$SCRATCH" 2>/dev/null)"
has   "PI_DATA_DIR=$REPO_ROOT/.pi-data-custom" "$MAKE_NAMED" "WIKI_ONLY=true: explicit PROJECT_NAME wins"
hasnt ".pi-data-pi-agent-wiki"                "$MAKE_NAMED" "WIKI_ONLY=true: default instance not used"

# --- make: default location is $HOME/pi-wiki -------------------------------
FAKE_HOME="$ROOT/home"
MAKE_HOME="$(make -n run WIKI_ONLY=true HOME="$FAKE_HOME" 2>/dev/null)"
has "WORK_DIR=$FAKE_HOME/pi-wiki" "$MAKE_HOME" "WIKI_ONLY=true: defaults to \$HOME/pi-wiki"

# --- make: a project path contradicts "no project" -------------------------
if make -n run WIKI_ONLY=true WORK_DIR="$PROJECT" >/dev/null 2>"$ROOT/err"; then
  no "WIKI_ONLY=true + WORK_DIR: rejected"
else
  ok "WIKI_ONLY=true + WORK_DIR: rejected"
fi
has "runs without a project" "$(cat "$ROOT/err" 2>/dev/null)" \
    "WIKI_ONLY=true + WORK_DIR: explains the conflict"

# --- make: WIKI_ONLY cannot be half-on -------------------------------------
MAKE_CONFLICT="$(make -n run WIKI_ONLY=true WIKI=false LLM_WIKI_SESSION_DIR="$SCRATCH" 2>/dev/null)"
has "docker-compose.wiki.yml" "$MAKE_CONFLICT" "WIKI_ONLY=true WIKI=false: wiki stays on"

# --- make: composes with the other targets ---------------------------------
MAKE_SHELL="$(make -n shell WIKI_ONLY=true LLM_WIKI_SESSION_DIR="$SCRATCH" 2>/dev/null)"
has   "WORK_DIR=$SCRATCH"     "$MAKE_SHELL" "make shell: uses the session dir"
has   "docker-compose.wiki.yml" "$MAKE_SHELL" "make shell: keeps the wiki overlay"

# --- make: a plain run is untouched ---------------------------------------
MAKE_PLAIN="$(make -n run WORK_DIR="$PROJECT" 2>/dev/null)"
has   "WORK_DIR=$PROJECT"       "$MAKE_PLAIN" "plain run: keeps the project"
hasnt "docker-compose.wiki.yml" "$MAKE_PLAIN" "plain run: no wiki overlay"
hasnt "WIKI_ONLY"               "$MAKE_PLAIN" "plain run: no WIKI_ONLY"

# --- pictl: `pictl wiki` ---------------------------------------------------
PICTL_WIKI="$(bin/pictl wiki --dry-run 2>/dev/null)"
has   "make run"       "$PICTL_WIKI" "pictl wiki: runs the TUI target"
has   "WIKI_ONLY=true" "$PICTL_WIKI" "pictl wiki: passes WIKI_ONLY=true"
hasnt "WORK_DIR="      "$PICTL_WIKI" "pictl wiki: passes no workspace"

PICTL_LONG="$(bin/pictl -w --no-workspace --dry-run 2>/dev/null)"
[ "$PICTL_LONG" = "$PICTL_WIKI" ] \
  && ok "pictl -w --no-workspace: same as pictl wiki" \
  || no "pictl -w --no-workspace: same as pictl wiki"

# --- pictl: composes with flags -------------------------------------------
PICTL_BG="$(bin/pictl wiki -b --dry-run 2>/dev/null)"
has "tmux new-session" "$PICTL_BG" "pictl wiki -b: starts a background session"
has "-s pi-wiki"       "$PICTL_BG" "pictl wiki -b: stable session name"
PICTL_ARGS="$(bin/pictl wiki -a "ingest these notes" --dry-run 2>/dev/null)"
has "make run-args"    "$PICTL_ARGS" "pictl wiki -a: one-off prompt target"
has "WIKI_ONLY=true"   "$PICTL_ARGS" "pictl wiki -a: still no project"
PICTL_NAMED="$(bin/pictl wiki -p svc --dry-run 2>/dev/null)"
has "PROJECT_NAME=svc" "$PICTL_NAMED" "pictl wiki -p: explicit project name"

# --- pictl: background session is really started (fake tmux) --------------
FAKE_TMUX="$REPO_ROOT/tests/helpers/fake-tmux.sh"
STATE="$ROOT/state"
LOG="$ROOT/tmux.log"
mkdir -p "$STATE"
run_pictl() {
  PATH="$REPO_ROOT/tests/helpers/bin:$PATH" \
  PI_TMUX_BIN="$FAKE_TMUX" FAKE_TMUX_LOG="$LOG" FAKE_TMUX_STATE="$STATE" \
  bin/pictl "$@" 2>&1
}
OUT="$(run_pictl wiki -b)"; RC=$?
[ "$RC" -eq 0 ] && ok "pictl wiki -b: starts" || no "pictl wiki -b: starts (rc=$RC)"
TMUX_LOG="$(cat "$LOG" 2>/dev/null)"
has "-s pi-wiki"                "$TMUX_LOG" "pictl wiki -b: session is pi-wiki"
has "make run WIKI_ONLY=true"    "$TMUX_LOG" "pictl wiki -b: runs the standalone make target"
has "(no project)"               "$TMUX_LOG" "pictl wiki -b: ls shows it is not on a project"
has "pictl attach wiki"          "$OUT"      "pictl wiki -b: says how to attach"

# Duplicate session: the suggested fix must stay in wiki mode.
: > "$STATE/pi-wiki.exists"
OUT="$(run_pictl wiki -b)"; RC=$?
[ "$RC" -eq 1 ] && ok "pictl wiki -b duplicate: exits 1" || no "pictl wiki -b duplicate: exits 1 (rc=$RC)"
has "pictl wiki -b" "$OUT" "pictl wiki -b duplicate: suggests pictl wiki -b"

# --- pictl: project path is refused, not silently dropped ------------------
if bin/pictl wiki --dry-run "$PROJECT" >/dev/null 2>"$ROOT/perr"; then
  no "pictl wiki <dir>: rejected"
else
  ok "pictl wiki <dir>: rejected"
fi
has "runs without a project" "$(cat "$ROOT/perr" 2>/dev/null)" \
    "pictl wiki <dir>: explains the conflict"
has "pictl -w" "$(cat "$ROOT/perr" 2>/dev/null)" \
    "pictl wiki <dir>: points at the project form"

# --- pictl: a wiki session on a project is unchanged ----------------------
PICTL_PROJ="$(bin/pictl -w --dry-run "$PROJECT" 2>/dev/null)"
has   "WORK_DIR=$PROJECT" "$PICTL_PROJ" "pictl -w <dir>: keeps the workspace"
has   "WIKI=true"         "$PICTL_PROJ" "pictl -w <dir>: wiki on"
hasnt "WIKI_ONLY"         "$PICTL_PROJ" "pictl -w <dir>: not standalone"

# --- pictl: help documents the mode ---------------------------------------
PICTL_HELP="$(bin/pictl -h 2>/dev/null)"
has "pictl wiki"       "$PICTL_HELP" "pictl -h: documents 'pictl wiki'"
has "--no-workspace"   "$PICTL_HELP" "pictl -h: documents --no-workspace"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
