#!/bin/bash
# Seeds a fresh per-project pi data dir with the agent config from the default
# .pi-data dir, so new instances (make run PROJECT_NAME=...) start with the
# same provider login/models instead of "No models available".
#
# Usage: ./scripts/seed-agent-config.sh <target-pi-data-dir> [default-pi-data-dir]
#
# Only seeds when the target has no configured provider yet (auth.json is
# missing, empty, or the "{}" logged-out stub). Sessions are never copied:
# each instance keeps its own session state. Existing target files are never
# overwritten.
#
# Also copies agent/bin (the fd/rg tools pi may have downloaded into the
# default .pi-data) so fresh instances of older images don't re-download
# them on first startup.

set -u

TARGET="${1:-}"
DEFAULT="${2:-.pi-data}"

TARGET_ABS="$(cd "$TARGET" 2>/dev/null && pwd || true)"
DEFAULT_ABS="$(cd "$DEFAULT" 2>/dev/null && pwd || true)"

# Nothing to seed from, or target is the default dir itself.
if [ -z "$DEFAULT_ABS" ] || [ -z "$TARGET_ABS" ] || [ "$TARGET_ABS" = "$DEFAULT_ABS" ]; then
  exit 0
fi

# Only seed if the target has no real auth config yet.
auth="$TARGET_ABS/agent/auth.json"
needs_seed=0
if [ ! -f "$auth" ] || [ ! -s "$auth" ]; then
  needs_seed=1
else
  trimmed="$(tr -d '[:space:]' < "$auth" 2>/dev/null)"
  if [ "$trimmed" = "{}" ]; then
    needs_seed=1
  fi
fi

if [ "$needs_seed" -ne 1 ]; then
  exit 0
fi

echo "==> Seeding $TARGET with agent config from $DEFAULT (provider login, settings, skills, extensions, tools)"

mkdir -p "$TARGET_ABS/agent"

# Provider login, model cache, and settings. We only get here when the target
# has no real auth config (see needs_seed above), so these are safe to copy
# wholesale — they preserve the deepseek (or other) login.
for f in auth.json models-store.json settings.json; do
  if [ -f "$DEFAULT_ABS/agent/$f" ]; then
    cp "$DEFAULT_ABS/agent/$f" "$TARGET_ABS/agent/$f"
  fi
done

# Copy skills/extensions only if the target doesn't have them yet, and never
# clobber anything the user placed there.
for d in skills extensions; do
  if [ -d "$DEFAULT_ABS/agent/$d" ] && [ ! -e "$TARGET_ABS/agent/$d" ]; then
    cp -r "$DEFAULT_ABS/agent/$d" "$TARGET_ABS/agent/$d"
  fi
done

# Copy the managed tools dir (fd, rg) only if the target doesn't have one, so
# fresh instances don't re-download these tools on first startup. Only matters
# for images built before fd/rg were apt-installed; harmless otherwise.
if [ -d "$DEFAULT_ABS/agent/bin" ] && [ ! -e "$TARGET_ABS/agent/bin" ]; then
  cp -r "$DEFAULT_ABS/agent/bin" "$TARGET_ABS/agent/bin"
  echo "  ==> Copied agent/bin (fd, rg) to $TARGET_ABS/agent/bin"
fi
