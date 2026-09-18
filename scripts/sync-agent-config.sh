#!/usr/bin/env bash
#
# sync-agent-config.sh — replicate the canonical pi agent config to other
# instances. Manual, one-shot. This is deliberately NOT wired into
# `make setup`/seeding: run it yourself after changing the default `.pi-data`.
#
# Usage:
#   scripts/sync-agent-config.sh [options]
#
# Options:
#   --from DIR       Source data dir (the dir that contains agent/).
#                    Default: <repo>/.pi-data
#   --to DIR         Target data dir (repeatable). Default: every
#                    <repo>/.pi-data-pi-agent-* that already has an agent/ dir.
#   --root DIR       Repo root used for target discovery. Default: the repo
#                    this script lives in.
#   --files "LIST"   Space-separated file names to copy.
#                    Default: "auth.json models.json settings.json models-store.json"
#   --dry-run        Print what would change; write nothing.
#   --no-backup      Overwrite without saving <file>.bak next to the target.
#   -h, --help       Show this help.
#
# Behaviour:
#   * Only files present in the source are copied; missing ones are skipped and
#     nothing is ever deleted from a target.
#   * Credential/model files (auth.json, models.json, models-store.json) are
#     chmod 600; settings.json is chmod 644.
#   * An existing target file is backed up to <file>.bak before being replaced
#     (unless --no-backup), only when its content actually differs.
#   * The source data dir is never modified.
#
# Exit codes: 0 = success (including "already up to date"),
#             1 = usage/config error or nothing to sync.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(dirname "$SCRIPT_DIR")"

ROOT="$DEFAULT_ROOT"
FROM="$DEFAULT_ROOT/.pi-data"
FILES="auth.json models.json settings.json models-store.json"
DRY_RUN=0
BACKUP=1
TARGETS=()

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 && !/^$/ { exit }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    FROM="${2:?sync: --from requires a value}"; shift 2 ;;
    --to)      TARGETS+=("${2:?sync: --to requires a value}"); shift 2 ;;
    --root)    ROOT="${2:?sync: --root requires a value}"; shift 2 ;;
    --files)   FILES="${2:?sync: --files requires a value}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-backup) BACKUP=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "sync: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

FROM="$(cd "$FROM" 2>/dev/null && pwd || true)"
if [ -z "$FROM" ] || [ ! -d "$FROM/agent" ]; then
  echo "sync: source agent dir not found (looked for ${FROM:-<missing>}/agent)" >&2
  exit 1
fi
SRC_AGENT="$FROM/agent"

# Any source file to sync at all?
have_source=0
for f in $FILES; do
  [ -f "$SRC_AGENT/$f" ] && have_source=1
done
if [ "$have_source" -eq 0 ]; then
  echo "sync: nothing to sync — none of [$FILES] exist in $SRC_AGENT" >&2
  exit 1
fi

# Discover targets when none were given explicitly.
if [ "${#TARGETS[@]}" -eq 0 ]; then
  shopt -s nullglob
  for d in "$ROOT"/.pi-data-pi-agent-*; do
    [ -d "$d/agent" ] && TARGETS+=("$d")
  done
  shopt -u nullglob
fi

# Normalize and validate targets.
VALID=()
for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
  [ -n "$t" ] || continue
  abs="$(cd "$t" 2>/dev/null && pwd || true)"
  if [ -z "$abs" ] || [ ! -d "$abs/agent" ]; then
    echo "sync: skipping (no agent/ dir): $t" >&2
    continue
  fi
  if [ "$abs" = "$FROM" ]; then
    echo "sync: skipping source: $t" >&2
    continue
  fi
  VALID+=("$abs")
done

if [ "${#VALID[@]}" -eq 0 ]; then
  echo "sync: no target instances to update (looked under $ROOT/.pi-data-pi-agent-*)" >&2
  exit 1
fi

echo "sync: source = $SRC_AGENT"
[ "$DRY_RUN" -eq 1 ] && echo "sync: DRY RUN — no files will be written"

total_changed=0
total_instances=0

for t in "${VALID[@]}"; do
  total_instances=$((total_instances + 1))
  echo "sync: -> $t"
  instance_changed=0
  for f in $FILES; do
    src="$SRC_AGENT/$f"
    dst="$t/agent/$f"
    [ -f "$src" ] || continue

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
      printf '        %-18s unchanged\n' "$f"
      continue
    fi

    if [ -f "$dst" ]; then action=updated; else action=added; fi
    printf '        %-18s %s\n' "$f" "$action"
    instance_changed=1
    total_changed=$((total_changed + 1))
    [ "$DRY_RUN" -eq 1 ] && continue

    if [ -f "$dst" ] && [ "$BACKUP" -eq 1 ]; then
      cp -p "$dst" "$dst.bak" 2>/dev/null || cp "$dst" "$dst.bak"
    fi

    # Create the replacement with tight permissions from the start, then move
    # it into place atomically so a credential is never briefly world-readable.
    tmp="$dst.tmp.$$"
    ( umask 077; cp "$src" "$tmp" )
    case "$f" in
      settings.json) chmod 644 "$tmp" ;;
      *)             chmod 600 "$tmp" ;;
    esac
    mv -f "$tmp" "$dst"
  done
  [ "$instance_changed" -eq 0 ] && printf '        %s\n' "(already up to date)"
done

echo "sync: $total_instances instance(s), $total_changed file(s) $([ "$DRY_RUN" -eq 1 ] && echo 'would change' || echo 'changed')"
if [ "$DRY_RUN" -eq 0 ] && [ "$total_changed" -gt 0 ]; then
  echo "sync: restart any running containers (pictl / make run) to load the new config."
fi
