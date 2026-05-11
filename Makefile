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
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) docker compose run --rm pi-agent

run-args: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) docker compose run --rm pi-agent $(args)

shell: setup
	HOST_UID=$(HOST_UID) HOST_GID=$(HOST_GID) docker compose run --entrypoint /bin/bash --rm pi-agent

clean:
	docker compose down