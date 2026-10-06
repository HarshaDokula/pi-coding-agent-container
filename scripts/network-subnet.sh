#!/usr/bin/env bash
#
# Print the /24 subnet to use for a project's Docker bridge network.
#
# Why this exists
# ---------------
# Docker hands every new bridge network a whole /16 drawn from a pool of only
# ~15 blocks (172.17.0.0/16 .. 172.31.0.0/16). Once those are used up (a dozen
# or so compose projects) the next network creation fails with:
#
#   failed to create network ...: Error response from daemon:
#   all predefined address pools have been fully subnetted
#
# Giving each project network an explicit /24 from our own private block means
# we never touch that tiny default pool.
#
# Clash avoidance
# ---------------
# By default this is purely deterministic: the project name is hashed to a /24
# inside BASE, with no reads of host state. Keep BASE free of your LAN/VPN and
# the result will not clash with anything. If you would rather have it probe
# Docker networks, host addresses and host routes and pick the first free /24,
# opt in with PI_NETWORK_DISCOVERY=1 (and an existing network for the same
# project is reused so Compose never sees a change).
#
# Usage
# -----
#   network-subnet.sh PROJECT [BASE]
#
#   PROJECT   stable seed, normally the compose project name
#   BASE      optional block to allocate inside (default 10.200.0.0/13)
#
# Environment
# -----------
#   PI_NETWORK_SUBNET      exact subnet override; printed verbatim
#   PI_NETWORK_BASE        base block, used when BASE is not given
#   PI_NETWORK_DISCOVERY   set to 1 to probe Docker/ip and avoid clashes
#                          (default 0: deterministic, reads nothing)
#   PI_NETWORK_USED        extra space/newline-separated CIDRs to treat as
#                          already in use (mainly for tests)
set -euo pipefail

if [[ -n "${PI_NETWORK_SUBNET:-}" ]]; then
  printf '%s\n' "$PI_NETWORK_SUBNET"
  exit 0
fi

project="${1:-default}"
base="${2:-${PI_NETWORK_BASE:-10.200.0.0/13}}"

# --- validate the base; it must leave room for at least a few /24s ----------
if [[ ! "$base" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
  echo "network-subnet.sh: invalid base '$base' (expected e.g. 10.200.0.0/13)" >&2
  exit 1
fi
o1=$((10#${BASH_REMATCH[1]})); o2=$((10#${BASH_REMATCH[2]}))
o3=$((10#${BASH_REMATCH[3]})); o4=$((10#${BASH_REMATCH[4]}))
plen=$((10#${BASH_REMATCH[5]}))
if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then
  echo "network-subnet.sh: invalid octet in '$base'" >&2
  exit 1
fi
if (( plen < 8 || plen > 16 )); then
  echo "network-subnet.sh: base must be /8../16 (got /$plen)" >&2
  exit 1
fi
base_int=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
blocks=$(( 1 << (32 - plen - 8) ))

# --- helpers ----------------------------------------------------------------
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  printf '%d\n' $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Print "START END" for a CIDR; a bare address counts as /32.
cidr_range() {
  local cidr="$1" ip plen2 n hostbits mask size start
  ip="${cidr%%/*}"
  if [[ "$cidr" == */* ]]; then plen2="${cidr##*/}"; else plen2=32; fi
  n="$(ip2int "$ip")"
  hostbits=$(( 32 - plen2 ))
  size=$(( 1 << hostbits ))
  mask=$(( (0xFFFFFFFF << hostbits) & 0xFFFFFFFF ))
  start=$(( n & mask ))
  printf '%d %d\n' "$start" "$(( start + size - 1 ))"
}

# --- reuse an existing network subnet (opt-in via PI_NETWORK_DISCOVERY=1) ----
discovery=0
[[ "${PI_NETWORK_DISCOVERY:-0}" == "1" ]] && discovery=1

if (( discovery )) && [[ -z "${PI_NETWORK_USED:-}" ]] && command -v docker >/dev/null 2>&1; then
  existing="$(docker network ls \
      --filter "label=com.docker.compose.project=$project" \
      --filter name=_pi_network --format '{{.Name}}' 2>/dev/null | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    subnet="$(docker network inspect "$existing" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -E '^[0-9.]+/[0-9]+$' | head -n1 || true)"
    if [[ -n "$subnet" ]]; then
      printf '%s\n' "$subnet"
      exit 0
    fi
  fi
fi

# --- collect ranges already in use (opt-in) ---------------------------------
used=()
if [[ -n "${PI_NETWORK_USED:-}" ]]; then
  used+=( ${PI_NETWORK_USED//$'\n'/ } )
elif (( discovery )); then
  if command -v docker >/dev/null 2>&1; then
    ids="$(docker network ls --format '{{.ID}}' 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
      while IFS= read -r cidr; do
        [[ -n "$cidr" ]] && used+=("$cidr")
      done < <(docker network inspect $ids \
                 --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
               | grep -E '^[0-9.]+/[0-9]+$' || true)
    fi
  fi
  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r cidr; do
      [[ -n "$cidr" ]] && used+=("$cidr")
    done < <(ip -4 -o addr show 2>/dev/null | awk '{print $4}' || true)
    while IFS= read -r cidr; do
      [[ -n "$cidr" ]] && used+=("$cidr")
    done < <(ip -4 -o route show table all 2>/dev/null \
               | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) print $i}' \
               || true)
  fi
fi

# --- deterministic probe for the first free /24 -----------------------------
hash="$(printf '%s' "$project" | cksum | awk '{print $1}')"
start=$(( hash % blocks ))
for (( i = 0; i < blocks; i++ )); do
  off=$(( (start + i) % blocks ))
  net=$(( base_int + off * 256 ))
  end=$(( net + 255 ))
  conflict=0
  for u in "${used[@]}"; do
    [[ -z "$u" ]] && continue
    range="$(cidr_range "$u" 2>/dev/null || true)"
    [[ -z "$range" ]] && continue
    us="${range%% *}"; ue="${range##* }"
    if (( net <= ue && end >= us )); then
      conflict=1
      break
    fi
  done
  if (( conflict == 0 )); then
    printf '%d.%d.%d.0/24\n' \
      $(( (net >> 24) & 255 )) \
      $(( (net >> 16) & 255 )) \
      $(( (net >> 8) & 255 ))
    exit 0
  fi
done

echo "network-subnet.sh: no free /24 in $base (all $blocks blocks are in use)" >&2
exit 1
