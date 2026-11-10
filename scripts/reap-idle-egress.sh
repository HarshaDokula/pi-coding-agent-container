#!/usr/bin/env bash
#
# Remove egress sidecars whose session is over.
#
# `docker compose run` starts the `egress` dependency and does NOT stop it when
# the one-off agent container exits (--rm only covers the run container). Those
# sidecars are harmless in themselves, but each one stays attached to its
# project's `*_pi_network`, so `docker network rm` cannot reclaim that /24 while
# it runs. They also accumulate RAM.
#
# This reaps the safe subset only: an egress container is removed when its
# compose project has NO running `pi-agent` container. A project with a live
# session is never touched, so concurrent sessions keep their proxy (they share
# one per project). Candidates are additionally limited to this tool's image, so
# an unrelated compose project that happens to call a service "egress" is not
# touched.
#
# Usage:  reap-idle-egress.sh [--dry-run]
#         PI_DOCKER=/path/to/docker   (tests; defaults to `docker`)
set -u

docker_bin="${PI_DOCKER:-docker}"
# Matches `image:` in docker-compose.yml / docker-compose.egress.yml.
egress_image="${PI_EGRESS_IMAGE:-local/pi-coding-agent:latest}"
dry=0
case "${1:-}" in
    --dry-run|-n) dry=1 ;;
    "") ;;
    *) echo "reap-idle-egress: unknown argument '$1'" >&2; exit 2 ;;
esac

if ! command -v "$docker_bin" >/dev/null 2>&1; then
    echo "reap-idle-egress: '$docker_bin' not found - skipping"
    exit 0
fi

found=0
removed=0

# One line per running egress sidecar: <container id> TAB <compose project>.
while IFS=$'\t' read -r id project; do
    [[ -n "$id" && -n "$project" ]] || continue
    found=$((found + 1))

    # Any live agent container in the same project means the proxy is in use.
    live="$("$docker_bin" ps -q \
        --filter "label=com.docker.compose.project=$project" \
        --filter "label=com.docker.compose.service=pi-agent" 2>/dev/null | head -1)"
    if [[ -n "$live" ]]; then
        continue
    fi

    if [[ "$dry" -eq 1 ]]; then
        echo "would remove idle egress: $project ($id)"
    elif "$docker_bin" rm -f "$id" >/dev/null 2>&1; then
        echo "removed idle egress: $project"
    else
        echo "could not remove egress $project ($id)" >&2
        continue
    fi
    removed=$((removed + 1))
done < <("$docker_bin" ps \
    --filter "label=com.docker.compose.service=egress" \
    --filter "ancestor=$egress_image" \
    --format '{{.ID}}\t{{.Label "com.docker.compose.project"}}' 2>/dev/null)

if [[ "$found" -eq 0 ]]; then
    echo "No egress sidecars running."
elif [[ "$removed" -eq 0 ]]; then
    echo "All egress sidecars belong to live sessions."
fi

exit 0
