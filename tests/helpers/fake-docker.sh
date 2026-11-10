#!/usr/bin/env bash
#
# Stub `docker` for tests of scripts/reap-idle-egress.sh (and, later, anything
# that needs a fake engine). Records every invocation in $FAKE_DOCKER_LOG and
# answers from files under $FAKE_DOCKER_STATE:
#
#   containers        lines of   id|compose-project|compose-service
#   networks          lines of   id|name
#   networks-inuse    one network NAME per line; `network rm` fails for these
#
# Supported calls (the subset the reaper and `make net-clean` use):
#   ps [-q] [--filter label=K=V]... [--format FMT]
#   rm -f ID...
#   network ls [--format FMT]
#   network rm ID...
#
# Lives in the repo (not /tmp) because /tmp is mounted noexec in the container.
set -u

log="${FAKE_DOCKER_LOG:-/dev/null}"
state="${FAKE_DOCKER_STATE:-}"
printf '%s\n' "$*" >> "$log"

containers="$state/containers"
networks="$state/networks"
inuse="$state/networks-inuse"

cmd="${1:-}"
shift || true

drop_line() { # drop_line FILE PREFIX
    local file="$1" prefix="$2"
    [[ -f "$file" ]] || return 0
    grep -v "^${prefix}" "$file" > "$file.tmp" 2>/dev/null || :
    mv "$file.tmp" "$file"
}

case "$cmd" in
    ps)
        quiet=0
        filters=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -q|--quiet) quiet=1; shift ;;
                --filter) filters+=("${2#label=}"); shift 2 ;;
                --format) shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -f "$containers" ]] || exit 0
        while IFS='|' read -r id project service; do
            [[ -n "${id:-}" ]] || continue
            match=1
            for f in "${filters[@]:-}"; do
                [[ -n "$f" ]] || continue
                key="${f%%=*}"
                want="${f#*=}"
                case "$key" in
                    com.docker.compose.project) [[ "$project" == "$want" ]] || match=0 ;;
                    com.docker.compose.service) [[ "$service" == "$want" ]] || match=0 ;;
                esac
            done
            [[ "$match" -eq 1 ]] || continue
            if [[ "$quiet" -eq 1 ]]; then
                printf '%s\n' "$id"
            else
                printf '%s\t%s\n' "$id" "$project"
            fi
        done < "$containers"
        ;;
    rm)
        for id in "$@"; do
            [[ "$id" == -* ]] && continue
            printf 'rm %s\n' "$id" >> "$log"
            drop_line "$containers" "${id}|"
        done
        ;;
    network)
        sub="${1:-}"
        shift || true
        case "$sub" in
            ls)
                [[ -f "$networks" ]] || exit 0
                while IFS='|' read -r id name; do
                    [[ -n "${id:-}" ]] || continue
                    printf '%s %s\n' "$id" "$name"
                done < "$networks"
                ;;
            rm)
                rc=0
                for id in "$@"; do
                    [[ "$id" == -* ]] && continue
                    name="$(grep "^${id}|" "$networks" 2>/dev/null | head -1 | cut -d'|' -f2)"
                    [[ -n "$name" ]] || continue
                    if [[ -f "$inuse" ]] && grep -qx "$name" "$inuse"; then
                        printf 'network rm %s in-use\n' "$name" >> "$log"
                        rc=1
                        continue
                    fi
                    printf 'network rm %s\n' "$name" >> "$log"
                    drop_line "$networks" "${id}|"
                done
                exit "$rc"
                ;;
        esac
        ;;
esac
exit 0
