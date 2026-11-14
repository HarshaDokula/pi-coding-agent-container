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
# A mount point is an *empty directory on the host* even while a container is
# using it: the contents belong to the bind source, not to the mount point.
# "Empty" is therefore never a staleness signal. The only proof that a mount
# point is unused is that no container references it, so this script fails
# closed whenever it cannot ask Docker.
inside_container=0
if [[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]]; then
    inside_container=1
fi

prune_ok=0
declare -A is_live=()

if (( inside_container )) && [[ "${PI_MOUNT_SYNC_FORCE:-}" != 1 ]]; then
    # No Docker CLI in here, and /workspace is a bind mount over the scratch
    # root, so the host is the only place that can make this decision.
    if (( check_only )); then
        exit 0
    fi
    note "running inside a container; leaving existing mount points alone (run 'make run' on the host)"
elif command -v docker >/dev/null 2>&1; then
    # Include stopped containers: their mounts still pin the source, and a
    # restart would fail if the mount point disappeared. `docker compose run
    # --rm` removes those containers, so this does not accumulate forever.
    if ! ids="$(docker ps -aq 2>/dev/null)"; then
        (( check_only )) || note "cannot query docker; keeping existing mount points (fix 'docker ps' first)"
    elif [[ -z "$ids" ]]; then
        prune_ok=1
    elif ! inspected="$(docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' $ids 2>/dev/null)"; then
        (( check_only )) || note "cannot inspect docker containers; keeping existing mount points"
    else
        prune_ok=1
        while IFS= read -r dest; do
            [[ "$dest" == /workspace/?* ]] || continue
            leaf="${dest#/workspace/}"
            is_live["${leaf%%/*}"]=1
        done <<<"$inspected"
    fi
elif (( inside_container )) && [[ "${PI_MOUNT_SYNC_FORCE:-}" == 1 ]]; then
    # Tests run the sync inside the container with no Docker CLI. The mount
    # table below is authoritative for this namespace, and FORCE=1 is the
    # caller's explicit assertion that no other container shares the scratch
    # root.
    prune_ok=1
else
    # A host without a usable Docker CLI cannot prove that no running or
    # stopped container uses a mount point. Keep them; creating the ones this
    # run needs is still safe.
    (( check_only )) || note "docker not found; keeping existing mount points (cannot prove they are unused)"
fi

# Authoritative for this namespace (the FORCE=1 path): exact path plus
# device:inode. A bind mount's mount point and every path alias of it share the
# source directory's inode, and a multi-directory scratch root is reachable
# both as /workspace and as <repo>/.pi-workspace. Matching by inode avoids
# treating an alias as an ordinary empty directory.
declare -A is_mountpoint=()
declare -A mount_ids=()
if [[ -r /proc/self/mountinfo ]]; then
    while read -r _ _ _ _ mp _; do
        mp="${mp//\\040/ }"
        is_mountpoint["$mp"]=1
        id="$(stat -c '%d:%i' "$mp" 2>/dev/null || stat -f '%d:%i' "$mp" 2>/dev/null)"
        [[ -n "$id" ]] && mount_ids["$id"]=1
    done < /proc/self/mountinfo
fi

is_mount_point() {
    local p="$1" id
    [[ -n "${is_mountpoint[$p]:-}" ]] && return 0
    id="$(stat -c '%d:%i' "$p" 2>/dev/null || stat -f '%d:%i' "$p" 2>/dev/null)"
    [[ -n "$id" && -n "${mount_ids[$id]:-}" ]]
}

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
    if [[ -n "${is_live[$name]:-}" ]] || is_mount_point "$path" || is_mount_point "$abs"; then
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

# Refuse to mount over files. A bind mount hides whatever is already at the
# mount point, so a leftover directory that still holds work is exactly the
# "I edited the wrong copy" trap. Warning and continuing is not enough: the
# files become invisible and the agent writes into the bind source instead.
if (( check_only == 0 )); then
    for name in "${want[@]}"; do
        [[ -n "$name" ]] || continue
        target="$scratch/$name"
        if [[ -L "$target" ]]; then
            echo "workspace-mounts: ERROR: $target is a symlink; refusing to mount over it" >&2
            exit 1
        fi
        if [[ -e "$target" && ! -d "$target" ]]; then
            echo "workspace-mounts: ERROR: $target exists and is not a directory" >&2
            exit 1
        fi
        if [[ -d "$target" ]] && [[ -n "$(ls -A "$target" 2>/dev/null)" ]]; then
            echo "workspace-mounts: ERROR: $target is not empty." >&2
            echo "  Mounting /workspace/$name would hide its contents. Move them into" >&2
            echo "  the real project, then remove $target and retry." >&2
            exit 1
        fi
        if ! mkdir -p "$target"; then
            echo "workspace-mounts: ERROR: could not create mount point $target" >&2
            exit 1
        fi
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
