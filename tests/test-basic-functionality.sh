#!/usr/bin/env bash
#
# Regression tests for "security hardening must not break basic functionality".
#
# Covers the two regressions found after the C2/B5 work:
#   1. the runtime image lost `make` (and with it the ability to build anything)
#   2. git over SSH broke with egress on, because GIT_SSH_COMMAND is split on
#      whitespace by git, so `-o ProxyCommand=nc ... %h %p` never applied and
#      ssh tried to resolve the hostname directly — impossible on an internal
#      network. Fixed with a ProxyCommand in ssh_config instead.
#
# No Docker needed.
#
# Run from anywhere: bash tests/test-basic-functionality.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if [[ "$2" == *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
hasnt() { if [[ "$2" != *"$1"* ]]; then ok "$3"; else no "$3"; fi; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (got '$1', want '$2')"; fi; }

DOCKERFILE="$(cat Dockerfile 2>/dev/null)"
RUNTIME_APT="$(awk '/^FROM .* AS base/{s=1} s && /apt-get install/{c=1} c{print; if ($0 !~ /\\$/) exit}' Dockerfile)"
MAKEFILE="$(cat Makefile 2>/dev/null)"
WRAPPER="$REPO_ROOT/src/ssh-netcat-proxy.sh"
SSH_CONF="$REPO_ROOT/src/ssh_config.d/90-pi-egress.conf"

# --- 1. the runtime image keeps the tools the agent needs ------------------
has "make" "$RUNTIME_APT" "runtime image installs make"
has "git" "$RUNTIME_APT" "runtime image installs git"
has "openssh-client" "$RUNTIME_APT" "runtime image installs openssh-client"
has "netcat-openbsd" "$RUNTIME_APT" "runtime image installs netcat (needed by the ssh proxy)"
has "python3" "$RUNTIME_APT" "runtime image keeps python3"
hasnt "build-essential" "$RUNTIME_APT" "runtime image still has no compiler"
hasnt "python3-dev" "$RUNTIME_APT" "runtime image still has no python headers"

# A compiler must remain reachable only through the explicit opt-in.
has "PI_WITH_TOOLCHAIN" "$DOCKERFILE" "toolchain stays behind an explicit build arg"

# --- 2. ssh works through the egress proxy --------------------------------
has "COPY src/ssh-netcat-proxy.sh /usr/local/bin/ssh-netcat-proxy" "$DOCKERFILE" \
    "image installs the ssh proxy helper"
has "COPY src/ssh_config.d/ /etc/ssh/ssh_config.d/" "$DOCKERFILE" \
    "image installs the ssh_config.d drop-in"
has "ProxyCommand /usr/local/bin/ssh-netcat-proxy %h %p" "$(cat "$SSH_CONF" 2>/dev/null)" \
    "ssh_config sets a ProxyCommand with %h/%p"

# git splits GIT_SSH_COMMAND on whitespace, so it must not carry a ProxyCommand.
hasnt "GIT_SSH_COMMAND" "$MAKEFILE" "Makefile no longer passes GIT_SSH_COMMAND"
hasnt "ProxyCommand" "$(grep -h 'EGRESS_PROXY_ARGS :=' Makefile 2>/dev/null)" \
    "the proxy command is not smuggled through a -e env var"

# The wrapper must pick the proxy only when one is configured.
OUT="$(HTTPS_PROXY= PI_NC_BIN=/bin/echo sh "$WRAPPER" github.com 22 2>&1)"
eq "$OUT" "github.com 22" "without HTTPS_PROXY the helper connects directly"
OUT="$(HTTPS_PROXY=http://egress:8888 PI_NC_BIN=/bin/echo sh "$WRAPPER" github.com 22 2>&1)"
eq "$OUT" "-X connect -x egress:8888 github.com 22" "with HTTPS_PROXY the helper tunnels via CONNECT"
OUT="$(HTTPS_PROXY=http://other:3128 PI_NC_BIN=/bin/echo sh "$WRAPPER" h 2200 2>&1)"
eq "$OUT" "-X connect -x other:3128 h 2200" "the proxy address comes from the environment"
OUT="$(sh "$WRAPPER" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "missing arguments fail closed (rc=$RC)"; else no "missing arguments fail closed"; fi

# --- 3. diagnostics exist --------------------------------------------------
if command -v make >/dev/null 2>&1; then
    has "doctor.sh" "$(make -n doctor 2>/dev/null)" "make doctor runs the diagnostic script"
else
    echo "SKIP  make doctor target (make is not installed here)"
fi
D="$(bash scripts/doctor.sh 2>&1)"
has "docker" "$D" "doctor reports on docker"
has "credentials" "$D" "doctor reports on credentials"
has "egress" "$D" "doctor reports on the egress mode"

# doctor must not explode when docker is unavailable
RC_DOCTOR=0
bash scripts/doctor.sh >/dev/null 2>&1 || RC_DOCTOR=$?
if [ "$RC_DOCTOR" -eq 0 ] || [ "$RC_DOCTOR" -eq 1 ]; then
    ok "doctor exits 0/1 (never crashes)"
else
    no "doctor exits 0/1 (got $RC_DOCTOR)"
fi

echo
echo "basic functionality tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
