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

setup:
	mkdir -p .pi-data .secrets workspace src
	chmod 700 .pi-data .secrets workspace
	@chmod 600 .secrets/github_token.txt 2>/dev/null || true
	touch .secrets/github_token.txt
	chmod 600 .secrets/github_token.txt
	@if [ -f .env ]; then grep "^GITHUB_TOKEN=" .env | cut -d '=' -f2- > .secrets/github_token.txt; fi
	chmod 400 .secrets/github_token.txt

build: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)"
	docker compose build

update: setup
	@./scripts/fetch-managed.sh "$(MANAGED_REPO_URL)" "$(MANAGED_REPO_REF)"
	docker compose build --no-cache

run: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) docker compose run --rm pi-agent

run-args: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) docker compose run --rm pi-agent $(args)

shell: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) WORK_DIR=$(WORK_DIR_ABS) docker compose run --entrypoint /bin/bash --rm pi-agent

clean:
	docker compose down