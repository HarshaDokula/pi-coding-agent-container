.PHONY: build run run-args clean shell setup ssh-key install uninstall sync test wiki-setup net-clean

# Install the `pictl` launcher into PATH (~/.local/bin by default) so the agent
# container can be started from any directory:
#   pictl                     # current directory
#   pictl /path/to/my-project # a specific project
# The launcher finds this project via its own symlink location, so no paths
# are hardcoded. Override the install prefix with PREFIX=/usr/local (system
# wide) or set PI_CONTAINER_DIR at runtime to point elsewhere.
PREFIX ?= $(HOME)/.local

install: bin/pictl
	@mkdir -p "$(PREFIX)/bin"
	@ln -sf "$(abspath bin/pictl)" "$(PREFIX)/bin/pictl"
	@echo "Installed 'pictl' launcher -> $(PREFIX)/bin/pictl"
	@echo "Run 'pictl' from any directory (or 'pictl /path/to/project')."
	@if ! command -v pictl >/dev/null 2>&1 || [ "$$(command -v pictl)" != "$(PREFIX)/bin/pictl" ]; then \
		echo "Note: add $(PREFIX)/bin to your PATH:"; \
		echo "  echo 'export PATH="$(PREFIX)/bin:\$$PATH"' >> ~/.bashrc"; \
	fi

uninstall:
	@rm -f "$(PREFIX)/bin/pictl"
	@echo "Removed 'pictl' launcher from $(PREFIX)/bin"


HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

# The container runs as HOST_UID (docker-compose `user:`). uid 0 would silently
# disable every privilege drop in the image, so refuse it outright
# (SECURITY.md, C5).
ifeq ($(HOST_UID),0)
$(error Refusing to run as root (HOST_UID=0). Run pictl/make as an unprivileged user)
endif

RANDOM_ID := $(shell openssl rand -hex 6 2>/dev/null || echo "default")
export SECRET_TARGET_PATH = /run/secrets/gh_$(RANDOM_ID)

# Managed skills/extensions repo (optional)
# Reads from .env if not passed on command line
MANAGED_REPO_URL ?= $(shell grep -E '^MANAGED_REPO_URL=' .env 2>/dev/null | tail -1 | sed 's/^MANAGED_REPO_URL=//')
MANAGED_REPO_REF ?= $(shell grep -E '^MANAGED_REPO_REF=' .env 2>/dev/null | tail -1 | sed 's/^MANAGED_REPO_REF=//')

# Working directory (or directories) to mount as the agent's workspace.
# Defaults to ./workspace for backward compatibility.
#
# Accepts one or more directories as a whitespace-separated list, the same way
# Unix commands accept multiple paths:
#   make run WORK_DIR=/path/to/your/repo
#   make run WORK_DIR="/path/to/repo-a /path/to/repo-b"
#
# With one directory it is mounted at /workspace (unchanged). With two or more,
# every directory is mounted at /workspace/<folder-name> so they sit side by
# side, and the agent's working directory is /workspace, e.g.:
#   /path/to/repo-a -> /workspace/repo-a
#   /path/to/repo-b -> /workspace/repo-b
#
# /workspace is a direct bind (see docker-compose.yml), not a named volume, so
# switching between single- and multi-directory runs never changes a volume
# config or prompts to recreate one.
#
# Paths containing whitespace are not supported (make splits WORK_DIR on
# whitespace), so keep one directory per value or use symlinks.
WORK_DIR ?= $(shell grep -E '^WORK_DIR=' .env 2>/dev/null | tail -1 | sed 's/^WORK_DIR=//')
ifeq ($(WORK_DIR),)
WORK_DIR := ./workspace
endif

# Split WORK_DIR into make words, exactly like multiple command-line arguments.
WORK_DIR_LIST := $(WORK_DIR)

# Resolve every workspace (created if missing) to an absolute path.
WORK_DIR_ALL_ABS := $(foreach d,$(WORK_DIR_LIST),$(shell mkdir -p "$(d)" && cd "$(d)" && pwd))
WORK_DIR_PRIMARY_ABS := $(firstword $(WORK_DIR_ALL_ABS))
WORK_DIR_EXTRA_ABS := $(wordlist 2,100000,$(WORK_DIR_ALL_ABS))

ifeq ($(WORK_DIR_EXTRA_ABS),)
# Single directory: mount it directly at /workspace (backward compatible).
WORK_DIR_ABS := $(WORK_DIR_PRIMARY_ABS)
WORK_DIR_MOUNT_ARGS :=
else
# Multiple directories: use a dedicated, gitignored .pi-workspace/ as the
# workspace root (so combo runs show only the mounted projects) and mount every
# directory at /workspace/<basename>.
WORK_DIR_ABS := $(shell mkdir -p "./.pi-workspace" && cd "./.pi-workspace" && pwd)
PRE_CREATE_WORK_DIR_MOUNTS := $(foreach d,$(WORK_DIR_ALL_ABS),$(shell mkdir -p "$(WORK_DIR_ABS)/$(notdir $(d))"))
WORK_DIR_MOUNT_ARGS := $(foreach d,$(WORK_DIR_ALL_ABS),-v "$(d):/workspace/$(notdir $(d))")

# Two directories with the same basename would collide at /workspace/<name>.
WORK_DIR_DUPLICATE_BASENAMES := $(shell printf '%s\n' $(foreach d,$(WORK_DIR_ALL_ABS),$(notdir $(d))) | sort | uniq -d)
ifneq ($(strip $(WORK_DIR_DUPLICATE_BASENAMES)),)
$(error WORK_DIR has directories that share a basename: $(WORK_DIR_DUPLICATE_BASENAMES); give each directory a unique name)
endif
endif

# Single SSH private key mounted read-only into the container for git over
# SSH. Only this one key is exposed to the agent (not the whole ~/.ssh dir).
# Use 'make ssh-key' to generate a dedicated key at this path, or override:
#   make run SSH_KEY=/absolute/path/to/pi_agent_ed25519
# or set it permanently in .env.
SSH_KEY ?= $(shell grep -E '^SSH_KEY=' .env 2>/dev/null | tail -1 | sed 's/^SSH_KEY=//')
ifeq ($(SSH_KEY),)
SSH_KEY := $(HOME)/.ssh/pi_agent_ed25519
endif
export SSH_KEY

# Git identity (read from .env so setup can warn when it is missing; docker
# compose reads .env itself, so these are only used for the setup hints).
GIT_NAME ?= $(shell grep -E '^GIT_NAME=' .env 2>/dev/null | tail -1 | sed 's/^GIT_NAME=//')
GIT_EMAIL ?= $(shell grep -E '^GIT_EMAIL=' .env 2>/dev/null | tail -1 | sed 's/^GIT_EMAIL=//')

# Optional unique compose project name for running multiple isolated instances.
# When set, it is exported as COMPOSE_PROJECT_NAME so each instance gets its own
# network and container naming. Use letters, digits, dashes, or underscores.
PROJECT_NAME ?= $(shell grep -E '^PROJECT_NAME=' .env 2>/dev/null | tail -1 | sed 's/^PROJECT_NAME=//')

# Auto-derive an isolated project identity when PROJECT_NAME is not set but
# WORK_DIR was passed explicitly on the command line, e.g.
#   make run WORK_DIR=/path/to/project-a
# becomes PROJECT_NAME=pi-agent-project-a. Each workspace then gets its own
# network, volumes, and .pi-data-<derived> (seeded from the default .pi-data),
# so concurrent instances on different projects don't collide on volume names.
# An explicit PROJECT_NAME always wins; a plain `make run` (no WORK_DIR on the
# command line) keeps the legacy .pi-data behavior.
ifeq ($(PROJECT_NAME),)
ifeq ($(origin WORK_DIR),command line)
DERIVED_PROJECT := $(shell basename "$(WORK_DIR_PRIMARY_ABS)" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/^-\+//' -e 's/-\+$$//' | cut -c1-50)
ifeq ($(DERIVED_PROJECT),)
DERIVED_PROJECT := workspace
endif
PROJECT_NAME := pi-agent-$(DERIVED_PROJECT)
endif
endif

ifneq ($(PROJECT_NAME),)
COMPOSE_PROJECT_NAME := $(PROJECT_NAME)
export COMPOSE_PROJECT_NAME
endif

# Per-instance pi data directory (sessions, settings, skills). Defaults to
# .pi-data, or .pi-data-<PROJECT_NAME> when PROJECT_NAME is set, so concurrent
# instances keep isolated agent state.
PI_DATA_DIR ?= $(shell grep -E '^PI_DATA_DIR=' .env 2>/dev/null | tail -1 | sed 's/^PI_DATA_DIR=//')
ifeq ($(PI_DATA_DIR),)
ifneq ($(PROJECT_NAME),)
PI_DATA_DIR := .pi-data-$(PROJECT_NAME)
else
PI_DATA_DIR := .pi-data
endif
endif
PI_DATA_DIR := $(abspath $(PI_DATA_DIR))
export PI_DATA_DIR

# Per-project Docker network subnet.
#
# Docker gives every bridge network a whole /16 from a pool of only ~15
# (172.17.0.0/16 .. 172.31.0.0/16). A dozen projects exhaust it and the next
# run fails with "all predefined address pools have been fully subnetted".
# Each project instead gets an explicit /24 (scripts/network-subnet.sh), which
# never draws on that tiny pool. By default the /24 is a deterministic hash of
# the project name inside PI_NETWORK_BASE: no host state is read. Set
# PI_NETWORK_DISCOVERY=1 if you want it to scan Docker networks, host addresses
# and host routes and pick the first free block instead.
#
# Override the exact subnet with PI_NETWORK_SUBNET, or the block with
# PI_NETWORK_BASE (a /8../16). All three can go in .env.
PI_NETWORK_BASE ?= $(shell grep -E '^PI_NETWORK_BASE=' .env 2>/dev/null | tail -1 | sed 's/^PI_NETWORK_BASE=//')
ifeq ($(PI_NETWORK_BASE),)
PI_NETWORK_BASE := 10.200.0.0/13
endif
PI_NETWORK_SUBNET ?= $(shell grep -E '^PI_NETWORK_SUBNET=' .env 2>/dev/null | tail -1 | sed 's/^PI_NETWORK_SUBNET=//')
# 0 (default) = deterministic, reads nothing from the host; 1 = probe for a
# free block. Read from .env as well, and passed to the allocator explicitly.
PI_NETWORK_DISCOVERY ?= $(shell grep -E '^PI_NETWORK_DISCOVERY=' .env 2>/dev/null | tail -1 | sed 's/^PI_NETWORK_DISCOVERY=//')
# Seed is the compose project name the subnet is derived from.
PI_NETWORK_SEED := $(if $(PROJECT_NAME),$(PROJECT_NAME),$(if $(COMPOSE_PROJECT_NAME),$(COMPOSE_PROJECT_NAME),$(shell basename "$(CURDIR)" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_-]/-/g' -e 's/^-\+//' -e 's/-\+$$//')))
ifeq ($(PI_NETWORK_SUBNET),)
PI_NETWORK_SUBNET := $(shell PI_NETWORK_DISCOVERY="$(PI_NETWORK_DISCOVERY)" ./scripts/network-subnet.sh "$(PI_NETWORK_SEED)" "$(PI_NETWORK_BASE)")
endif
export PI_NETWORK_SUBNET

# Run the container detached (background) instead of the default foreground
# mode. Set DETACHED=true (or 1) on the command line or in .env to detach.
DETACHED ?= $(shell grep -E '^DETACHED=' .env 2>/dev/null | tail -1 | sed 's/^DETACHED=//')
RUN_FLAGS := --rm
ifneq ($(filter $(DETACHED),true 1 yes on),)
RUN_FLAGS := -d --rm
endif

# -----------------------------------------------------------------------------
# LLM Wiki (opt-in, shared KB)
# -----------------------------------------------------------------------------
# Off by default. Enable per session with `make run WIKI=true` (or `pictl -w`).
# When enabled, the shared vault is bind-mounted and the pinned
# @zosmaai/pi-llm-wiki package is loaded for that run only via `pi -e`, so
# settings.json is never mutated and seed/sync are unaffected.
LLM_WIKI_VERSION ?= $(shell grep -E '^LLM_WIKI_VERSION=' .env 2>/dev/null | tail -1 | sed 's/^LLM_WIKI_VERSION=//')
ifeq ($(LLM_WIKI_VERSION),)
LLM_WIKI_VERSION := 0.12.2
endif

LLM_WIKI_DIR ?= $(shell grep -E '^LLM_WIKI_DIR=' .env 2>/dev/null | tail -1 | sed 's/^LLM_WIKI_DIR=//')
ifeq ($(LLM_WIKI_DIR),)
LLM_WIKI_DIR := $(HOME)/pi-llm-wiki
endif
LLM_WIKI_DIR := $(abspath $(LLM_WIKI_DIR))

LLM_WIKI_PKG_DIR ?= $(abspath vendor/pi-llm-wiki)

WIKI_ENABLED := $(filter true 1 yes on,$(WIKI))

ifeq ($(WIKI_ENABLED),)
COMPOSE_FILES := -f docker-compose.yml
WIKI_ARGS :=
else
COMPOSE_FILES := -f docker-compose.yml -f docker-compose.wiki.yml
WIKI_ARGS := -e /opt/pi-llm-wiki/node_modules/@zosmaai/pi-llm-wiki
endif

export LLM_WIKI_DIR LLM_WIKI_PKG_DIR

# Only vendor the wiki package and create the vault dir when this run wants it.
ifneq ($(WIKI_ENABLED),)
setup: wiki-setup
endif

setup:
	mkdir -p $(PI_DATA_DIR) .secrets workspace src
	chmod 700 $(PI_DATA_DIR) .secrets workspace
	@# .env holds GITHUB_TOKEN and the git identity: keep it private to the
	@# owning user (SECURITY.md, A2).
	@if [ -f .env ]; then \
		if [ -n "$$(/usr/bin/find .env -maxdepth 0 -perm /077 2>/dev/null)" ]; then \
			echo "Note: .env was readable by group/other - tightening to 600." >&2; \
		fi; \
		chmod 600 .env; \
	fi
	@./scripts/seed-agent-config.sh "$(PI_DATA_DIR)" ".pi-data"
	@# Ship the built-in secret-redaction extension so tool results are scrubbed
	@# before pi persists them to the session transcript (SECURITY.md, A1).
	@mkdir -p "$(PI_DATA_DIR)/agent/extensions"
	@install -m 644 src/redact-secrets.ts "$(PI_DATA_DIR)/agent/extensions/redact-secrets.ts"
	@chmod 600 .secrets/github_token.txt 2>/dev/null || true
	touch .secrets/github_token.txt
	chmod 600 .secrets/github_token.txt
	@if [ -f .env ] && grep -q "^GITHUB_TOKEN=" .env; then \
		grep "^GITHUB_TOKEN=" .env | cut -d '=' -f2- > .secrets/github_token.txt; \
	else \
		echo "unset" > .secrets/github_token.txt; \
	fi
	chmod 400 .secrets/github_token.txt
	@if [ ! -f .env ]; then \
		echo "Hint: no .env found - run 'cp .env.example .env' and set GIT_NAME/GIT_EMAIL." >&2; \
	fi
	@if [ -z "$(GIT_NAME)" ] || [ -z "$(GIT_EMAIL)" ]; then \
		echo "Hint: GIT_NAME/GIT_EMAIL not set - the agent's git commits will have no author and pushes to GitHub will fail. Edit .env." >&2; \
	fi
	@if [ ! -f "$(SSH_KEY)" ]; then \
		echo "Hint: SSH key $(SSH_KEY) not found - run 'make ssh-key' and add the printed key at https://github.com/settings/ssh/new." >&2; \
	fi

# Vendor the pinned LLM wiki package into <repo>/vendor/pi-llm-wiki and make
# sure the shared vault root exists. Runs on the host and is idempotent.
# Called by `setup` only when WIKI=true, or explicitly with `make wiki-setup`.
wiki-setup:
	@mkdir -p "$(LLM_WIKI_DIR)"
	@./scripts/fetch-llm-wiki.sh "$(LLM_WIKI_VERSION)" "$(LLM_WIKI_PKG_DIR)"

ssh-key:
	@mkdir -p "$$(dirname "$(SSH_KEY)")"
	@if [ -f "$(SSH_KEY)" ]; then \
		echo "SSH key already exists at $(SSH_KEY)"; \
	else \
		echo "Generating dedicated ed25519 key for the pi agent..."; \
		ssh-keygen -t ed25519 -C "pi-agent" -f "$(SSH_KEY)" -N ""; \
	fi
	@echo
	@echo "Public key (add it to GitHub at https://github.com/settings/ssh/new):"
	@cat "$(SSH_KEY).pub"
	@echo
	@echo "Then run: make run"

# Manually replicate the canonical .pi-data agent config (provider login,
# models, settings) into existing per-workspace data dirs. Deliberately NOT
# part of setup/seed, so a manual/config change is only propagated when you
# ask for it.
#   make sync
#   make sync SYNC_ARGS=--dry-run
#   make sync SYNC_ARGS="--to .pi-data-pi-agent-myproject"
sync:
	@./scripts/sync-agent-config.sh $(SYNC_ARGS)

# Run the shell test suite (tests/test-*.sh).
test:
	@set -e; for t in tests/test-*.sh; do [ -f "$$t" ] || continue; echo "== $$t =="; bash "$$t"; done

build: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)" "$(PI_DATA_DIR)"
	docker compose build

update: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)" "$(PI_DATA_DIR)"
	docker compose build --no-cache

run: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_KEY=$(SSH_KEY) PI_DATA_DIR=$(PI_DATA_DIR) PI_NETWORK_SUBNET=$(PI_NETWORK_SUBNET) docker compose $(COMPOSE_FILES) run $(RUN_FLAGS) $(WORK_DIR_MOUNT_ARGS) pi-agent $(WIKI_ARGS)

run-args: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_KEY=$(SSH_KEY) PI_DATA_DIR=$(PI_DATA_DIR) PI_NETWORK_SUBNET=$(PI_NETWORK_SUBNET) docker compose $(COMPOSE_FILES) run $(RUN_FLAGS) $(WORK_DIR_MOUNT_ARGS) pi-agent $(WIKI_ARGS) $(args)

shell: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_KEY=$(SSH_KEY) PI_DATA_DIR=$(PI_DATA_DIR) PI_NETWORK_SUBNET=$(PI_NETWORK_SUBNET) docker compose $(COMPOSE_FILES) run $(WORK_DIR_MOUNT_ARGS) --entrypoint /bin/bash --rm pi-agent

clean:
	docker compose down

# Remove unused Docker networks left behind by per-project runs. `docker compose
# run --rm` removes the container but never the project network, so stale
# `*_pi_network` bridges accumulate and eventually exhaust Docker's default
# address pool. Scoped to our own networks; in-use networks are kept.
net-clean:
	@ids="$$(docker network ls --filter name=_pi_network --format '{{.ID}}')"; \
	if [ -n "$$ids" ]; then \
		docker network rm $$ids >/dev/null 2>&1 || true; \
		echo "Removed unused pi_network bridges (in-use ones were kept)."; \
	else \
		echo "No pi_network bridges to remove."; \
	fi
