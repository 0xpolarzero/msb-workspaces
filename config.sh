#!/usr/bin/env bash
# MicroSandbox Workspaces configuration.
# The installer copies this file to ~/.config/msw/config.sh and preserves local edits.

MSW_VERSION="3.1.0"

# Shared base image and immutable development snapshot.
MSW_BASE_IMAGE="ghcr.io/superradcompany/ubuntu-systemd:24.04"
MSW_BASE_BUILDER="msw-base-builder"
MSW_BASE_SNAPSHOT="msw-base-v1"
MSW_ROOT_DISK="48G"

# Friendly browser names. Each VM has a distinct loopback IP, so identical ports can
# be used concurrently by all workspaces while remaining local to this Mac.
MSW_DEV_IP="127.0.0.10"
MSW_DEV_HOST="dev.msw.test"
MSW_PLAYGROUNDS_IP="127.0.0.11"
MSW_PLAYGROUNDS_HOST="playgrounds.msw.test"
MSW_PERSONAL_IP="127.0.0.12"
MSW_PERSONAL_HOST="personal.msw.test"

# Workspace CPU defaults plus each workspace's live memory limit and resize ceiling.
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

# The guest sees a placeholder named GH_TOKEN. The real read token stays on the host
# and is substituted only when traffic reaches one of these GitHub endpoints.
MSW_GITHUB_SECRET_HOSTS="github.com,api.github.com"

MSW_BACKUP_DIR="$HOME/Backups/microsandbox"
MSW_DOCS_DIR="$HOME/.local/share/msw/docs"
