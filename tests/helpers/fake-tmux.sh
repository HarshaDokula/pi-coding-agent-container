#!/usr/bin/env bash
#
# Stub tmux for tests/test-pictl-sessions.sh.
#
# Records every invocation in $FAKE_TMUX_LOG (one line per call) and answers the
# few queries pictl makes from files under $FAKE_TMUX_STATE:
#
#   has-session -t NAME   -> exit 0 if $FAKE_TMUX_STATE/NAME.exists exists
#   list-sessions         -> print the lines of $FAKE_TMUX_STATE/sessions
#   new-session ...       -> record only
#   attach-session ...    -> record only
#   kill-session -t NAME  -> record, and drop NAME from the sessions file
#
# Lives in the repo (not /tmp) because /tmp is mounted noexec in the container.
set -u

log="${FAKE_TMUX_LOG:-/dev/null}"
state="${FAKE_TMUX_STATE:-/dev/null}"
printf '%s\n' "$*" >> "$log"

cmd="${1:-}"
case "$cmd" in
    has-session)
        target=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -t) target="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$target" && -f "$state/$target.exists" ]] && exit 0
        exit 1
        ;;
    list-sessions)
        [[ -f "$state/sessions" ]] || exit 1
        fmt=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -F) fmt="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        # pictl asks for "#{session_name}\t#{@pi_workspace}\t#{t:session_created}";
        # emit name + empty workspace + a fixed timestamp.
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            if [[ "$fmt" == *"#{session_name}"* ]]; then
                printf '%s\t\t12:00:00\n' "$name"
            else
                printf '%s\n' "$name"
            fi
        done < "$state/sessions"
        exit 0
        ;;
    kill-session)
        target=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -t) target="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$target" && -f "$state/$target.exists" ]] || exit 1
        rm -f "$state/$target.exists"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
