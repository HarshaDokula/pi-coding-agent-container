.PHONY: build run clean shell setup ssh-key

HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)

export PARANOID_MODE ?= true
RANDOM_ID := $(shell openssl rand -hex 6 2>/dev/null || echo "default")
export SECRET_TARGET_PATH = /run/secrets/gh_$(RANDOM_ID)

# Managed skills/extensions repo (optional)
# Reads from .env if not passed on command line
MANAGED_REPO_URL ?= $(shell grep -E '^MANAGED_REPO_URL=' .env 2>/dev/null | tail -1 | sed 's/^MANAGED_REPO_URL=//')
MANAGED_REPO_REF ?= $(shell grep -E '^MANAGED_REPO_REF=' .env 2>/dev/null | tail -1 | sed 's/^MANAGED_REPO_REF=//')

# Working directory to mount as the agent's workspace
# Defaults to ./workspace for backward compatibility
# Override with: make run WORK_DIR=/path/to/your/repo
WORK_DIR ?= $(shell grep -E '^WORK_DIR=' .env 2>/dev/null | tail -1 | sed 's/^WORK_DIR=//')
ifeq ($(WORK_DIR),)
WORK_DIR := ./workspace
endif
WORK_DIR_ABS := $(shell mkdir -p $(WORK_DIR) && cd $(WORK_DIR) && pwd)

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

# Optional unique compose project name for running multiple isolated instances.
# When set, it is exported as COMPOSE_PROJECT_NAME so each instance gets its own
# network and container naming. Use letters, digits, dashes, or underscores.
PROJECT_NAME ?= $(shell grep -E '^PROJECT_NAME=' .env 2>/dev/null | tail -1 | sed 's/^PROJECT_NAME=//')
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

# Run the container detached (background) instead of the default foreground
# mode. Set DETACHED=true (or 1) on the command line or in .env to detach.
DETACHED ?= $(shell grep -E '^DETACHED=' .env 2>/dev/null | tail -1 | sed 's/^DETACHED=//')
RUN_FLAGS := --rm
ifneq ($(filter $(DETACHED),true 1 yes on),)
RUN_FLAGS := -d --rm
endif

setup:
	mkdir -p $(PI_DATA_DIR) .secrets workspace src
	chmod 700 $(PI_DATA_DIR) .secrets workspace
	@chmod 600 .secrets/github_token.txt 2>/dev/null || true
	touch .secrets/github_token.txt
	chmod 600 .secrets/github_token.txt
	@if [ -f .env ] && grep -q "^GITHUB_TOKEN=" .env; then \
		grep "^GITHUB_TOKEN=" .env | cut -d '=' -f2- > .secrets/github_token.txt; \
	else \
		echo "unset" > .secrets/github_token.txt; \
	fi
	chmod 400 .secrets/github_token.txt
	@if [ ! -f "$(SSH_KEY)" ]; then echo "WARNING: SSH_KEY ($(SSH_KEY)) does not exist; run 'make ssh-key' first." >&2; fi

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

build: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)" "$(PI_DATA_DIR)"
	docker compose build

update: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)" "$(PI_DATA_DIR)"
	docker compose build --no-cache

run: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_KEY=$(SSH_KEY) PI_DATA_DIR=$(PI_DATA_DIR) docker compose run $(RUN_FLAGS) pi-agent

run-args: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_KEY=$(SSH_KEY) PI_DATA_DIR=$(PI_DATA_DIR) docker compose run $(RUN_FLAGS) pi-agent $(args)

shell: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_KEY=$(SSH_KEY) PI_DATA_DIR=$(PI_DATA_DIR) docker compose run --entrypoint /bin/bash --rm pi-agent

clean:
	docker compose down
