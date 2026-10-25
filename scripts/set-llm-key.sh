#!/usr/bin/env bash
#
# set-llm-key.sh — store a provider API key outside the pi data dir and point
# pi at it through models.json instead of a literal in auth.json.
#
# Why: `auth.json` holds the key in plaintext, and that file is copied into
# every per-project instance by seeding/sync, so one key ends up in N places
# with no revocation path (SECURITY.md A5, A7). With this script the key lives
# in one 0400 file (or better: your OS keychain, materialised per run) which is
# mounted into the container as a Docker secret, and pi resolves it at request
# time with `apiKey: "!cat /run/secrets/llm_key"`. Nothing secret is written
# into the data directories, so seeding/sync no longer replicate a key.
#
# Usage:
#   scripts/set-llm-key.sh --provider deepseek --from stdin
#   scripts/set-llm-key.sh --provider deepseek --from keychain:pi-deepseek
#   scripts/set-llm-key.sh --provider deepseek --from pass:llm/deepseek
#   scripts/set-llm-key.sh --provider deepseek --from op:op://Private/DeepSeek/key
#   scripts/set-llm-key.sh --provider deepseek --from env:DEEPSEEK_API_KEY
#   scripts/set-llm-key.sh --provider deepseek --from file:~/.deepseek-key
#
# Options:
#   --provider NAME    provider id as pi knows it (deepseek, opencode, openai, …)
#   --from SOURCE      stdin (default) | env:VAR | file:PATH | keychain:SERVICE
#                      | pass:PATH | op:REFERENCE
#   --data-dir DIR     pi data dir to configure (default $PI_DATA_DIR or .pi-data)
#   --secret FILE      where the key is written (default <repo>/.secrets/llm_key)
#   --secret-path P    path inside the container (default /run/secrets/llm_key)
#   --print-models     only print the models.json stanza, write nothing
#   --quiet
#
# The key is never echoed. Exit codes: 0 ok, 1 bad input/source, 2 setup issue.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${PI_DATA_DIR:-$ROOT/.pi-data}"
SECRET_FILE="$ROOT/.secrets/llm_key"
SECRET_PATH="/run/secrets/llm_key"
PROVIDER=""
SOURCE="stdin"
QUIET=0
PRINT_ONLY=0

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

die() { echo "set-llm-key: $*" >&2; exit "${2:-1}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider)    PROVIDER="${2:?--provider needs a value}"; shift 2 ;;
        --from)        SOURCE="${2:?--from needs a value}"; shift 2 ;;
        --data-dir)    DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
        --secret)      SECRET_FILE="${2:?--secret needs a value}"; shift 2 ;;
        --secret-path) SECRET_PATH="${2:?--secret-path needs a value}"; shift 2 ;;
        --print-models) PRINT_ONLY=1; shift ;;
        --quiet|-q)    QUIET=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ -n "$PROVIDER" ]] || die "--provider is required (deepseek, opencode, openai, …)"
[[ "$PROVIDER" =~ ^[a-z0-9._-]+$ ]] || die "invalid provider name: $PROVIDER"

MODELS_JSON="$DATA_DIR/agent/models.json"

# models.json stanza that makes pi resolve the key at request time.
models_stanza() {
    cat <<JSON
{
  "providers": {
    "$PROVIDER": {
      "apiKey": "!cat $SECRET_PATH"
    }
  }
}
JSON
}

if (( PRINT_ONLY == 1 )); then
    models_stanza
    exit 0
fi

# --- resolve the key -------------------------------------------------------
case "$SOURCE" in
    stdin)
        read -r KEY || true
        ;;
    env:*)
        var="${SOURCE#env:}"
        KEY="${!var:-}"
        [[ -n "$KEY" ]] || die "environment variable $var is empty"
        ;;
    file:*)
        path="${SOURCE#file:}"
        path="${path/#\~/$HOME}"
        [[ -r "$path" ]] || die "cannot read $path"
        KEY="$(head -n1 -- "$path")"
        ;;
    keychain:*)
        service="${SOURCE#keychain:}"
        command -v security >/dev/null 2>&1 || die "macOS 'security' not found"
        KEY="$(security find-generic-password -s "$service" -w 2>/dev/null)" \
            || die "no keychain item named $service"
        ;;
    pass:*)
        entry="${SOURCE#pass:}"
        command -v pass >/dev/null 2>&1 || die "'pass' not found"
        KEY="$(pass show "$entry" 2>/dev/null | head -n1)" \
            || die "pass entry $entry not readable"
        ;;
    op:*)
        ref="${SOURCE#op:}"
        command -v op >/dev/null 2>&1 || die "1Password CLI 'op' not found"
        KEY="$(op read "$ref" 2>/dev/null)" || die "op reference $ref not readable"
        ;;
    *)
        die "unknown --from source: $SOURCE"
        ;;
esac

# Trim surrounding whitespace, then reject anything unusable.
KEY="$(printf '%s' "$KEY" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[[ -n "$KEY" ]] || die "empty key — refusing to write a placeholder"
if printf '%s' "$KEY" | grep -q '[[:space:]]'; then
    die "the key contains whitespace; that is almost certainly wrong input"
fi
(( ${#KEY} >= 16 )) || die "the key looks too short (${#KEY} chars)"

mask() {
    local k="$1"
    if (( ${#k} <= 10 )); then printf '****'; else printf '%s…%s' "${k:0:6}" "${k: -4}"; fi
}

# --- write the secret ------------------------------------------------------
secret_dir="$(dirname "$SECRET_FILE")"
mkdir -p "$secret_dir" || die "cannot create $secret_dir" 2
chmod 700 "$secret_dir" 2>/dev/null || true

tmp="$SECRET_FILE.tmp.$$"
( umask 077; printf '%s\n' "$KEY" > "$tmp" ) || die "cannot write $tmp" 2
chmod 400 "$tmp"
mv -f "$tmp" "$SECRET_FILE" || die "cannot move $tmp into place" 2

(( QUIET == 0 )) && echo "set-llm-key: wrote $(mask "$KEY") to ${SECRET_FILE#"$ROOT"/} (mode 400)"

# --- point pi at it --------------------------------------------------------
mkdir -p "$(dirname "$MODELS_JSON")" 2>/dev/null || true

if [[ ! -f "$MODELS_JSON" ]]; then
    models_stanza > "$MODELS_JSON"
    chmod 600 "$MODELS_JSON"
    (( QUIET == 0 )) && echo "set-llm-key: created ${MODELS_JSON#"$ROOT"/} with apiKey \"!cat $SECRET_PATH\""
elif grep -qF -- "!cat $SECRET_PATH" "$MODELS_JSON"; then
    (( QUIET == 0 )) && echo "set-llm-key: ${MODELS_JSON#"$ROOT"/} already points at $SECRET_PATH"
else
    cat >&2 <<EOF
set-llm-key: $MODELS_JSON already exists and does not reference $SECRET_PATH.
             Add this stanza by hand (merging JSON automatically is risky), then
             re-run with --print-models to see the exact block:

EOF
    models_stanza >&2
fi

# --- warn about a plaintext key that would win -----------------------------
AUTH="$DATA_DIR/agent/auth.json"
if [[ -f "$AUTH" ]] && grep -q "\"$PROVIDER\"" "$AUTH" 2>/dev/null; then
    cat >&2 <<EOF

set-llm-key: WARNING — $PROVIDER still has an entry in $AUTH.
             auth.json takes precedence over models.json, so the plaintext key
             there will be used instead of the secret. Remove that entry
             (e.g. with /logout in pi, or by editing the file).
EOF
fi

if (( QUIET == 0 )); then
    cat <<EOF

Next:
  1. make setup           # creates the .secrets mount if it is missing
  2. make build           # the image must include the secret mount
  3. start the agent and confirm with: make check-keys
EOF
fi
