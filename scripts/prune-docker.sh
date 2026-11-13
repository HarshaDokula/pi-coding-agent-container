#!/usr/bin/env bash
#
# Reclaim disk space from repeated image rebuilds.
#
# Every rebuild retags local/pi-coding-agent:latest, so the previous image
# becomes untagged ("dangling"). BuildKit also keeps cache records for the
# builds, including --no-cache ones. Docker does not prune either automatically.
#
# Usage: prune-docker.sh [--dry-run] [--images-only] [--cache-age AGE]
#
# By default this removes dangling images and the whole BuildKit cache.
# Dangling images are untagged and unreferenced, so removing them is safe.
# Build cache is rebuildable, but it is shared by every project on the daemon,
# not just this one.
#
# --images-only removes dangling images without touching the build cache.
# --cache-age AGE limits the cache prune to entries older than AGE (e.g. 24h).
#
# Environment:
#   PI_DOCKER=/path/to/docker   use another docker binary (tests)
#   PI_PRUNE_CACHE_AGE=AGE      default for --cache-age
set -u

docker_bin="${PI_DOCKER:-docker}"
dry=0
images_only=0
cache_age="${PI_PRUNE_CACHE_AGE:-}"

usage() {
    cat <<'EOF'
usage: prune-docker.sh [--dry-run] [--images-only] [--cache-age AGE]

  --dry-run, -n     print what would run, change nothing
  --images-only     only remove dangling images (keep the build cache)
  --cache-age AGE   only remove build-cache entries older than AGE (e.g. 24h)

Without --cache-age, the whole BuildKit cache is removed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) dry=1; shift ;;
        --images-only) images_only=1; shift ;;
        --cache-age)
            [[ $# -ge 2 ]] || { echo "prune-docker: --cache-age needs a value" >&2; exit 2; }
            cache_age="$2"; shift 2 ;;
        --cache-age=*) cache_age="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "prune-docker: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# Accept both "24h" and Docker's "until=24h" spelling.
cache_age="${cache_age#until=}"

if ! command -v "$docker_bin" >/dev/null 2>&1; then
    echo "prune-docker: '$docker_bin' not found - skipping"
    exit 0
fi

run_prune() {
    if [[ "$dry" -eq 1 ]]; then
        printf 'would run: %s\n' "$*"
        return 0
    fi
    "$@"
}

rc=0
run_prune "$docker_bin" image prune -f || rc=1

if [[ "$images_only" -eq 0 ]]; then
    if [[ -n "$cache_age" ]]; then
        run_prune "$docker_bin" builder prune -f --filter "until=$cache_age" || rc=1
    else
        run_prune "$docker_bin" builder prune -f || rc=1
    fi
fi

exit "$rc"
