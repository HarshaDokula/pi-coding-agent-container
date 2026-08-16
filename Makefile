.PHONY: build run clean shell setup

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

# SSH directory mounted read-only into the container so git can use the host's
# SSH keys for github.com instead of the HTTPS token. Override with:
#   make run SSH_DIR=/absolute/path/to/.ssh
# or set it permanently in .env.
SSH_DIR ?= $(shell grep -E '^SSH_DIR=' .env 2>/dev/null | tail -1 | sed 's/^SSH_DIR=//')
ifeq ($(SSH_DIR),)
SSH_DIR := $(HOME)/.ssh
endif
export SSH_DIR

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
	@if [ -f .env ]; then grep "^GITHUB_TOKEN=" .env | cut -d '=' -f2- > .secrets/github_token.txt; fi
	chmod 400 .secrets/github_token.txt
	@if [ ! -d "$(SSH_DIR)" ]; then echo "WARNING: SSH_DIR ($(SSH_DIR)) does not exist; git over SSH may fail." >&2; fi

build: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)" "$(PI_DATA_DIR)"
	docker compose build

update: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)" "$(PI_DATA_DIR)"
	docker compose build --no-cache

run: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_DIR=$(SSH_DIR) PI_DATA_DIR=$(PI_DATA_DIR) docker compose run $(RUN_FLAGS) pi-agent

run-args: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_DIR=$(SSH_DIR) PI_DATA_DIR=$(PI_DATA_DIR) docker compose run $(RUN_FLAGS) pi-agent $(args)

shell: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) SSH_DIR=$(SSH_DIR) PI_DATA_DIR=$(PI_DATA_DIR) docker compose run --entrypoint /bin/bash --rm pi-agent

clean:
	docker compose down
