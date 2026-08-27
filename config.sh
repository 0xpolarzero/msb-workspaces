#!/usr/bin/env bash
# MicroSandbox Workspaces configuration.
# The installer copies this file to ~/.config/msw/config.sh and preserves local edits.

MSW_VERSION="3.2.2"

# Shared base image and immutable development snapshot.
MSW_BASE_IMAGE="ghcr.io/superradcompany/ubuntu-systemd:24.04"
MSW_BASE_BUILDER="msw-base-builder"
MSW_BASE_SNAPSHOT="msw-base-v1"
MSW_ROOT_DISK="48G"

# Typed workspace configuration. MSW Monitor and setup.sh persist the validated
# JSON document at this path. setup.sh creates the three legacy defaults below
# only when no typed document exists yet.
MSW_WORKSPACES_FILE="${MSW_WORKSPACES_FILE:-$HOME/.config/msw/workspaces.json}"

# Legacy seed values used only when setup.sh creates workspaces.json for an
# installation that does not have the typed document yet.
MSW_DEV_CPUS="8"
MSW_DEV_MAX_CPUS="12"
MSW_DEV_MEMORY="32G"
MSW_DEV_MAX_MEMORY="48G"

MSW_PLAYGROUNDS_CPUS="4"
MSW_PLAYGROUNDS_MAX_CPUS="12"
MSW_PLAYGROUNDS_MEMORY="32G"
MSW_PLAYGROUNDS_MAX_MEMORY="48G"

MSW_PERSONAL_CPUS="6"
MSW_PERSONAL_MAX_CPUS="12"
MSW_PERSONAL_MEMORY="16G"
MSW_PERSONAL_MAX_MEMORY="32G"

# Independent persistent ext4 volumes. Adjust before first installation if needed.
MSW_DEV_WORKSPACE_SIZE="120G"
MSW_DEV_RUNTIME_SIZE="100G"
MSW_PLAYGROUNDS_WORKSPACE_SIZE="60G"
MSW_PLAYGROUNDS_RUNTIME_SIZE="60G"
MSW_PERSONAL_WORKSPACE_SIZE="100G"
MSW_PERSONAL_RUNTIME_SIZE="80G"

# Published on every workspace's own loopback IP.
# 24678 and 24679 are reserved for automated end-to-end health tests.
MSW_PUBLISHED_PORTS="1234,1337,24678-24679,3000-3010,3100,3333,3306-3308,4000-4005,4173,4200,4321,5001-5005,5173-5180,5432-5435,5555,6006,6379-6382,7001-7005,8000-8010,8080-8090,8787,8888,9000-9005,9229-9230,27017-27019"

# Connect mode only (legacy): the guest sees a placeholder named GH_TOKEN and
# the real read token stays on the host, substituted only when traffic reaches
# one of these GitHub endpoints. Local mode (the default) never puts any
# GitHub credential in the guest at all (Path C §7).
MSW_GITHUB_SECRET_HOSTS="github.com,api.github.com"

# Path C §1: single source of truth for GitHub mode. local = repo-aware proxy
# (default; no Connect grants, no keychain tokens, no guest secret). connect =
# the legacy Connect-grant flow. Environment overrides this value.
MSW_GITHUB_MODE="${MSW_GITHUB_MODE:-local}"

# Host prerequisite: setup.sh installs the GitHub CLI (`gh`) via Homebrew;
# local-mode sign-in on a clean Mac uses `gh`'s web OAuth flow and msw reuses
# the authenticated `gh` session. No OAuth client ID lives in this file.

# Path C §3/§4: host loopback port for the repo-aware GitHub proxy. The guest
# relay listens on the same port inside each workspace; the host shuttle
# bridges the two over `msb exec --stream`.
MSW_GITHUB_PROXY_PORT="18446"

MSW_BACKUP_DIR="$HOME/Backups/microsandbox"
MSW_DOCS_DIR="$HOME/.local/share/msw/docs"
