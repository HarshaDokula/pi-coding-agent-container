# syntax=docker/dockerfile:1

FROM node:26-trixie-slim AS base

ENV NODE_ENV=production
ENV DEBIAN_FRONTEND=noninteractive
ENV NPM_CONFIG_LOGLEVEL=warn
ENV HOME=/home/node

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    wget \
    ca-certificates \
    procps \
    build-essential \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# System Hardening: Purge Privilege Escalation Vectors
# -----------------------------------------------------------------------------
RUN rm -f /bin/su /usr/bin/su /bin/mount /usr/bin/mount /bin/umount /usr/bin/umount \
    /usr/bin/passwd /usr/bin/chsh /usr/bin/chfn /usr/bin/chage /usr/bin/gpasswd \
    /usr/bin/newgrp /bin/login /usr/bin/login /usr/bin/nsenter /usr/bin/unshare \
    /usr/bin/setpriv /bin/setpriv \
    && find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec chmod a-s {} + || true

RUN mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# The GitHub CLI Guardrail & Vault
#
# `gh` is a small wrapper that reads the token from the Docker secret and execs
# the guard. It is deliberately NOT setuid: compose mounts secrets 0444, so the
# token is readable by the container user anyway and elevation would only add a
# local privilege-escalation primitive to the image (see SECURITY.md, C1).
# -----------------------------------------------------------------------------
COPY src/gh-guard.sh /usr/local/bin/gh-guard
RUN chmod 0755 /usr/local/bin/gh-guard

COPY src/gh-vault.c /tmp/gh-vault.c
RUN gcc -O2 /tmp/gh-vault.c -o /usr/local/bin/gh \
    && chown root:root /usr/local/bin/gh \
    && chmod 0755 /usr/local/bin/gh \
    && rm /tmp/gh-vault.c

# -----------------------------------------------------------------------------
# The Global Syscall Firewall (LD_PRELOAD) - Blocks Child Processes
# -----------------------------------------------------------------------------
COPY src/fs-vault.c /tmp/fs-vault.c
RUN gcc -shared -fPIC -O2 /tmp/fs-vault.c -o /usr/local/lib/fs-vault.so -ldl \
    && rm /tmp/fs-vault.c

# -----------------------------------------------------------------------------
# Comprehensive Application-Layer Firewall (V8 Hook)
# -----------------------------------------------------------------------------
COPY src/app-firewall.js /usr/local/lib/app-firewall.js

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
    && git config --system core.sshCommand "ssh -i /home/node/.ssh/git_key -o IdentitiesOnly=yes" \
    && mkdir -p /etc/ssh \
    && (ssh-keyscan github.com > /etc/ssh/ssh_known_hosts 2>/dev/null || true)

WORKDIR /workspace

USER node

ENTRYPOINT ["pi"]
CMD []
