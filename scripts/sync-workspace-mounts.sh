#!/usr/bin/env bash
#
# sync-workspace-mounts.sh — keep the mount points under .pi-workspace in sync
# with the directories of the current run.
#
# A multi-directory run (`make run WORK_DIR="a b"`, `pictl a b`) uses
# <repo>/.pi-workspace as the container's /workspace root and bind-mounts each
# project at /workspace/<basename>. That root is persistent and shared by every
# combo, so without cleanup /workspace accumulates one empty directory per
# project name ever passed to a multi-directory run. Those leftovers look like
# mounted projects but are not, and because /workspace is writable, writes aimed
# at "the project" can land in .pi-workspace/<name> on the host instead.
#
# This script (1) removes the empty mount points left by earlier runs and
# (2) creates the ones the current run needs.
#
# Usage:
#   scripts/sync-workspace-mounts.sh SCRATCH_ROOT NAME...
#   scripts/sync-workspace-mounts.sh --check SCRATCH_ROOT [NAME...]
#
# --check reports what a real run would remove and changes nothing. Each entry
# is printed on stdout as one of:
#   stale <path>
#   keep  <path> <reason>
# In apply mode that listing is captured by the Makefile, so removals and
# leftovers that hold files are repeated on stderr where you can see them.
#
# Safety rules: only *empty* directories are removed (a stale entry that still
# has files is reported and left alone — it may hold work an agent wrote into
# the wrong /workspace path), never a symlink, and never a path that a running
# container has bind-mounted. Inside a container there is no Docker CLI to prove
# that, so pruning is skipped there unless PI_MOUNT_SYNC_FORCE=1.

set -uo pipefail

check_only=0
if [[ "${1:-}" == "--check" ]]; then
    check_only=1
    shift
fi

if [[ $# -lt 1 ]]; then
    echo "usage: $(basename "$0") [--check] SCRATCH_ROOT NAME..." >&2
    exit 2
fi

scratch="$1"
shift
want=("$@")

# Non-fatal diagnostics go to stderr: the Makefile captures stdout of $(shell).
note() { printf 'workspace-mounts: %s\n' "$*" >&2; }

[[ -d "$scratch" ]] || exit 0
scratch="$(cd "$scratch" && pwd -P)" || exit 0

declare -A wanted=()
for name in "${want[@]}"; do
    [[ -n "$name" ]] && wanted["$name"]=1
done
if (( check_only == 0 )) && (( ${#wanted[@]} == 0 )); then
    echo "usage: $(basename "$0") SCRATCH_ROOT NAME... (refusing to prune with no mount points to keep)" >&2
    exit 2
fi

# --- can we safely prune? ---------------------------------------------------
# Inside a container there is no Docker CLI to prove a mount point is unused,
# and its /workspace hides the underlying scratch root behind a bind mount, so
# the host is both the safe and the only meaningful place to do this.
prune_ok=1
if [[ "${PI_MOUNT_SYNC_FORCE:-}" != 1 ]] && { [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]]; }; then
    if (( check_only )); then
        exit 0
    fi
    note "running inside a container; leaving existing mount points alone (run 'make run' on the host)"
    prune_ok=0
fi

# A mount point is in use while a running container has a workspace mounted
# there. In a multi-directory run the container sees the scratch root at
# /workspace and each project at /workspace/<name>, so the leaf name of any
# /workspace/* mount is a mount point that must survive. No Docker CLI means no
# running container can be using one. A Docker CLI that exists but does not
# answer is different: then we cannot prove nobody is using them, so prune
# nothing.
declare -A is_live=()
if (( prune_ok )) && command -v docker >/dev/null 2>&1; then
    if ! ids="$(docker ps -q 2>/dev/null)"; then
        prune_ok=0
        (( check_only )) || note "cannot query docker; skipping cleanup (fix 'docker ps' first)"
    elif [[ -n "$ids" ]]; then
        # shellcheck disable=SC2086 # word splitting of container ids is intended
        while IFS= read -r dest; do
            [[ "$dest" == /workspace/?* ]] || continue
            leaf="${dest#/workspace/}"
            is_live["${leaf%%/*}"]=1
        done < <(docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' $ids 2>/dev/null)
    fi
fi

# Last line of defence where there is no Docker CLI: this process's own mount
# table. Matched by exact path only - a bind mount is attached to one path, and
# the same directory is reachable through aliases that the kernel resolves to
# the underlying tree, so alias resolution answers the wrong question.
declare -A is_mountpoint=()
if [[ -r /proc/self/mountinfo ]]; then
    while read -r _ _ _ _ mp _; do
        is_mountpoint["${mp//\\040/ }"]=1
    done < /proc/self/mountinfo
fi

# --- classify existing entries ---------------------------------------------
stale_paths=()
stale_names=()
kept_full=()
for path in "$scratch"/*; do
    [[ -e "$path" || -L "$path" ]] || continue
    name="$(basename "$path")"
    [[ -n "${wanted[$name]:-}" ]] && continue

    if [[ -L "$path" ]]; then
        printf 'keep  %s symlink\n' "$path"
        continue
    fi
    if [[ ! -d "$path" ]]; then
        printf 'keep  %s not-a-directory\n' "$path"
        continue
    fi
    abs="$(cd "$path" && pwd -P)" || continue
    if [[ -n "${is_live[$name]:-}" || -n "${is_mountpoint[$path]:-}" || -n "${is_mountpoint[$abs]:-}" ]]; then
        printf 'keep  %s in-use\n' "$path"
        continue
    fi
    if [[ -n "$(ls -A "$path" 2>/dev/null)" ]]; then
        printf 'keep  %s not-empty\n' "$path"
        kept_full+=("$path")
        continue
    fi
    stale_paths+=("$path")
    stale_names+=("$name")
done

# --- act --------------------------------------------------------------------
removed=0
removed_names=()
if ((${#stale_paths[@]})); then
    if (( check_only )); then
        for path in "${stale_paths[@]}"; do
            printf 'stale %s\n' "$path"
        done
    elif (( prune_ok )); then
        for i in "${!stale_paths[@]}"; do
            path="${stale_paths[$i]}"
            if err="$(rmdir "$path" 2>&1)"; then
                removed=$((removed + 1))
                removed_names+=("${stale_names[$i]}")
            else
                # EBUSY here means something is still using it - never force it.
                note "could not remove $path: ${err#rmdir: }"
            fi
        done
    fi
fi

# A mount point we are about to create that already holds files will be hidden
# by the bind mount, which is exactly the "I edited the wrong copy" trap.
if (( check_only == 0 )); then
    for name in "${want[@]}"; do
        [[ -n "$name" ]] || continue
        target="$scratch/$name"
        if [[ -d "$target" ]] && [[ -n "$(ls -A "$target" 2>/dev/null)" ]]; then
            note "$target is not empty; its contents will be hidden by the bind mount"
        fi
        mkdir -p "$target" || note "could not create mount point $target"
    done
fi

if (( removed > 0 )); then
    note "removed $removed stale mount point(s) left by earlier runs: ${removed_names[*]:-}"
fi
# The classification output is captured by the Makefile, so say the interesting
# part out loud: a leftover that holds files is not ours to delete, but it is
# exactly the path an agent may have written to by mistake.
if (( check_only == 0 )); then
    for path in "${kept_full[@]:-}"; do
        [[ -n "$path" ]] && note "kept $path (holds files): move them into the real project, then delete the directory"
    done
fi
exit 0
