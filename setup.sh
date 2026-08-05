#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD_BASE=0
RECREATE_WORKSPACES=0
RESET_CONFIG=0
TEST_MODE="${MSW_TEST_MODE:-0}"

usage() {
  cat <<'HELP'
Usage: ./setup.sh [OPTIONS]

Options:
  --rebuild-base         Rebuild the reusable development snapshot.
  --recreate-workspaces  Recreate VM roots; repository and Docker volumes survive.
  --reset-config         Replace ~/.config/msw/config.sh with packaged defaults.
  -h, --help             Show this help.
HELP
}

while (( $# )); do
  case "$1" in
    --rebuild-base) REBUILD_BASE=1 ;;
    --recreate-workspaces) RECREATE_WORKSPACES=1 ;;
    --reset-config) RESET_CONFIG=1; RECREATE_WORKSPACES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
  shift
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }
fatal() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }
ensure_line() { local line="$1" file="$2"; touch "$file"; grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >>"$file"; }

if [[ "$TEST_MODE" != 1 ]]; then
  [[ "$(uname -s)" == Darwin ]] || fatal "this installer is for macOS"
  [[ "$(uname -m)" == arm64 ]] || fatal "an Apple Silicon Mac is required"
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/libexec" "$HOME/.config/msw" "$HOME/.local/share/msw/docs"
ensure_line 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zprofile"
ensure_line 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zshrc"
export PATH="$HOME/.local/bin:$PATH"

if [[ "$TEST_MODE" != 1 ]]; then
  log "Installing host tools"
  if ! command -v brew >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    else
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi
  ensure_line 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$HOME/.zprofile"
  eval "$(brew shellenv)"
  brew install gnu-tar zstd git-lfs

  if ! command -v msb >/dev/null 2>&1; then
    if ! brew install superradcompany/tap/microsandbox; then
      warn "Homebrew formula failed; using the official MicroSandbox installer"
      curl -fsSL https://install.microsandbox.dev | sh
    fi
  elif brew list --versions superradcompany/tap/microsandbox >/dev/null 2>&1; then
    brew upgrade superradcompany/tap/microsandbox || true
  fi
fi

MSB_BIN="${MSW_MSB_BIN:-$(command -v msb 2>/dev/null || true)}"
[[ -n "$MSB_BIN" && -x "$MSB_BIN" ]] || fatal "msb is unavailable"

log "Installing the MSW CLI and documentation"
if [[ "$RESET_CONFIG" == 1 || ! -f "$HOME/.config/msw/config.sh" ]]; then
  install -m 0644 "$SCRIPT_DIR/config.sh" "$HOME/.config/msw/config.sh"
else
  echo "Keeping existing $HOME/.config/msw/config.sh"
fi
install -m 0755 "$SCRIPT_DIR/lib/bootstrap-base.sh" "$HOME/.config/msw/bootstrap-base.sh"
install -m 0755 "$SCRIPT_DIR/bin/msw" "$HOME/.local/bin/msw"
install -m 0755 "$SCRIPT_DIR/bin/msw-ssh-proxy" "$HOME/.local/bin/msw-ssh-proxy"
install -m 0755 "$SCRIPT_DIR/bin/msw-git-askpass" "$HOME/.local/libexec/msw-git-askpass"
install -m 0644 "$SCRIPT_DIR/docs/"*.md "$HOME/.local/share/msw/docs/"
install -m 0644 "$SCRIPT_DIR/README.md" "$HOME/.local/share/msw/README.md"

# shellcheck source=/dev/null
source "$HOME/.config/msw/config.sh"

log "Checking MicroSandbox"
if ! "$MSB_BIN" doctor; then
  "$MSB_BIN" doctor --fix
  "$MSB_BIN" doctor
fi

log "Configuring browser names, loopback addresses, and SSH"
"$HOME/.local/bin/msw" host repair

HOST_CPUS="${MSW_TEST_HOST_CPUS:-}"
if [[ -z "$HOST_CPUS" ]]; then HOST_CPUS="$(sysctl -n hw.logicalcpu)"; fi
cap_cpu() { local requested="$1"; (( requested > HOST_CPUS )) && printf '%s\n' "$HOST_CPUS" || printf '%s\n' "$requested"; }
snapshot_exists() { "$MSB_BIN" snapshot inspect "$MSW_BASE_SNAPSHOT" >/dev/null 2>&1; }
sandbox_exists() { "$MSB_BIN" inspect "$1" >/dev/null 2>&1; }
volume_exists() { "$MSB_BIN" volume inspect "$1" >/dev/null 2>&1; }

BASE_STAMP="$HOME/.config/msw/base-version"
if [[ -f "$BASE_STAMP" && "$(cat "$BASE_STAMP")" != "$MSW_VERSION" ]]; then
  warn "base version changed; rebuilding VM roots while preserving data volumes"
  REBUILD_BASE=1
  RECREATE_WORKSPACES=1
fi

validate_ports() {
  local token start end port seen=" "
  local old_ifs="$IFS"; IFS=','
  for token in $MSW_PUBLISHED_PORTS; do
    if [[ "$token" == *-* ]]; then start="${token%-*}"; end="${token#*-}"; else start="$token"; end="$token"; fi
    [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || fatal "invalid port token: $token"
    (( start >= 1 && end <= 65535 && start <= end )) || fatal "invalid port range: $token"
    for ((port=start; port<=end; port++)); do
      [[ "$seen" != *" $port "* ]] || fatal "published port repeated: $port"
      seen+="$port "
    done
  done
  IFS="$old_ifs"
}
validate_ports

if [[ "$REBUILD_BASE" == 1 ]] && snapshot_exists; then
  log "Removing the old base snapshot"
  "$MSB_BIN" snapshot rm "$MSW_BASE_SNAPSHOT" --force
fi

if ! snapshot_exists; then
  log "Building the reusable Ubuntu development base"
  sandbox_exists "$MSW_BASE_BUILDER" && "$MSB_BIN" rm -f "$MSW_BASE_BUILDER" || true
  volume_exists msw-base-runtime-temporary && "$MSB_BIN" volume rm msw-base-runtime-temporary || true

  BASE_CPUS="$(cap_cpu 8)"
  BASE_MAX_CPUS="$(cap_cpu 12)"
  (( BASE_CPUS > BASE_MAX_CPUS )) && BASE_CPUS="$BASE_MAX_CPUS"

  "$MSB_BIN" create "$MSW_BASE_IMAGE" \
    --name "$MSW_BASE_BUILDER" \
    --cpus "$BASE_CPUS" --max-cpus "$BASE_MAX_CPUS" \
    --memory 16G --max-memory 24G \
    --root-disk "$MSW_ROOT_DISK" \
    --mount-named "msw-base-runtime-temporary:/var/lib/msw-runtime:kind=disk,size=24G" \
    --mkdir /workspace --mkdir /var/lib/msw-runtime \
    --workdir /workspace --init auto --security default --net public \
    --label msw.role=base-builder

  "$MSB_BIN" exec --no-tty "$MSW_BASE_BUILDER" -- bash -s <"$HOME/.config/msw/bootstrap-base.sh"
  "$MSB_BIN" stop -t 120 "$MSW_BASE_BUILDER"
  "$MSB_BIN" snapshot create "$MSW_BASE_SNAPSHOT" --from "$MSW_BASE_BUILDER" --integrity --label msw.role=development-base
  "$MSB_BIN" snapshot verify "$MSW_BASE_SNAPSHOT"
  "$MSB_BIN" rm "$MSW_BASE_BUILDER"
  "$MSB_BIN" volume rm msw-base-runtime-temporary
  printf '%s\n' "$MSW_VERSION" >"$BASE_STAMP"
else
  echo "Using existing base snapshot: $MSW_BASE_SNAPSHOT"
  [[ -f "$BASE_STAMP" ]] || printf '%s\n' "$MSW_VERSION" >"$BASE_STAMP"
fi

expand_ports_into_args() {
  local bind_ip="$1" token start end current old_ifs="$IFS"
  PORT_ARGS=()
  IFS=','
  for token in $MSW_PUBLISHED_PORTS; do
    if [[ "$token" == *-* ]]; then start="${token%-*}"; end="${token#*-}"; else start="$token"; end="$token"; fi
    for ((current=start; current<=end; current++)); do PORT_ARGS+=(--port "${bind_ip}:${current}:${current}"); done
  done
  IFS="$old_ifs"
}

check_port_conflicts() {
  [[ "$TEST_MODE" == 1 ]] && return 0
  local bind_ip="$1" workspace="$2" port conflicts=""
  local token start end current old_ifs="$IFS"; IFS=','
  for token in $MSW_PUBLISHED_PORTS; do
    if [[ "$token" == *-* ]]; then start="${token%-*}"; end="${token#*-}"; else start="$token"; end="$token"; fi
    for ((current=start; current<=end; current++)); do
      /usr/bin/nc -z -G 1 "$bind_ip" "$current" >/dev/null 2>&1 && conflicts+=" $current"
    done
  done
  IFS="$old_ifs"
  [[ -z "$conflicts" ]] || fatal "$workspace cannot start because these ports are already used on $bind_ip:$conflicts"
}

wait_for_guest_systemd() {
  local box="$1" attempt=0
  until "$MSB_BIN" exec --no-tty "$box" -- systemctl daemon-reload >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    (( attempt < 120 )) || fatal "$box systemd bus did not become ready"
    sleep 1
  done
}

configure_workspace_guest() {
  local box="$1" browser_host="$2"
  wait_for_guest_systemd "$box"
  "$MSB_BIN" exec --no-tty "$box" -- bash -s -- "$box" "$browser_host" <<'GUEST'
set -Eeuo pipefail
workspace="$1"; browser_host="$2"
mkdir -p /workspace /var/lib/msw-runtime/docker /var/lib/msw-runtime/containerd
cat >/etc/profile.d/msw-workspace.sh <<PROFILE
export MSW_WORKSPACE="$workspace"
export MSW_BROWSER_HOST="$browser_host"
export HOST="0.0.0.0"
export BIND_ADDRESS="0.0.0.0"
export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS="$browser_host"
PROFILE
chmod 0644 /etc/profile.d/msw-workspace.sh
hostnamectl set-hostname "msw-$workspace"
printf '%s\n' "$workspace" >/workspace/.msw-workspace
cat >/etc/motd <<MOTD
MicroSandbox workspace: $workspace

  Code:       /workspace
  Browser:    http://$browser_host:<published-port>
  Docker:     docker compose up --build
  Runtimes:   mise use <tool>@<version>
  Python:     uv sync / uv run ...
MOTD
systemctl daemon-reload
systemctl enable containerd.service docker.service
systemctl restart containerd.service docker.service
timeout 120 bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
docker run --rm alpine:latest true
mkdir -p /workspace/.msw-docker-smoke
printf 'host\n' >/workspace/.msw-docker-smoke/in
docker run --rm -v /workspace/.msw-docker-smoke:/work alpine:latest sh -ceu 'grep -qx host /work/in; printf "container\n" >/work/out'
grep -qx container /workspace/.msw-docker-smoke/out
rm -rf /workspace/.msw-docker-smoke
sync
GUEST
}

keychain_read_token() {
  local box="$1"
  if [[ -n "${MSW_TEST_KEYCHAIN_DIR:-}" ]]; then
    local file="$MSW_TEST_KEYCHAIN_DIR/msw.github.read__${box}"
    [[ -f "$file" ]] || return 1
    cat "$file"
  else
    /usr/bin/security find-generic-password -w -s msw.github.read -a "$box" 2>/dev/null
  fi
}

create_workspace() {
  local box="$1" bind_ip="$2" browser_host="$3" cpus="$4" max_cpus="$5" memory="$6" max_memory="$7" workspace_size="$8" runtime_size="$9"
  local effective_cpus effective_max token=""
  effective_cpus="$(cap_cpu "$cpus")"; effective_max="$(cap_cpu "$max_cpus")"
  (( effective_cpus > effective_max )) && effective_cpus="$effective_max"

  if sandbox_exists "$box" && [[ "$RECREATE_WORKSPACES" == 1 ]]; then
    warn "recreating $box root; its repository and Docker volumes are preserved"
    "$MSB_BIN" rm -f "$box"
  fi

  if ! sandbox_exists "$box"; then
    check_port_conflicts "$bind_ip" "$box"
    expand_ports_into_args "$bind_ip"
    log "Creating workspace: $box"
    "$MSB_BIN" run --detach \
      --name "$box" --from-snapshot "$MSW_BASE_SNAPSHOT" \
      --cpus "$effective_cpus" --max-cpus "$effective_max" \
      --memory "$memory" --max-memory "$max_memory" \
      --mount-named "msw-${box}-workspace:/workspace:kind=disk,size=${workspace_size}" \
      --mount-named "msw-${box}-runtime:/var/lib/msw-runtime:kind=disk,size=${runtime_size}" \
      --workdir /workspace --init auto --security default --net public \
      --label msw.managed=true --label "msw.workspace=${box}" \
      --env "MSW_WORKSPACE=${box}" --env "MSW_BROWSER_HOST=${browser_host}" \
      --env 'PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
      --env SHELL=/usr/bin/zsh --env LANG=en_US.UTF-8 \
      --env HOST=0.0.0.0 --env BIND_ADDRESS=0.0.0.0 \
      --env "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=${browser_host}" \
      "${PORT_ARGS[@]}" \
      -- sleep infinity
    configure_workspace_guest "$box" "$browser_host"
    if token="$(keychain_read_token "$box" 2>/dev/null)"; then
      GH_TOKEN="$token" "$MSB_BIN" modify "$box" --secret "GH_TOKEN@${MSW_GITHUB_SECRET_HOSTS}" --next-start >/dev/null
      unset token
    fi
    "$MSB_BIN" stop -t 90 "$box"
  else
    echo "Workspace already exists: $box"
  fi
}

create_workspace dev "$MSW_DEV_IP" "$MSW_DEV_HOST" "$MSW_DEV_CPUS" "$MSW_DEV_MAX_CPUS" "$MSW_DEV_MEMORY" "$MSW_DEV_MAX_MEMORY" "$MSW_DEV_WORKSPACE_SIZE" "$MSW_DEV_RUNTIME_SIZE"
create_workspace playgrounds "$MSW_PLAYGROUNDS_IP" "$MSW_PLAYGROUNDS_HOST" "$MSW_PLAYGROUNDS_CPUS" "$MSW_PLAYGROUNDS_MAX_CPUS" "$MSW_PLAYGROUNDS_MEMORY" "$MSW_PLAYGROUNDS_MAX_MEMORY" "$MSW_PLAYGROUNDS_WORKSPACE_SIZE" "$MSW_PLAYGROUNDS_RUNTIME_SIZE"
create_workspace personal "$MSW_PERSONAL_IP" "$MSW_PERSONAL_HOST" "$MSW_PERSONAL_CPUS" "$MSW_PERSONAL_MAX_CPUS" "$MSW_PERSONAL_MEMORY" "$MSW_PERSONAL_MAX_MEMORY" "$MSW_PERSONAL_WORKSPACE_SIZE" "$MSW_PERSONAL_RUNTIME_SIZE"

log "Running the complete local VM, Docker, SSH, internet, and browser-port test"
"$HOME/.local/bin/msw" check --deep

cat <<'DONE'

Setup complete. The installer has already run the full local end-to-end test.

Next:
  1. exec zsh -l
  2. msw identity "YOUR NAME" YOUR_EMAIL@example.com
  3. Follow docs/GITHUB-SETUP.md, then run one command per workspace:
       msw github setup dev OWNER/VERIFICATION-REPO
       msw github setup playgrounds OWNER/VERIFICATION-REPO
       msw github setup personal OWNER/VERIFICATION-REPO

Daily use:
  msw dev
  msw zed dev PATH
  msw open dev 3000
  msw backup
  msw help
DONE
