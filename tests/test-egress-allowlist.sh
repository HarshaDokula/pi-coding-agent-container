#!/usr/bin/env bash
#
# Tests for the egress allowlist switch (default ON, EGRESS=false opts out).
#
# No Docker or network required: everything is observed with `make -n` plus
# static greps of the compose overlay. The proxy itself is covered by
# tests/test-egress-proxy.sh.
#
# Run from anywhere: bash tests/test-egress-allowlist.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }

MAKE_DEFAULT="$(make -n run EGRESS= 2>/dev/null)"
MAKE_OFF="$(make -n run EGRESS=false 2>/dev/null)"
MAKE_ON="$(make -n run EGRESS=true 2>/dev/null)"
MAKE_WIKI="$(make -n run EGRESS=true WIKI=true 2>/dev/null)"
OVERLAY="$(cat docker-compose.egress.yml 2>/dev/null)"
ALLOWLIST="$(make -s --eval='print: ; @echo $(EGRESS_ALLOWLIST)' print 2>/dev/null | tail -1)"

# --- default is ON ----------------------------------------------------------
has "docker-compose.egress.yml" "$MAKE_DEFAULT" "default run: egress overlay loaded (default ON)"
has "HTTPS_PROXY=http://egress:8888" "$MAKE_DEFAULT" "default run: proxy env set"
has "GIT_SSH_COMMAND" "$MAKE_DEFAULT" "default run: ssh routed through proxy"

# --- egress modes -----------------------------------------------------------
MODE_DEFAULT="$(make -s --eval='print: ; @echo $(EGRESS_MODE)' print EGRESS= 2>/dev/null | tail -1)"
MODE_RESEARCH="$(make -s --eval='print: ; @echo $(EGRESS_MODE)' print EGRESS=research 2>/dev/null | tail -1)"
MODE_OFF="$(make -s --eval='print: ; @echo $(EGRESS_MODE)' print EGRESS=false 2>/dev/null | tail -1)"

if [ "$MODE_DEFAULT" = "allowlist" ]; then ok "default mode is allowlist"; else no "default mode is allowlist (got '$MODE_DEFAULT')"; fi
if [ "$MODE_RESEARCH" = "research" ]; then ok "EGRESS=research selects research mode"; else no "EGRESS=research selects research mode (got '$MODE_RESEARCH')"; fi
if [ "$MODE_OFF" = "off" ]; then ok "EGRESS=false disables the proxy"; else no "EGRESS=false disables the proxy (got '$MODE_OFF')"; fi
has "EGRESS_MODE" "$OVERLAY" "overlay passes EGRESS_MODE to the proxy"
has "depends_on" "$OVERLAY" "overlay starts the proxy as a dependency"

# --- explicit values --------------------------------------------------------
has "HTTPS_PROXY=http://egress:8888" "$MAKE_ON" "EGRESS=true: proxy env set"
has "docker-compose.egress.yml" "$MAKE_ON" "EGRESS=true: overlay loaded"
hasnt "docker-compose.egress.yml" "$MAKE_OFF" "EGRESS=false: overlay omitted"
hasnt "HTTPS_PROXY" "$MAKE_OFF" "EGRESS=false: no proxy env"

# --- overlay composes with the wiki overlay --------------------------------
has "docker-compose.wiki.yml" "$MAKE_WIKI" "wiki + egress: wiki overlay kept"
has "docker-compose.egress.yml" "$MAKE_WIKI" "wiki + egress: egress overlay kept"

# --- overlay wiring ---------------------------------------------------------
has "internal: true" "$OVERLAY" "overlay makes pi_network internal"
has "depends_on" "$OVERLAY" "overlay starts the proxy as a dependency"
has "pi_egress_upstream" "$OVERLAY" "overlay gives the proxy its own route out"
has "/usr/local/lib/egress-proxy.js" "$OVERLAY" "overlay runs the proxy binary"
hasnt "secrets:" "$OVERLAY" "overlay does not hand the token to the proxy"

# --- default allowlist covers what the agent needs -------------------------
for host in api.deepseek.com github.com github.com:22 api.github.com \
            registry.npmjs.org pypi.org duckduckgo.com html.duckduckgo.com; do
    if printf '%s' "$ALLOWLIST" | tr ',' '\n' | grep -qx "$host"; then
        ok "allowlist contains $host"
    else
        no "allowlist contains $host"
    fi
done

# --- the proxy refuses to run open -----------------------------------------
PROXY_ERR="$(EGRESS_ALLOWLIST= PORT=0 node src/egress-proxy.js 2>&1)"
has "refusing to run an open proxy" "$PROXY_ERR" "proxy refuses an empty allowlist"

# --- pictl flags ------------------------------------------------------------
PICTL="$REPO_ROOT/bin/pictl"
PICTL_DEFAULT="$(cd /tmp && "$PICTL" --dry-run 2>&1 | tail -1)"
PICTL_RESEARCH="$(cd /tmp && "$PICTL" --dry-run -r 2>&1 | tail -1)"
PICTL_RESEARCH_LONG="$(cd /tmp && "$PICTL" --dry-run --research 2>&1 | tail -1)"
PICTL_NO_EGRESS="$(cd /tmp && "$PICTL" --dry-run --no-egress 2>&1 | tail -1)"
PICTL_ENV="$(cd /tmp && EGRESS=research "$PICTL" --dry-run 2>&1 | tail -1)"
PICTL_OVERRIDE="$(cd /tmp && EGRESS=false "$PICTL" --dry-run -r 2>&1 | tail -1)"
PICTL_BOTH="$(cd /tmp && "$PICTL" --dry-run -r -w 2>&1 | tail -1)"
PICTL_PASSTHRU="$(cd /tmp && "$PICTL" --dry-run -- EGRESS=research 2>&1 | tail -1)"
PICTL_HELP="$(cd /tmp && "$PICTL" -h 2>&1)"

has "EGRESS=research" "$PICTL_RESEARCH" "pictl -r selects research mode"
has "EGRESS=research" "$PICTL_RESEARCH_LONG" "pictl --research selects research mode"
has "EGRESS=false" "$PICTL_NO_EGRESS" "pictl --no-egress disables the proxy"
hasnt "EGRESS=" "$PICTL_DEFAULT" "pictl default leaves the mode to the Makefile"
has "EGRESS=research" "$PICTL_ENV" "pictl surfaces an inherited EGRESS (visible in --dry-run)"
has "EGRESS=research" "$PICTL_OVERRIDE" "pictl flag overrides an inherited EGRESS"
has "WIKI=true" "$PICTL_BOTH" "pictl -r -w keeps the wiki flag"
has "EGRESS=research" "$PICTL_BOTH" "pictl -r -w keeps the research flag"
has "EGRESS=research" "$PICTL_PASSTHRU" "pictl -- EGRESS=research passthrough still works"
has "--research" "$PICTL_HELP" "pictl -h documents --research"
has "--no-egress" "$PICTL_HELP" "pictl -h documents --no-egress"

# --- a pictl invocation reaches make with the overlay ----------------------
# (`make -n` is what pictl ultimately runs; assert the flag lands on the same
# command line the overlay check uses above.)
has "docker-compose.egress.yml" "$(make -n run EGRESS=research 2>/dev/null)" "make run EGRESS=research selects the overlay"

# --- stale exit paths -------------------------------------------------------
hasnt "EGRESS" "$(cd /tmp && "$PICTL" net-clean --dry-run 2>&1 || true)" "net-clean is unaffected by egress flags"

echo
echo "egress allowlist tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
