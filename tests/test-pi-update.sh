#!/usr/bin/env bash
#
# Tests for the pi upgrade path: the pinned version is consistent across the
# build files, the container does not advertise an update it cannot install,
# and `make update` resolves/builds/pins the latest release safely.
#
# Hermetic: release metadata is a local file:// fixture, and `make` is only
# inspected with -n (nothing is built, no network is used).
#
# Run from anywhere: bash tests/test-pi-update.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

UPDATE_SCRIPT="scripts/update-pi-version.sh"
chmod +x "$UPDATE_SCRIPT" 2>/dev/null || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }
line_of() { printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1; }

DOCKERFILE="$(cat Dockerfile 2>/dev/null)"
COMPOSE="$(cat docker-compose.yml 2>/dev/null)"
MAKEFILE="$(cat Makefile 2>/dev/null)"
ENV_EXAMPLE="$(cat .env.example 2>/dev/null)"

# --- 1. the pinned version is consistent everywhere --------------------------
DOCKERFILE_VER="$(printf '%s\n' "$DOCKERFILE" | sed -n 's/^ARG PI_VERSION=//p' | head -1)"
COMPOSE_VER="$(printf '%s\n' "$COMPOSE" | sed -n 's/.*PI_VERSION: ${PI_VERSION:-\([^}]*\)}.*/\1/p' | head -1)"
MAKE_VER="$(printf '%s\n' "$MAKEFILE" | sed -n 's/^PI_PINNED_DEFAULT := //p' | head -1)"
ENV_VER="$(printf '%s\n' "$ENV_EXAMPLE" | sed -n 's/^# PI_VERSION=//p' | head -1)"

if printf '%s' "$DOCKERFILE_VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "Dockerfile pins a concrete PI_VERSION ($DOCKERFILE_VER)"
else
    no "Dockerfile pins a concrete PI_VERSION (got '$DOCKERFILE_VER')"
fi
eq "$COMPOSE_VER" "$DOCKERFILE_VER" "compose default matches the Dockerfile pin"
eq "$MAKE_VER" "$DOCKERFILE_VER" "Makefile default matches the Dockerfile pin"
eq "$ENV_VER" "$DOCKERFILE_VER" ".env.example matches the Dockerfile pin"

# --- 2. the container does not advertise pi self-updates --------------------
has "ENV PI_SKIP_VERSION_CHECK=1" "$DOCKERFILE" "image disables the pi self-update notice"
has 'ARG PI_VERSION=' "$DOCKERFILE" "image still pins pi at build time"
has 'pi --version | grep -qx' "$DOCKERFILE" "build asserts the pinned version"

# --- 3. make wiring ---------------------------------------------------------
if command -v make >/dev/null 2>&1; then
    # Isolate from the caller's .env-derived environment, like the other suites.
    makefile_run() { (cd "$REPO_ROOT" && unset WIKI WIKI_ONLY PROJECT_NAME COMPOSE_PROJECT_NAME PI_DATA_DIR WORK_DIR PI_VERSION; make -n "$@" 2>/dev/null); }

    UPDATE_CMD="$(makefile_run update)"
    has "update-pi-version.sh --fallback \"$DOCKERFILE_VER\"" "$UPDATE_CMD" \
        "make update resolves latest with the pin as fallback"
    hasnt "--version" "$UPDATE_CMD" "make update asks for latest by default"
    has "--no-cache --build-arg PI_VERSION" "$UPDATE_CMD" \
        "make update rebuilds without cache at the resolved version"

    RES_LINE="$(line_of "$UPDATE_CMD" "update-pi-version.sh --fallback")"
    BUILD_LINE="$(line_of "$UPDATE_CMD" "docker compose build")"
    SAVE_LINE="$(line_of "$UPDATE_CMD" "update-pi-version.sh --save")"
    if [[ -n "$RES_LINE" && -n "$BUILD_LINE" && -n "$SAVE_LINE" \
          && "$RES_LINE" -lt "$BUILD_LINE" && "$BUILD_LINE" -lt "$SAVE_LINE" ]]; then
        ok "make update records the pin only after a successful build"
    else
        no "make update records the pin only after a successful build (resolve=$RES_LINE build=$BUILD_LINE save=$SAVE_LINE)"
    fi

    PINNED_UPDATE="$(makefile_run update PI_VERSION=9.9.9)"
    has 'update-pi-version.sh --version "9.9.9"' "$PINNED_UPDATE" \
        "make update PI_VERSION=x pins that release instead of latest"
    hasnt "--fallback" "$PINNED_UPDATE" "an explicit pin does not use the latest lookup"

    # An exported PI_VERSION must not defeat "make update means update".
    ENVCMD="$(cd "$REPO_ROOT" && unset WIKI WIKI_ONLY PROJECT_NAME COMPOSE_PROJECT_NAME PI_DATA_DIR WORK_DIR; PI_VERSION=8.8.8 make -n update 2>/dev/null)"
    hasnt "--version" "$ENVCMD" "an exported PI_VERSION does not pin a make update"
    has 'update-pi-version.sh --fallback "8.8.8"' "$ENVCMD" \
        "an exported PI_VERSION is only the offline fallback"

    BUILD_CMD="$(makefile_run build)"
    has "--build-arg PI_VERSION=$DOCKERFILE_VER" "$BUILD_CMD" \
        "make build passes the pinned version explicitly"
    hasnt "update-pi-version" "$BUILD_CMD" "make build does not look up or change pi"

    HELP="$(makefile_run help)"
    has "make update" "$HELP" "make help lists update"
    has "upgrade pi to the latest release" "$HELP" "make help says update upgrades pi"
    has "make build" "$HELP" "make help lists build"
    hasnt "update-pi" "$HELP" "make help has no second update command"
else
    echo "SKIP  make not installed — skipping make wiring assertions"
fi

# --- 4. the resolver -------------------------------------------------------
LATEST="$TMP/latest.json"
ENVF="$TMP/env"
PKG="@earendil-works/pi-coding-agent"

run_resolver() {
    PI_ENV_FILE="$ENVF" PI_LATEST_VERSION_URL="$1" bash "$UPDATE_SCRIPT" "${@:2}" 2>"$TMP/stderr"
}

reset_env() {
    cat > "$ENVF" <<'EOF'
# PI_VERSION=1.0.0
GIT_NAME=Test User
GIT_EMAIL=test@example.com
PI_VERSION=1.4.0
EOF
}

valid_metadata() {
    printf '{"ok":true,"version":"%s","packageName":"%s"}\n' "$1" "$PKG" > "$LATEST"
}

# 4a. resolving prints the version and does not touch .env.
reset_env
valid_metadata "9.9.9"
OUT="$(run_resolver "file://$LATEST")"; RC=$?
eq "$RC" "0" "resolver succeeds with valid metadata"
eq "$OUT" "9.9.9" "resolver prints the resolved version"
eq "$(grep '^PI_VERSION=' "$ENVF")" "PI_VERSION=1.4.0" "resolving does not rewrite .env"

# 4b. --save records the pin.
OUT="$(run_resolver "file://$TMP/unused.json" --save 9.9.9)"; RC=$?
eq "$RC" "0" "--save succeeds for a valid version"
eq "$(grep '^PI_VERSION=' "$ENVF")" "PI_VERSION=9.9.9" "--save updates the active pin"
eq "$(grep -c '^PI_VERSION=' "$ENVF")" "1" "--save leaves exactly one active pin"
has "# PI_VERSION=1.0.0" "$(cat "$ENVF")" "--save keeps the commented example"
has "GIT_NAME=Test User" "$(cat "$ENVF")" "--save keeps unrelated lines"

# 4c. --save is idempotent.
OUT="$(run_resolver "file://$TMP/unused.json" --save 9.9.9)"; RC=$?
eq "$RC" "0" "--save is idempotent"
eq "$(grep -c '^PI_VERSION=' "$ENVF")" "1" "idempotent save does not duplicate the pin"
has "already pinned to 9.9.9" "$(cat "$TMP/stderr")" "idempotent save says the pin is current"

# 4d. --save preserves an export-style line.
cat > "$ENVF" <<'EOF'
export PI_VERSION=1.4.0
GIT_NAME=Test User
EOF
OUT="$(run_resolver "file://$TMP/unused.json" --save 9.9.9)"; RC=$?
eq "$RC" "0" "--save accepts an export-style pin"
eq "$(grep -E '^(export )?PI_VERSION=' "$ENVF")" "export PI_VERSION=9.9.9" \
    "--save preserves the export style"
eq "$(grep -cE '^(export )?PI_VERSION=' "$ENVF")" "1" "--save removes the old export line"

# 4e. --save follows a symlinked .env instead of replacing the link.
printf 'PI_VERSION=1.4.0\n' > "$TMP/real.env"
ln -sf "real.env" "$TMP/link.env"
PI_ENV_FILE="$TMP/link.env" bash "$UPDATE_SCRIPT" --save 9.9.9 >/dev/null 2>&1; RC=$?
eq "$RC" "0" "--save succeeds through a symlink"
if [[ -L "$TMP/link.env" ]]; then ok "--save keeps the .env symlink"; else no "--save replaced the .env symlink"; fi
eq "$(grep '^PI_VERSION=' "$TMP/real.env")" "PI_VERSION=9.9.9" "--save writes to the symlink target"

# 4f. -save refuses an invalid version.
reset_env
OUT="$(run_resolver "file://$TMP/unused.json" --save latest)"; RC=$?
eq "$RC" "1" "--save rejects a non-version value"
eq "$(grep '^PI_VERSION=' "$ENVF")" "PI_VERSION=1.4.0" "a rejected --save leaves .env untouched"

# 4g. --version prints without network access.
reset_env
OUT="$(run_resolver "file://$TMP/never-fetched.json" --version 8.8.8)"; RC=$?
eq "$RC" "0" "--version succeeds without fetching metadata"
eq "$OUT" "8.8.8" "--version prints the pinned release"
eq "$(grep '^PI_VERSION=' "$ENVF")" "PI_VERSION=1.4.0" "--version does not rewrite .env"

OUT="$(run_resolver "file://$TMP/never-fetched.json" --version=7.7.7)"; RC=$?
eq "$RC" "0" "--version=VALUE is accepted"
eq "$OUT" "7.7.7" "--version=VALUE prints the value"

OUT="$(run_resolver "file://$TMP/never-fetched.json" --version "")"; RC=$?
eq "$RC" "2" "an empty --version is a usage error"

OUT="$(run_resolver "file://$TMP/never-fetched.json" --version 2>&1)"; RC=$?
eq "$RC" "2" "--version without a value exits 2"

# 4h. --fallback keeps the current pin when metadata is unavailable.
reset_env
OUT="$(run_resolver "file://$TMP/does-not-exist.json" --fallback 7.7.7)"; RC=$?
eq "$RC" "0" "--fallback succeeds when metadata is unreachable"
eq "$OUT" "7.7.7" "--fallback prints the pinned version"
has "rebuilding the pinned 7.7.7" "$(cat "$TMP/stderr")" "--fallback explains the fallback"

OUT="$(run_resolver "file://$LATEST" --fallback 7.7.7)"; RC=$?
eq "$RC" "0" "--fallback succeeds when metadata is reachable"
eq "$OUT" "9.9.9" "--fallback prefers the latest version"

OUT="$(run_resolver "file://$TMP/does-not-exist.json")"; RC=$?
eq "$RC" "1" "an unreachable metadata URL without fallback is fatal"
eq "$(grep '^PI_VERSION=' "$ENVF")" "PI_VERSION=1.4.0" "a failed resolve leaves .env untouched"

reset_env
printf '{"version":"latest","packageName":"%s"}\n' "$PKG" > "$LATEST"
OUT="$(run_resolver "file://$LATEST" --fallback 7.7.7)"; RC=$?
eq "$RC" "0" "--fallback handles an invalid resolved version"
eq "$OUT" "7.7.7" "an invalid resolved version falls back"

printf 'not json\n' > "$LATEST"
OUT="$(run_resolver "file://$LATEST")"; RC=$?
eq "$RC" "1" "malformed metadata is refused"

# 4i. a package rename is refused, never silently pinned.
reset_env
printf '{"version":"9.9.9","packageName":"@someone/else"}\n' > "$LATEST"
OUT="$(run_resolver "file://$LATEST")"; RC=$?
eq "$RC" "1" "a mismatched packageName is refused"
has "points at" "$(cat "$TMP/stderr")" "the package mismatch is explained"
eq "$(grep '^PI_VERSION=' "$ENVF")" "PI_VERSION=1.4.0" "a package mismatch leaves .env untouched"

# --- 5. docs point at the real upgrade path --------------------------------
DOCTOR="$(cat scripts/doctor.sh 2>/dev/null)"
has 'PI_VERSION' "$DOCTOR" "doctor compares the image's pi with the pin"
has 'PI_SKIP_VERSION_CHECK' "$DOCTOR" "doctor checks the self-update notice is disabled"

USAGE="$(cat USAGE.md 2>/dev/null)"
has "make update" "$USAGE" "USAGE documents make update"
has "upgrade pi to the latest release" "$USAGE" "USAGE says make update upgrades pi"
has "make build" "$USAGE" "USAGE documents make build"
hasnt "never contacts the network" "$USAGE" "USAGE does not claim make build is offline"
hasnt "update-pi" "$USAGE" "USAGE does not document a second update command"

README="$(cat README.md 2>/dev/null)"
has "make update" "$README" "README documents make update"
hasnt "no network" "$README" "README does not claim make build is offline"
hasnt "update-pi" "$README" "README does not document a second update command"

printf '\npi update tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
