# syntax=docker/dockerfile:1

# Base image is pinned by digest so a rebuild cannot silently pick up a
# different image (SECURITY.md, C4). Bump both the tag and the digest together:
#   docker buildx imagetools inspect node:26-trixie-slim
ARG NODE_IMAGE=node:26-trixie-slim@sha256:36793bcbb160a6a16cede1e62b93f84e26b78a972a8a4c0b879c1c12f22761ec

# -----------------------------------------------------------------------------
# Builder: the only stage with a C toolchain. Compiles the two LD_PRELOAD / gh
# vault binaries and hands the artefacts to the runtime image, so the shipped
# image has no compiler (SECURITY.md, C2 — a compiler is what lets the agent
# build a static binary and walk around the preload shims).
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

COPY src/gh-vault.c /src/gh-vault.c
COPY src/fs-vault.c /src/fs-vault.c

RUN mkdir -p /out \
    && gcc -O2 -Wall /src/gh-vault.c -o /out/gh \
    && gcc -shared -fPIC -O2 -Wall /src/fs-vault.c -o /out/fs-vault.so -ldl

# -----------------------------------------------------------------------------
# Runtime base
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS base

ENV NODE_ENV=production
ENV DEBIAN_FRONTEND=noninteractive
ENV NPM_CONFIG_LOGLEVEL=warn
ENV HOME=/home/node

# Runtime dependencies only: no build-essential, no python3-dev. The Python
# interpreter and pip are kept because running Python is a core agent task, and
# `make` is kept because it is a build *driver*, not a compiler — without gcc it
# cannot produce the static binaries that defeat the preload shims. Compilers
# are opt-in via PI_WITH_TOOLCHAIN=1 (below).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    netcat-openbsd \
    make \
    curl \
    wget \
    ca-certificates \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Opt-in escape hatch: some workflows need to build native modules at runtime
# (pip/npm sdist installs). This restores the toolchain but re-opens the
# static-binary bypass, so it is off by default.
ARG PI_WITH_TOOLCHAIN=0
RUN if [ "$PI_WITH_TOOLCHAIN" = "1" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends build-essential python3-dev \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# -----------------------------------------------------------------------------
# SSH transport through the egress proxy
#
# With EGRESS on, the container sits on an internal network: no route out and no
# external DNS. `ssh` therefore cannot resolve a hostname and, if it cannot
# resolve it, never reaches the proxy either — which is what broke git over SSH.
# A ProxyCommand in ssh_config fixes it because ssh expands %h/%p itself and
# hands the name to the proxy. The helper falls back to a direct connection when
# no proxy is configured, so EGRESS=false keeps working.
# -----------------------------------------------------------------------------
COPY src/ssh-netcat-proxy.sh /usr/local/bin/ssh-netcat-proxy
COPY src/ssh_config.d/ /etc/ssh/ssh_config.d/
RUN chmod 0755 /usr/local/bin/ssh-netcat-proxy \
    && chmod 0644 /etc/ssh/ssh_config.d/90-pi-egress.conf

# -----------------------------------------------------------------------------
# GitHub CLI (apt repository)
#
# The repository keyring is verified against a pinned SHA-256 before it is
# trusted: fetching it over HTTPS and piping it into apt without checking would
# let a compromised mirror or TLS interception sign its own packages
# (SECURITY.md, C4). Update GH_KEYRING_SHA256 when GitHub rotates the key:
#   curl -sL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sha256sum
# -----------------------------------------------------------------------------
ARG GH_KEYRING_SHA256=6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO /tmp/gh-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && echo "${GH_KEYRING_SHA256}  /tmp/gh-keyring.gpg" | sha256sum -c - \
    && mv /tmp/gh-keyring.gpg /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# System Hardening: Purge Privilege Escalation Vectors
# Runs after every apt install so nothing reintroduces a setuid binary.
# -----------------------------------------------------------------------------
RUN rm -f /bin/su /usr/bin/su /bin/mount /usr/bin/mount /bin/umount /usr/bin/umount \
    /usr/bin/passwd /usr/bin/chsh /usr/bin/chfn /usr/bin/chage /usr/bin/gpasswd \
    /usr/bin/newgrp /bin/login /usr/bin/login /usr/bin/nsenter /usr/bin/unshare \
    /usr/bin/setpriv /bin/setpriv \
    && find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec chmod a-s {} + || true

# -----------------------------------------------------------------------------
# The GitHub CLI Guardrail & Vault
#
# `gh` is a small wrapper (built above, no compiler here) that reads the token
# from the Docker secret and execs the guard. It is deliberately NOT setuid:
# compose mounts secrets 0444, so the token is readable by the container user
# anyway and elevation would only add a local privilege-escalation primitive to
# the image (see SECURITY.md, C1).
# -----------------------------------------------------------------------------
COPY --from=builder /out/gh /usr/local/bin/gh
COPY --from=builder /out/fs-vault.so /usr/local/lib/fs-vault.so
COPY src/gh-guard.sh /usr/local/bin/gh-guard
RUN chown root:root /usr/local/bin/gh /usr/local/lib/fs-vault.so /usr/local/bin/gh-guard \
    && chmod 0755 /usr/local/bin/gh /usr/local/bin/gh-guard \
    && chmod 0644 /usr/local/lib/fs-vault.so

# -----------------------------------------------------------------------------
# Comprehensive Application-Layer Firewall (V8 Hook)
# -----------------------------------------------------------------------------
COPY src/app-firewall.js /usr/local/lib/app-firewall.js

# Outbound allowlist proxy used by the egress sidecar (SECURITY.md, B5).
COPY src/egress-proxy.js /usr/local/lib/egress-proxy.js

# Force Node.js to load the firewall before initializing the agent
ENV NODE_OPTIONS="--require /usr/local/lib/app-firewall.js"

FROM base AS release

# Pin the pi source version explicitly. An unpinned `npm install -g` keeps
# whatever `latest` was when the layer was first cached, so the image can run
# an older pi than npm publishes while a rebuild still looks up to date.
# Bump PI_VERSION to upgrade, or override per build:
#   docker compose build --build-arg PI_VERSION=x.y.z
# pi cannot update itself in the container: /usr/local is root-owned.
ARG PI_VERSION=1.4.0
RUN npm install -g "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && pi --version | grep -qx "${PI_VERSION}"

RUN mkdir -p /home/node/.pi/agent \
    /workspace \
    /home/node/.config \
    /home/node/.npm \
    /home/node/.ssh && \
    chown -R node:node /home/node/.pi \
    /workspace \
    /home/node/.config \
    /home/node/.npm \
    /home/node/.ssh

# GitHub's published SSH host keys, verified at build time against the
# fingerprints from
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# Pinned instead of `ssh-keyscan` at build time, which trusts whatever answers
# on the network that day (SECURITY.md, C3).
COPY src/github_known_hosts /etc/ssh/ssh_known_hosts
RUN chmod 0644 /etc/ssh/ssh_known_hosts \
    && for fp in \
        SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU \
        SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM \
        SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s; do \
        ssh-keygen -lf /etc/ssh/ssh_known_hosts | grep -qF -- "$fp" \
            || { echo "known_hosts fingerprint mismatch: $fp" >&2; exit 1; }; \
    done

# Seal the OS: Activate the LD_PRELOAD firewall now that the DAC filesystem is staged
RUN echo "/usr/local/lib/fs-vault.so" > /etc/ld.so.preload && \
    printf '#!/bin/sh\n\
unset GIT_TRACE\n\
unset GIT_TRACE_CURL\n\
unset GIT_TRACE_PACKET\n\
unset GIT_TRACE_SETUP\n\
unset GIT_TRACE_PERFORMANCE\n\
unset GIT_CURL_VERBOSE\n\
unset GIT_REFLOG_ACTION\n\
unset GIT_SSH_COMMAND\n\
unset GIT_SSH_VARIANT\n\
exec /usr/bin/git "$@"\n' > /usr/local/bin/git \
    && chmod +x /usr/local/bin/git

# Route GitHub HTTPS URLs over SSH so the agent uses a single host SSH key for
# git transport instead of the HTTPS token. This keeps `gh` available for API
# calls while git push/pull/fetch/clone against github.com use SSH.
RUN git config --system url."git@github.com:".insteadOf "https://github.com/" \
    && git config --system core.sshCommand "ssh -i /home/node/.ssh/git_key -o IdentitiesOnly=yes"

WORKDIR /workspace

USER node

ENTRYPOINT ["pi"]
CMD []
