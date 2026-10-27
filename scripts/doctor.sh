#!/usr/bin/env bash
#
# doctor.sh — one command that answers "why is the container not working?".
#
# Checks the host side (files, permissions, keys, compose wiring) and, when a
# Docker daemon is reachable, the image side (pinned version, required tools).
# Every check prints PASS / WARN / FAIL plus the command that fixes it.
#
# Usage: scripts/doctor.sh [--data-dir DIR]
#
# Exit codes: 0 all good, 1 at least one FAIL.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${PI_DATA_DIR:-$ROOT/.pi-data}"

fails=0
warns=0
pass=0

pass_() { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
warn()  { printf 'WARN  %s\n      fix: %s\n' "$1" "${2:-}"; warns=$((warns + 1)); }
fail()  { printf 'FAIL  %s\n      fix: %s\n' "$1" "${2:-}"; fails=$((fails + 1)); }

echo "pi container doctor — $ROOT"
echo

# --- host prerequisites -----------------------------------------------------
command -v docker >/dev/null 2>&1 \
    && pass_ "docker found" \
    || fail "docker not found on PATH" "install Docker Engine or Docker Desktop"

DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    DOCKER_OK=1
    pass_ "docker daemon reachable"
else
    warn "docker daemon not reachable (image checks skipped)" "start Docker, then re-run"
fi

# --- config files -----------------------------------------------------------
if [[ -f "$ROOT/.env" ]]; then
    perms="$(stat -c '%a' "$ROOT/.env" 2>/dev/null || echo '?')"
    if [[ "$perms" == "600" || "$perms" == "400" ]]; then
        pass_ ".env permissions ($perms)"
    else
        warn ".env is mode $perms (should be 600)" "make setup"
    fi
    grep -q '^GIT_NAME=' "$ROOT/.env" 2>/dev/null \
        && pass_ "GIT_NAME set" \
        || warn "GIT_NAME not set in .env (commits will have no author)" "edit .env"
else
    fail "no .env" "cp .env.example .env && edit GIT_NAME/GIT_EMAIL"
fi

for f in .secrets/github_token.txt .secrets/llm_key; do
    if [[ -f "$ROOT/$f" ]]; then
        content="$(head -c 8 "$ROOT/$f" 2>/dev/null)"
        if [[ "$content" == "unset" || -z "$content" ]]; then
            warn "$f is a placeholder" \
                 "$([[ $f == *llm_key* ]] && echo 'make set-key SET_KEY_ARGS="--provider <p>"' || echo 'put GITHUB_TOKEN in .env then make setup')"
        else
            pass_ "$f present"
        fi
    else
        warn "$f missing" "make setup"
    fi
done

if [[ -f "${SSH_KEY:-$HOME/.ssh/pi_agent_ed25519}" ]]; then
    pass_ "git SSH key present ($(stat -c '%a' "$SSH_KEY" 2>/dev/null || echo '?') )"
else
    warn "no git SSH key at ${SSH_KEY:-$HOME/.ssh/pi_agent_ed25519}" "make ssh-key, then add it on GitHub"
fi

# --- credentials ------------------------------------------------------------
# Inside the container the fs-vault shim blocks auth.json for non-pi processes by
# design, so probe only on the host.
INSIDE_CONTAINER=0
if [[ -f /etc/ld.so.preload ]] && grep -q 'fs-vault' /etc/ld.so.preload 2>/dev/null; then
    INSIDE_CONTAINER=1
fi

if [[ -f "$DATA_DIR/agent/auth.json" || -f "$DATA_DIR/agent/models.json" ]]; then
    pass_ "agent credentials present in $(basename "$DATA_DIR")"
    if (( INSIDE_CONTAINER == 1 )); then
        warn "key verification skipped: running inside the container" "run 'make doctor' on the host"
    elif "$ROOT/scripts/check-keys.sh" --data-dir "$DATA_DIR" --quiet >/tmp/doctor-check-keys.$$ 2>&1; then
        pass_ "provider keys verified (make check-keys)"
    else
        out="$(tail -2 /tmp/doctor-check-keys.$$ 2>/dev/null | tr '\n' ' ')"
        warn "provider key check failed: ${out:-see output}" "make check-keys"
    fi
    rm -f /tmp/doctor-check-keys.$$
else
    fail "no credentials in $(basename "$DATA_DIR")" "make set-key … or run the agent and /login"
fi

# --- egress wiring ----------------------------------------------------------
EGRESS_VAL="$(make -s --eval='print: ; @echo $(EGRESS_MODE)' print 2>/dev/null | tail -1)"
case "${EGRESS_VAL:-allowlist}" in
    off)        pass_ "egress control disabled (EGRESS=false)" ;;
    allowlist)  pass_ "egress allowlist active (add hosts to EGRESS_ALLOWLIST if a fetch is denied)" ;;
    research)   pass_ "egress research mode (public web allowed, SSRF-guarded)" ;;
    *)          warn "unexpected egress mode '$EGRESS_VAL'" "use EGRESS=true|research|false" ;;
esac

if [[ -f "$ROOT/.pi-data/agent/models.json" ]] && grep -q '!cat /run/secrets/llm_key' "$ROOT/.pi-data/agent/models.json" 2>/dev/null; then
    [[ -s "$ROOT/.secrets/llm_key" ]] \
        && pass_ "models.json secret indirection is wired" \
        || fail "models.json wants /run/secrets/llm_key but .secrets/llm_key is empty" "make set-key …"
fi

# --- image checks (need a daemon) -------------------------------------------
if (( DOCKER_OK == 1 )); then
    IMAGE="local/pi-coding-agent:latest"
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        pass_ "image $IMAGE present"
        missing="$(docker run --rm --entrypoint /bin/sh "$IMAGE" \
            -c 'for b in make git ssh nc gh node python3 curl; do command -v "$b" >/dev/null || echo -n "$b "; done' 2>/dev/null)"
        if [[ -z "$missing" ]]; then
            pass_ "image has the expected tools (make git ssh nc gh node python3 curl)"
        else
            fail "image is missing: $missing" "make update (the image predates the fix)"
        fi
        if docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'test -f /etc/ssh/ssh_config.d/90-pi-egress.conf' 2>/dev/null; then
            pass_ "image ships the ssh proxy config (git over SSH works with egress on)"
        else
            fail "image lacks /etc/ssh/ssh_config.d/90-pi-egress.conf (git push fails with egress on)" "make update"
        fi
    else
        fail "image $IMAGE not built" "make build"
    fi

    if docker compose -f "$ROOT/docker-compose.yml" -f "$ROOT/docker-compose.egress.yml" config -q >/dev/null 2>&1; then
        pass_ "compose config is valid"
    else
        fail "docker compose config failed" "run 'make run' to see the error"
    fi
fi

echo
printf '%d passed, %d warnings, %d failures\n' "$pass" "$warns" "$fails"
(( fails == 0 )) || exit 1
