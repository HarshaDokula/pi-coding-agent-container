#!/usr/bin/env bash
#
# check-keys.sh — verify that the LLM provider credentials in auth.json actually
# work.
#
# Pi stores API keys without validating them, so a revoked or mistyped key
# still shows up as "logged in" and only fails on the first request — which is
# how a dead key can sit in the data dir unnoticed (SECURITY.md, A6). This
# probe makes a cheap, read-only API call per provider and reports the result.
#
# Usage:
#   scripts/check-keys.sh [--data-dir DIR] [--auth-file FILE] [--provider NAME]
#                         [--timeout SECS] [--quiet]
#
# Defaults: --data-dir $PI_DATA_DIR (or .pi-data), --timeout 15.
#          --auth-file overrides the "<data-dir>/agent/auth.json" path, which is
#          handy when probing a backup or a copied config.
#
# Exit codes: 0 all probes passed (or no known provider to probe),
#             1 at least one probe failed,
#             2 setup problem (missing/unreadable auth.json, missing curl).
#
# Keys are never printed: only the provider name, a masked fingerprint and the
# HTTP status.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${PI_DATA_DIR:-$ROOT/.pi-data}"
AUTH_FILE=""
PROVIDER_FILTER=""
TIMEOUT=15
QUIET=0

# curl is injectable so the test suite can run hermetically.
CURL_BIN="${PI_CHECK_KEYS_CURL:-curl}"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-dir)  DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
        --auth-file) AUTH_FILE="${2:?--auth-file needs a value}"; shift 2 ;;
        --provider)  PROVIDER_FILTER="${2:?--provider needs a value}"; shift 2 ;;
        --timeout)   TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
        --quiet|-q)  QUIET=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "check-keys: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

AUTH="${AUTH_FILE:-$DATA_DIR/agent/auth.json}"
if [[ ! -f "$AUTH" ]]; then
    echo "check-keys: no credential file at $AUTH" >&2
    echo "            (run 'pi' and /login, or point --data-dir at another instance)" >&2
    exit 2
fi
if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    echo "check-keys: curl not found (set PI_CHECK_KEYS_CURL to an alternative)" >&2
    exit 2
fi

# Print the top-level provider names in auth.json ("deepseek", "opencode", ...).
provider_names() {
    grep -oE '"[A-Za-z0-9_.-]+"[[:space:]]*:[[:space:]]*\{' "$AUTH" \
        | sed -E 's/^"([^"]+)".*/\1/' | sort -u
}

# Print the api key for one provider. Tolerates the key not being the first
# field and ignores nested objects.
provider_key() {
    local name="$1"
    awk -v want="\"$name\"" '
        $0 ~ want { inprov = 1 }
        inprov && match($0, /"key"[[:space:]]*:[[:space:]]*"[^"]*"/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^"key"[[:space:]]*:[[:space:]]*"/, "", s)
            sub(/"$/, "", s)
            print s
            exit
        }
        inprov && /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/ && NR > 0 { }
    ' "$AUTH"
}

mask() {
    local k="$1"
    local n=${#k}
    if (( n <= 10 )); then printf '****'; else printf '%s…%s' "${k:0:6}" "${k: -4}"; fi
}

# probe <provider> <key> -> "<http_code> <body_file>"
probe() {
    local provider="$1" key="$2"
    local body
    body="$(mktemp)"

    local code
    case "$provider" in
        deepseek)
            code="$("$CURL_BIN" -s -o "$body" -w '%{http_code}' --max-time "$TIMEOUT" \
                -H "Authorization: Bearer $key" https://api.deepseek.com/models)"
            ;;
        openai)
            code="$("$CURL_BIN" -s -o "$body" -w '%{http_code}' --max-time "$TIMEOUT" \
                -H "Authorization: Bearer $key" https://api.openai.com/v1/models)"
            ;;
        anthropic)
            code="$("$CURL_BIN" -s -o "$body" -w '%{http_code}' --max-time "$TIMEOUT" \
                -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" \
                https://api.anthropic.com/v1/models)"
            ;;
        google)
            code="$("$CURL_BIN" -s -o "$body" -w '%{http_code}' --max-time "$TIMEOUT" \
                "https://generativelanguage.googleapis.com/v1beta/models?key=$key")"
            ;;
        opencode)
            code="$("$CURL_BIN" -s -o "$body" -w '%{http_code}' --max-time "$TIMEOUT" \
                -H "Authorization: Bearer $key" https://opencode.ai/zen/v1/models)"
            ;;
        *)
            rm -f "$body"
            printf 'n/a '
            return 0
            ;;
    esac

    printf '%s %s' "${code:-000}" "$body"
}

failed=0
checked=0
unknown=0
printed_header=0

for provider in $(provider_names); do
    [[ -n "$PROVIDER_FILTER" && "$provider" != "$PROVIDER_FILTER" ]] && continue

    key="$(provider_key "$provider")"
    if [[ -z "$key" ]]; then
        printf 'SKIP  %-12s no api_key entry\n' "$provider"
        continue
    fi

    if (( QUIET == 0 && printed_header == 0 )); then
        printf '%-6s %-12s %-20s %s\n' "STATUS" "PROVIDER" "KEY" "DETAIL"
        printed_header=1
    fi

    out="$(probe "$provider" "$key")"
    code="${out%% *}"
    body="${out#* }"

    if [[ "$code" == "n/a" ]]; then
        printf 'SKIP  %-12s %-20s no probe defined for this provider\n' "$provider" "$(mask "$key")"
        unknown=$((unknown + 1))
        continue
    fi

    checked=$((checked + 1))
    case "$code" in
        200|204)
            printf 'OK    %-12s %-20s HTTP %s\n' "$provider" "$(mask "$key")" "$code"
            ;;
        401|403)
            detail="HTTP $code — key rejected"
            if [[ "$provider" == "opencode" ]] && grep -q 'FreeTierError' "$body" 2>/dev/null; then
                detail="HTTP $code — OpenCode free tier only works inside OpenCode; needs paid Zen credit"
            fi
            printf 'FAIL  %-12s %-20s %s\n' "$provider" "$(mask "$key")" "$detail"
            failed=$((failed + 1))
            ;;
        000)
            printf 'FAIL  %-12s %-20s no response (network/proxy/DNS?)\n' "$provider" "$(mask "$key")"
            failed=$((failed + 1))
            ;;
        *)
            printf 'FAIL  %-12s %-20s HTTP %s\n' "$provider" "$(mask "$key")" "$code"
            failed=$((failed + 1))
            ;;
    esac
    [[ -f "$body" ]] && rm -f "$body"
done

if (( checked == 0 )); then
    echo "check-keys: nothing probeable — no known provider with an api_key in $AUTH" >&2
    echo "            if the file has credentials, it may be unreadable: inside the" >&2
    echo "            container the fs-vault shim blocks this path, so run 'make" >&2
    echo "            check-keys' on the host (that is where make targets run)." >&2
    exit 2
fi

echo
if (( failed > 0 )); then
    echo "check-keys: $failed of $checked probe(s) failed"
    exit 1
fi
echo "check-keys: $checked probe(s) passed${unknown:+, $unknown unprobeable}"
