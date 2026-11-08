#!/bin/sh
# Container entrypoint.
#
# Runs `mise install` once per project when MISE_BOOTSTRAP=1 and the workspace
# declares a toolchain (mise.toml, .tool-versions, or .mise.toml), then hands
# over to pi. Toolchains land in the pi_toolchains volume, so the second run is
# a no-op.
#
# Deliberately non-fatal: a failed install must not cost you the session, but it
# has to be loud, otherwise the next `node`/`python` call fails mysteriously.
set -u

# PI_WORKSPACE_DIR exists so the script can be tested outside a container.
WS="${PI_WORKSPACE_DIR:-/workspace}"

if [ "${MISE_BOOTSTRAP:-0}" = "1" ]; then
    manifest=""
    for f in "$WS/mise.toml" "$WS/.mise.toml" "$WS/.tool-versions"; do
        [ -f "$f" ] && { manifest="$f"; break; }
    done

    if [ -n "$manifest" ]; then
        echo "pi: bootstrapping toolchains from $(basename "$manifest") (mise)" >&2
        if ! mise install; then
            echo "pi: WARNING - mise install failed; the declared tool versions may be" >&2
            echo "    missing or stale. Retry inside the session with: mise install" >&2
        fi
        mise reshim >/dev/null 2>&1 || true
    else
        echo "pi: MISE_BOOTSTRAP=1 but no mise.toml/.tool-versions in $WS - skipping" >&2
    fi
fi

exec pi "$@"
