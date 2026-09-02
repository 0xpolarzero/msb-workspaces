#!/usr/bin/env bash
# Silo configuration.
# The installer copies this file to ~/.config/silo/config.sh and preserves local edits.

SILO_VERSION="3.2.2"

# Shared base image and immutable development snapshot.
SILO_BASE_IMAGE="ghcr.io/superradcompany/ubuntu-systemd:24.04"
SILO_BASE_BUILDER="silo-base-builder"
SILO_BASE_SNAPSHOT="silo-base-v1"
SILO_ROOT_DISK="48G"

# Typed workspace configuration. Silo and setup.sh persist the validated
# JSON document at this path. setup.sh creates the three defaults below only
# when no typed document exists yet.
SILO_WORKSPACES_FILE="${SILO_WORKSPACES_FILE:-$HOME/.config/silo/workspaces.json}"

# Default values used when setup.sh creates workspaces.json.
SILO_DEV_CPUS="8"
SILO_DEV_MAX_CPUS="12"
SILO_DEV_MEMORY="32G"
SILO_DEV_MAX_MEMORY="48G"

SILO_PLAYGROUNDS_CPUS="4"
SILO_PLAYGROUNDS_MAX_CPUS="12"
SILO_PLAYGROUNDS_MEMORY="32G"
SILO_PLAYGROUNDS_MAX_MEMORY="48G"

SILO_PERSONAL_CPUS="6"
SILO_PERSONAL_MAX_CPUS="12"
SILO_PERSONAL_MEMORY="16G"
SILO_PERSONAL_MAX_MEMORY="32G"

# Independent persistent ext4 volumes. Adjust before first installation if needed.
SILO_DEV_WORKSPACE_SIZE="120G"
SILO_DEV_RUNTIME_SIZE="100G"
SILO_PLAYGROUNDS_WORKSPACE_SIZE="60G"
SILO_PLAYGROUNDS_RUNTIME_SIZE="60G"
SILO_PERSONAL_WORKSPACE_SIZE="100G"
SILO_PERSONAL_RUNTIME_SIZE="80G"

# Published on every workspace's own loopback IP.
# 24678 and 24679 are reserved for automated end-to-end health tests.
SILO_PUBLISHED_PORTS="1234,1337,24678-24679,3000-3010,3100,3333,3306-3308,4000-4005,4173,4200,4321,5001-5005,5173-5180,5432-5435,5555,6006,6379-6382,7001-7005,8000-8010,8080-8090,8787,8888,9000-9005,9229-9230,27017-27019"

# The current repo-aware proxy never puts a GitHub credential in a guest.
SILO_GITHUB_MODE="local"

# Host prerequisite: setup.sh installs the GitHub CLI (`gh`) via Homebrew;
# local-mode sign-in on a clean Mac uses `gh`'s web OAuth flow and silo reuses
# the authenticated `gh` session. No OAuth client ID lives in this file.

# Path C §3/§4: host loopback port for the repo-aware GitHub proxy. The guest
# relay listens on the same port inside each workspace; the host shuttle
# bridges the two over `msb exec --stream`.
SILO_GITHUB_PROXY_PORT="18446"

SILO_BACKUP_DIR="$HOME/Backups/silo"
SILO_DOCS_DIR="$HOME/.local/share/silo/docs"
