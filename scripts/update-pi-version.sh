#!/usr/bin/env bash
#
# Resolve (or pin) the pi version baked into the image.
#
# Used by `make update`, which needs three separate operations:
#
#   update-pi-version.sh                 resolve latest from pi.dev, print it
#   update-pi-version.sh --version X.Y.Z print X.Y.Z (explicit pin, no network)
#   update-pi-version.sh --fallback X.Y.Z
#                                        resolve latest, but print X.Y.Z with a
#                                        warning if pi.dev cannot be reached
#   update-pi-version.sh --save X.Y.Z    record X.Y.Z as PI_VERSION in .env
#
# Nothing is written to .env except by --save. `make update` saves the pin only
# after the image built successfully, so a failed upgrade cannot leave the repo
# pinned to a version that was never built.
#
# The resolved version is printed to stdout; progress/warnings go to stderr, so
# callers can capture the version without parsing prose.
#
# Environment:
#   PI_ENV_FILE             file updated by --save (default: .env)
#   PI_LATEST_VERSION_URL   release metadata URL (default: pi.dev; tests use file://)
set -euo pipefail

ENV_FILE="${PI_ENV_FILE:-.env}"
URL="${PI_LATEST_VERSION_URL:-https://pi.dev/api/latest-version}"
EXPECTED_PACKAGE="@earendil-works/pi-coding-agent"

mode="resolve"          # resolve | version | save
explicit_version=""
fallback_version=""
version_requested=0

usage() {
    cat <<'EOF'
usage: update-pi-version.sh [--version X.Y.Z] [--fallback X.Y.Z] [--save X.Y.Z]

Default            resolve the latest pi release from pi.dev and print it.
--version X.Y.Z    print X.Y.Z without network access (explicit pin).
--fallback X.Y.Z   resolve latest, but print X.Y.Z with a warning if the
                   release metadata cannot be fetched or parsed.
--save X.Y.Z       record X.Y.Z as PI_VERSION in .env (nothing else).

Environment: PI_ENV_FILE (default .env), PI_LATEST_VERSION_URL (override source)
EOF
}

valid_version() {
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { echo "update-pi-version: --version needs a value" >&2; exit 2; }
            version_requested=1; explicit_version="$2"; mode="version"; shift 2 ;;
        --version=*)
            version_requested=1; explicit_version="${1#*=}"; mode="version"; shift ;;
        --fallback)
            [[ $# -ge 2 ]] || { echo "update-pi-version: --fallback needs a value" >&2; exit 2; }
            fallback_version="$2"; shift 2 ;;
        --fallback=*)
            fallback_version="${1#*=}"; shift ;;
        --save)
            [[ $# -ge 2 ]] || { echo "update-pi-version: --save needs a value" >&2; exit 2; }
            explicit_version="$2"; mode="save"; shift 2 ;;
        --save=*)
            explicit_version="${1#*=}"; mode="save"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "update-pi-version: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$version_requested" -eq 1 && -z "$explicit_version" ]]; then
    echo "update-pi-version: --version needs a non-empty value" >&2
    exit 2
fi

# Record a pin. Follows a symlinked .env instead of replacing the link, keeps
# the file mode, and preserves an existing `export PI_VERSION=...` style.
save_version() {
    local version="$1" current="" target dir tmp prefix=""
    if [[ -f "$ENV_FILE" ]]; then
        current="$(grep -E '^[[:space:]]*(export[[:space:]]+)?PI_VERSION=' "$ENV_FILE" 2>/dev/null \
            | tail -1 \
            | sed -E 's/^[[:space:]]*(export[[:space:]]+)?PI_VERSION=//' || true)"
    fi
    if [[ "$current" == "$version" ]]; then
        echo "pi is already pinned to $version in $ENV_FILE" >&2
        return 0
    fi

    target="$ENV_FILE"
    if [[ -L "$ENV_FILE" ]]; then
        local link
        link="$(readlink "$ENV_FILE")"
        case "$link" in
            /*) target="$link" ;;
            *) target="$(dirname "$ENV_FILE")/$link" ;;
        esac
    fi

    dir="$(dirname "$target")"
    tmp="$(mktemp "$dir/.pi-version.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    if [[ -f "$target" ]]; then
        grep -v -E '^[[:space:]]*(export[[:space:]]+)?PI_VERSION=' "$target" > "$tmp" || true
        if grep -Eq '^[[:space:]]*export[[:space:]]+PI_VERSION=' "$target"; then
            prefix="export "
        fi
        chmod --reference="$target" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    else
        : > "$tmp"
        chmod 600 "$tmp"
    fi
    printf '%sPI_VERSION=%s\n' "$prefix" "$version" >> "$tmp"
    mv "$tmp" "$target"
    trap - EXIT

    echo "pinned pi $version in $ENV_FILE (was ${current:-unset})" >&2
}

# Rescue the offline/no-metadata path: keep the current pin instead of failing
# a no-cache rebuild that would have worked before this upgrade command existed.
use_fallback_or_fail() {
    local reason="$1"
    if [[ -n "$fallback_version" ]]; then
        if ! valid_version "$fallback_version"; then
            echo "update-pi-version: $reason; fallback '$fallback_version' is not a valid version" >&2
            exit 1
        fi
        echo "update-pi-version: $reason; rebuilding the pinned $fallback_version" >&2
        printf '%s\n' "$fallback_version"
        exit 0
    fi
    echo "update-pi-version: $reason" >&2
    echo "    (pin a release manually with 'make update PI_VERSION=x.y.z')" >&2
    exit 1
}

if [[ "$mode" == "save" ]]; then
    valid_version "$explicit_version" || {
        echo "update-pi-version: '$explicit_version' is not a valid version" >&2
        exit 1
    }
    save_version "$explicit_version"
    exit 0
fi

if [[ "$mode" == "version" ]]; then
    valid_version "$explicit_version" || {
        echo "update-pi-version: '$explicit_version' is not a valid version" >&2
        exit 1
    }
    printf '%s\n' "$explicit_version"
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    use_fallback_or_fail "curl not found"
fi

metadata=""
if ! metadata="$(curl -fsSL --max-time 15 "$URL" 2>/dev/null)"; then
    use_fallback_or_fail "could not fetch $URL"
fi

# Parse without assuming jq is installed. Node is already required for the
# host-side key scripts; keep a sed fallback for minimal hosts. The output is
# "<version>\t<packageName>" so one pass gets both.
version=""
package_name=""
if command -v node >/dev/null 2>&1; then
    parsed="$(printf '%s' "$metadata" | node -e '
        let raw = "";
        process.stdin.on("data", (chunk) => { raw += chunk; });
        process.stdin.on("end", () => {
            try {
                const data = JSON.parse(raw);
                const version = typeof data.version === "string" ? data.version.trim() : "";
                const packageName = typeof data.packageName === "string" ? data.packageName.trim() : "";
                process.stdout.write(version + "\t" + packageName);
            } catch {}
        });
    ' 2>/dev/null)"
    version="${parsed%%$'\t'*}"
    if [[ "$parsed" == *$'\t'* ]]; then
        package_name="${parsed#*$'\t'}"
    fi
else
    version="$(printf '%s' "$metadata" \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)"
    package_name="$(printf '%s' "$metadata" \
        | sed -n 's/.*"packageName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -1)"
fi

if ! valid_version "$version"; then
    use_fallback_or_fail "$URL did not return a valid version (got '${version:-<empty>}')"
fi

if [[ -n "$package_name" && "$package_name" != "$EXPECTED_PACKAGE" ]]; then
    echo "update-pi-version: $URL points at '$package_name', but the image installs $EXPECTED_PACKAGE" >&2
    exit 1
fi

printf '%s\n' "$version"
