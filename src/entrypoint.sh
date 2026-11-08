#!/bin/sh
# Container entrypoint.
#
# When MISE_BOOTSTRAP=1, install the toolchain(s) the workspace declares before
# starting pi. Manifests are looked for at the workspace root and one level down,
# because a multi-directory run mounts each project at /workspace/<name>.
#
# Everything lands in MISE_DATA_DIR (the pi_toolchains volume), so the first run
# downloads and every later run is a no-op. A failed install must not cost you
# the session, but it has to be loud: the next `node`/`python` call would
# otherwise fail mysteriously.
set -u

# PI_WORKSPACE_DIR exists so this script can be tested outside a container.
WS="${PI_WORKSPACE_DIR:-/workspace}"

has_manifest() {
    [ -f "$1/mise.toml" ] || [ -f "$1/.mise.toml" ] || [ -f "$1/.tool-versions" ]
}

if [ "${MISE_BOOTSTRAP:-0}" = "1" ]; then
    installed=0
    for dir in "$WS" "$WS"/*/; do
        # Trim the trailing slash the glob leaves on directories.
        dir="${dir%/}"
        has_manifest "$dir" || continue
        echo "pi: bootstrapping toolchains for $dir (mise)" >&2
        if mise -C "$dir" install; then
            installed=$((installed + 1))
        else
            echo "pi: WARNING - mise install failed for $dir; the declared tool" >&2
            echo "    versions may be missing or stale. Retry inside the session" >&2
            echo "    with: mise -C $dir install" >&2
        fi
    done

    if [ "$installed" -gt 0 ]; then
        mise reshim >/dev/null 2>&1 || true
    else
        echo "pi: MISE_BOOTSTRAP=1 but no mise.toml/.tool-versions under $WS - skipping" >&2
    fi
fi

exec pi "$@"
