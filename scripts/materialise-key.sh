#!/usr/bin/env bash
#
# materialise-key.sh — put the LLM key where docker can mount it, preferring RAM.
#
# Prints the path to use as the docker secret source (nothing else on stdout, so
# it can be captured). By default that is <repo>/.secrets/llm_key, a plaintext
# file on disk.
#
# If PI_KEY_SOURCE is set (e.g. `keychain:pi-deepseek`, `op:op://…`, `pass:…`,
# `file:/path`, `env:VAR`) the key is fetched on every run and written to a
# tmpfs directory instead, so the only persistent record is the *reference* in
# .env. On Linux that is $XDG_RUNTIME_DIR (fallback /dev/shm); elsewhere a tmpfs
# path is not available and the script falls back to the static file with a
# warning.
#
# Usage:
#   scripts/materialise-key.sh            # print the path to use
#   scripts/materialise-key.sh --show     # also explain what it did (stderr)
#
# Exit codes: 0 ok, 1 could not materialise, 2 setup problem.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC="$ROOT/.secrets/llm_key"
SHOW=0
[[ "${1:-}" == "--show" ]] && SHOW=1

say() { (( SHOW == 1 )) && echo "materialise-key: $*" >&2; return 0; }

source_spec="${PI_KEY_SOURCE:-}"
if [[ -z "$source_spec" ]]; then
    say "no PI_KEY_SOURCE set — using $STATIC"
    printf '%s\n' "$STATIC"
    exit 0
fi

# Resolve the key from the configured source.
case "$source_spec" in
    keychain:*)
        svc="${source_spec#keychain:}"
        command -v security >/dev/null 2>&1 || { echo "materialise-key: macOS 'security' not found" >&2; exit 2; }
        key="$(security find-generic-password -s "$svc" -w 2>/dev/null)" \
            || { echo "materialise-key: no keychain item named $svc" >&2; exit 1; }
        ;;
    pass:*)
        entry="${source_spec#pass:}"
        command -v pass >/dev/null 2>&1 || { echo "materialise-key: 'pass' not found" >&2; exit 2; }
        key="$(pass show "$entry" 2>/dev/null | head -n1)" \
            || { echo "materialise-key: pass entry $entry not readable" >&2; exit 1; }
        ;;
    op:*)
        ref="${source_spec#op:}"
        command -v op >/dev/null 2>&1 || { echo "materialise-key: 1Password CLI 'op' not found" >&2; exit 2; }
        key="$(op read "$ref" 2>/dev/null)" \
            || { echo "materialise-key: op reference $ref not readable" >&2; exit 1; }
        ;;
    file:*)
        f="${source_spec#file:}"; f="${f/#\~/$HOME}"
        [[ -r "$f" ]] || { echo "materialise-key: cannot read $f" >&2; exit 1; }
        key="$(head -n1 -- "$f")"
        ;;
    env:*)
        var="${source_spec#env:}"
        key="${!var:-}"
        [[ -n "$key" ]] || { echo "materialise-key: environment variable $var is empty" >&2; exit 1; }
        ;;
    *)
        echo "materialise-key: unknown PI_KEY_SOURCE '$source_spec' (expected keychain:|pass:|op:|file:|env:)" >&2
        exit 1
        ;;
esac

key="$(printf '%s' "$key" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[[ -n "$key" && "$key" != "unset" ]] || { echo "materialise-key: source returned an empty/placeholder key" >&2; exit 1; }

# Write it to RAM: $XDG_RUNTIME_DIR or /dev/shm are tmpfs on Linux.
for base in "${XDG_RUNTIME_DIR:-}" /dev/shm; do
    [[ -n "$base" && -d "$base" && -w "$base" ]] || continue
    dir="$base/pi-llm-key-$(id -u)"
    umask 077
    mkdir -p "$dir" 2>/dev/null || continue
    chmod 700 "$dir" 2>/dev/null || true
    tmp="$dir/llm_key.tmp.$$"
    ( umask 077; printf '%s\n' "$key" > "$tmp" ) || continue
    chmod 400 "$tmp"
    mv -f "$tmp" "$dir/llm_key" || continue
    say "materialised from ${source_spec%%:*} into $dir/llm_key (tmpfs, mode 400)"
    printf '%s\n' "$dir/llm_key"
    exit 0
done

echo "materialise-key: no tmpfs available (need \$XDG_RUNTIME_DIR or /dev/shm);" >&2
echo "                falling back to the static file. Unset PI_KEY_SOURCE or run on Linux." >&2
printf '%s\n' "$STATIC"
exit 0
