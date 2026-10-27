#!/usr/bin/env bash
#
# Tests for per-project Docker network subnets: scripts/network-subnet.sh and
# the Makefile / docker-compose IPAM wiring.
#
# Docker hands out a whole /16 per network from a pool of only ~15 blocks, so a
# dozen projects exhaust it ("all predefined address pools have been fully
# subnetted"). These tests pin the fix: every project gets a valid, stable /24
# from a pinned base, and by default nothing is read from the host.
#
# No Docker or network required.
#
# Run from anywhere: bash tests/test-network-subnet.sh

set -u

# These assertions drive `make`; skip cleanly where make is not installed
# (e.g. running the tests inside the container instead of on the host).
command -v make >/dev/null 2>&1 || { echo "SKIP  make not installed — run this suite on the host"; exit 0; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Isolate from the parent environment / .env overrides.
unset PI_NETWORK_SUBNET PI_NETWORK_BASE PI_NETWORK_DISCOVERY PROJECT_NAME COMPOSE_PROJECT_NAME

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$1"; then no "$3"; else ok "$3"; fi; }
matches() { if printf '%s' "$2" | grep -qE -- "$1"; then ok "$3"; else no "$3"; fi; }

SCRIPT="$REPO_ROOT/scripts/network-subnet.sh"
BASE="10.200.0.0/13"

# --- script: valid, deterministic, distinct per project --------------------
A="$(bash "$SCRIPT" pi-agent-alpha "$BASE")"
A_AGAIN="$(bash "$SCRIPT" pi-agent-alpha "$BASE")"
B="$(bash "$SCRIPT" pi-agent-beta "$BASE")"

matches '^10\.(20[0-7])\.[0-9]{1,3}\.0/24$' "$A" \
    "script: returns a valid /24 network address ($A)"
[[ "$A" == "$A_AGAIN" ]] && ok "script: deterministic for the same project" \
                         || no "script: deterministic for the same project"
[[ "$A" != "$B" ]] && ok "script: different projects usually get different subnets" \
                    || no "script: different projects usually get different subnets"

# --- script: overrides ------------------------------------------------------
OVERRIDE="$(PI_NETWORK_SUBNET=10.9.9.0/24 bash "$SCRIPT" pi-agent-alpha "$BASE")"
[[ "$OVERRIDE" == "10.9.9.0/24" ]] \
  && ok "script: PI_NETWORK_SUBNET wins verbatim" \
  || no "script: PI_NETWORK_SUBNET wins verbatim (got '$OVERRIDE')"

BASED="$(bash "$SCRIPT" pi-agent-alpha 10.202.0.0/16)"
matches '^10\.202\.[0-9]{1,3}\.0/24$' "$BASED" "script: explicit base block is honored"

if bash "$SCRIPT" pi-agent-alpha "not-a-subnet" >/dev/null 2>&1; then
  no "script: invalid base is rejected"
else
  ok "script: invalid base is rejected"
fi

# --- script: clash avoidance when probing is enabled ------------------------
CLASH="$(PI_NETWORK_USED="$A" bash "$SCRIPT" pi-agent-alpha "$BASE")"
[[ "$CLASH" != "$A" ]] && ok "script: skips a /24 already in use ($CLASH)" \
                       || no "script: skips a /24 already in use"

WIDE="$(PI_NETWORK_USED="10.200.0.0/16" bash "$SCRIPT" pi-agent-alpha "$BASE")"
hasnt "10.200." "$WIDE" "script: skips a whole used /16 (returned $WIDE)"

if PI_NETWORK_USED="10.200.0.0/16" \
     bash "$SCRIPT" pi-agent-alpha 10.200.0.0/16 >/dev/null 2>&1; then
  no "script: fails when the base is fully used"
else
  ok "script: fails when the base is fully used"
fi

# --- script: default reads nothing from the host ----------------------------
mkdir -p "$REPO_ROOT/.pi-workspace"
FAKEBIN="$(mktemp -d "$REPO_ROOT/.pi-workspace/netsubnet.XXXXXX")"
WORK="$(mktemp -d)"
trap 'rm -rf "$FAKEBIN" "$WORK"' EXIT
cat > "$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FAKE_LOG:-}" ]] && echo "docker $*" >> "$FAKE_LOG"
case " $* " in
  *" --format {{.Name}} "*) exit 0 ;;
  *" --format {{.ID}} "*)   echo deadbeef; exit 0 ;;
  *" network inspect "*)     printf '%s\n' "${FAKE_SUBNET:-10.200.0.0/24}"; exit 0 ;;
esac
exit 0
EOF
cat > "$FAKEBIN/ip" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FAKE_LOG:-}" ]] && echo "ip $*" >> "$FAKE_LOG"
exit 0
EOF
chmod +x "$FAKEBIN/docker" "$FAKEBIN/ip"

FAKE_LOG="$WORK/default.log"
rm -f "$FAKE_LOG"
DEFAULTED="$(FAKE_LOG="$FAKE_LOG" PATH="$FAKEBIN:$PATH" bash "$SCRIPT" pi-agent-alpha "$BASE")"
if [[ -s "$FAKE_LOG" ]]; then
  no "script: default allocator reads nothing (invoked: $(tr '\n' ';' < "$FAKE_LOG"))"
else
  ok "script: default allocator reads nothing from the host"
fi
[[ "$DEFAULTED" == "$A" ]] && ok "script: default matches the deterministic value" \
                           || no "script: default matches the deterministic value"

# Opt-in probing must actually consult Docker and skip what it reports.
CAND="$(bash "$SCRIPT" pi-agent-alpha 10.200.0.0/16)"
PROBED="$(FAKE_SUBNET="$CAND" PI_NETWORK_DISCOVERY=1 PATH="$FAKEBIN:$PATH" \
          bash "$SCRIPT" pi-agent-alpha 10.200.0.0/16)"
[[ "$PROBED" != "$CAND" ]] && ok "script: PI_NETWORK_DISCOVERY=1 skips a used /24 ($PROBED)" \
                           || no "script: PI_NETWORK_DISCOVERY=1 skips a used /24"

# --- Makefile wiring --------------------------------------------------------
mkdir -p "$WORK/alpha" "$WORK/beta"

MAKE_ALPHA="$(make -n run WORK_DIR="$WORK/alpha" 2>/dev/null)"
MAKE_BETA="$(make -n run WORK_DIR="$WORK/beta" 2>/dev/null)"
EXPECTED_ALPHA="$(PI_NETWORK_BASE="$BASE" bash "$SCRIPT" "pi-agent-$(basename "$WORK/alpha")")"
EXPECTED_BETA="$(PI_NETWORK_BASE="$BASE" bash "$SCRIPT" "pi-agent-$(basename "$WORK/beta")")"

has "PI_NETWORK_SUBNET=$EXPECTED_ALPHA" "$MAKE_ALPHA" \
    "make: passes the derived subnet to the run"
hasnt "PI_NETWORK_SUBNET=$EXPECTED_BETA" "$MAKE_ALPHA" \
      "make: two projects do not share a subnet"

MAKE_ENV="$(PI_NETWORK_SUBNET=10.9.9.0/24 make -n run WORK_DIR="$WORK/alpha" 2>/dev/null)"
has "PI_NETWORK_SUBNET=10.9.9.0/24" "$MAKE_ENV" \
    "make: PI_NETWORK_SUBNET env override is honored"

MAKE_BASE="$(PI_NETWORK_BASE=10.202.0.0/16 make -n run WORK_DIR="$WORK/alpha" 2>/dev/null)"
has "PI_NETWORK_SUBNET=10.202." "$MAKE_BASE" \
    "make: PI_NETWORK_BASE env override is honored"

# --- compose declares the IPAM subnet --------------------------------------
COMPOSE="$(cat docker-compose.yml)"
has '${PI_NETWORK_SUBNET' "$COMPOSE" "compose: network subnet comes from PI_NETWORK_SUBNET"
has 'ipam:' "$COMPOSE" "compose: network declares an ipam block"

# --- cleanup helpers --------------------------------------------------------
CLEAN="$(make -n net-clean 2>/dev/null)"
has "docker network rm" "$CLEAN" "make net-clean: removes unused networks"
has "_pi_network" "$CLEAN" "make net-clean: scoped to this tool's networks"

PICTL_CLEAN="$(bin/pictl net-clean --dry-run 2>/dev/null)"
has "docker network rm" "$PICTL_CLEAN" "pictl net-clean: dispatches to make net-clean"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
