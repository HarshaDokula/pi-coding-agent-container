#!/usr/bin/env bash
#
# refresh-known-hosts.sh — regenerate src/github_known_hosts from GitHub's
# published SSH host keys.
#
# The image pins GitHub's host keys instead of trusting `ssh-keyscan` at build
# time (SECURITY.md C3). GitHub does rotate them occasionally; when that happens
# git/ssh fail with "Host key verification failed" and this script is the
# supported fix — it fetches the keys from https://api.github.com/meta, checks
# them against the fingerprints in the same authoritative response, and only
# then rewrites the file.
#
# Usage: scripts/refresh-known-hosts.sh [--check] [--target FILE]
#   --check   verify the current file, write nothing (exit 1 if stale)
#
# Requires: curl, ssh-keygen. No jq needed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/src/github_known_hosts"
META_URL="${PI_GITHUB_META_URL:-https://api.github.com/meta}"
CURL_BIN="${PI_CHECK_KEYS_CURL:-curl}"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --target) TARGET="${2:?--target needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "refresh-known-hosts: unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v "$CURL_BIN" >/dev/null 2>&1 || { echo "refresh-known-hosts: curl not found" >&2; exit 2; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "refresh-known-hosts: ssh-keygen not found (install openssh-client)" >&2; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.keys" "$tmp.fps"' EXIT

"$CURL_BIN" -sSfL --max-time 20 "$META_URL" > "$tmp" || {
    echo "refresh-known-hosts: could not fetch $META_URL" >&2; exit 1; }

# Authoritative public keys, e.g. "ssh-ed25519 AAAA...", "ecdsa-sha2-nistp256 AAAA..."
grep -oE '"(ssh-(rsa|ed25519)|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+"' "$tmp" \
    | tr -d '"' | sort -u > "$tmp.keys"

# Authoritative fingerprints from the same response. The API returns the bare
# base64 digest ("SHA256_ECDSA": "p2QAM..."); the docs and ssh-keygen use the
# "SHA256:" prefix, so normalise it here.
grep -oE '"SHA256_[A-Z0-9]+": *"[^"]+"' "$tmp" \
    | sed -E 's/.*: *"([^"]+)".*/\1/' \
    | while read -r fp; do
          case "$fp" in
              SHA256:*) printf '%s\n' "$fp" ;;
              *)        printf 'SHA256:%s\n' "$fp" ;;
          esac
      done | sort -u > "$tmp.fps"

if [[ ! -s "$tmp.keys" ]]; then
    echo "refresh-known-hosts: no ssh keys found in $META_URL" >&2; exit 1
fi

# Fail closed: without fingerprints from the same authoritative response there
# is nothing to verify the fetched keys against.
if [[ ! -s "$tmp.fps" ]]; then
    echo "refresh-known-hosts: no fingerprints in $META_URL — refusing to write unverified keys" >&2
    exit 1
fi

# Write the candidate file and self-check it against the fingerprints.
while read -r key; do
    printf 'github.com %s\n' "$key"
done < "$tmp.keys" > "$TARGET.candidate"

have="$(ssh-keygen -lf "$TARGET.candidate" 2>/dev/null | awk '{print $2}')"
missing=""
while read -r fp; do
    [[ -n "$fp" ]] || continue
    [[ "$have" == *"$fp"* ]] || missing="$missing $fp"
done < "$tmp.fps"

if [[ -n "$missing" ]]; then
    rm -f "$TARGET.candidate"
    echo "refresh-known-hosts: key/fingerprint mismatch — refusing to write." >&2
    echo "  keys fetched: $(wc -l < "$tmp.keys" | tr -d ' ')   fingerprints checked: $(wc -l < "$tmp.fps" | tr -d ' ')" >&2
    echo "  missing:$missing" >&2
    exit 1
fi

if (( CHECK_ONLY == 1 )); then
    if cmp -s "$TARGET.candidate" "$TARGET"; then
        rm -f "$TARGET.candidate"
        echo "refresh-known-hosts: $TARGET is current"
        exit 0
    fi
    rm -f "$TARGET.candidate"
    echo "refresh-known-hosts: $TARGET is stale — run 'make refresh-known-hosts'" >&2
    exit 1
fi

if cmp -s "$TARGET.candidate" "$TARGET"; then
    rm -f "$TARGET.candidate"
    echo "refresh-known-hosts: $TARGET already up to date"
    exit 0
fi

chmod 0644 "$TARGET.candidate"
mv -f "$TARGET.candidate" "$TARGET"
echo "refresh-known-hosts: updated $TARGET ($(wc -l < "$TARGET" | tr -d ' ') hosts keys)"
echo "Rebuild the image so it picks up the new file: make update"
