#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD_BASE=0
RECREATE_WORKSPACES=0
RESET_CONFIG=0
SKIP_WORKSPACES=0
TEST_MODE="${MSW_TEST_MODE:-0}"

usage() {
  cat <<'HELP'
Usage: ./setup.sh [OPTIONS]

Options:
  --rebuild-base         Rebuild the reusable development snapshot.
  --recreate-workspaces  Recreate VM roots; repository and Docker volumes survive.
  --reset-config         Replace ~/.config/msw/config.sh with packaged defaults.
  --skip-workspaces      Install dependencies and the base snapshot only.
  -h, --help             Show this help.
HELP
}

while (( $# )); do
  case "$1" in
    --rebuild-base) REBUILD_BASE=1 ;;
    --recreate-workspaces) RECREATE_WORKSPACES=1 ;;
    --reset-config) RESET_CONFIG=1; RECREATE_WORKSPACES=1 ;;
    --skip-workspaces) SKIP_WORKSPACES=1 ;;
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

# ~/.local/state/msw must exist (private) BEFORE the GitHub proxy and
# port-forwarder launch agents are rendered/loaded: their launchd plists
# point StandardOutPath/StandardErrorPath into it, and a missing directory
# makes the jobs fail immediately on a clean home. setup.sh verifies every
# loaded job stays alive before reporting success.
mkdir -p "$HOME/.local/bin" "$HOME/.local/libexec" "$HOME/.config/msw" "$HOME/.local/share/msw/docs" "$HOME/.local/state/msw"
chmod 0700 "$HOME/.local/state/msw"
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
  brew install gnu-tar zstd git-lfs gh

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
install -m 0755 "$SCRIPT_DIR/bin/msw-github-host-token" "$HOME/.local/libexec/msw-github-host-token"
install -m 0755 "$SCRIPT_DIR/bin/msw-keychain-bridge" "$HOME/.local/libexec/msw-keychain-bridge"
install -m 0755 "$SCRIPT_DIR/lib/msw-github-relay.py" "$HOME/.local/libexec/msw-github-relay.py"
install -m 0755 "$SCRIPT_DIR/lib/msw-github-shuttle.py" "$HOME/.local/libexec/msw-github-shuttle.py"
install -m 0755 "$SCRIPT_DIR/lib/msw-port-forwarder.py" "$HOME/.local/libexec/msw-port-forwarder.py"
# Path C §4 proxy stack: wrapper + core + upstream + vendored h11. The
# wrapper resolves ../lib relative to its own location, so these exact
# destinations keep it working unchanged.
install -m 0755 "$SCRIPT_DIR/bin/msw-github-proxy" "$HOME/.local/bin/msw-github-proxy"
install -d -m 0755 "$HOME/.local/lib"
install -m 0644 "$SCRIPT_DIR/lib/proxycore.py" "$HOME/.local/lib/proxycore.py"
install -m 0644 "$SCRIPT_DIR/lib/proxy-upstream.py" "$HOME/.local/lib/proxy-upstream.py"
if [[ -d "$SCRIPT_DIR/lib/vendor/h11" ]]; then
  # Replace the installed subtree atomically (never copy over it): a proxy
  # import may have left __pycache__/*.pyc behind, which the vendored-h11
  # hash gate rejects as unlisted files. Populate a fresh tree, then swap.
  # Stage beside the destination so the final swap is a same-filesystem
  # atomic rename (mktemp under TMPDIR can be a different volume).
  h11_tmp="$HOME/.local/lib/.msw-h11.$$"
  rm -rf "$h11_tmp"
  mkdir -p "$h11_tmp" || fatal "could not stage the vendored h11 tree"
  (
    cd "$SCRIPT_DIR/lib/vendor/h11" || exit 1
    find . -type d -exec mkdir -p "$h11_tmp/{}" \;
    find . -type f -exec install -m 0644 "{}" "$h11_tmp/{}" \;
  ) || { rm -rf "$h11_tmp"; fatal "could not stage the vendored h11 tree"; }
  find "$h11_tmp" -type d -exec chmod 0755 {} \;
  rm -rf "$HOME/.local/lib/vendor/h11"
  mkdir -p "$HOME/.local/lib/vendor" || { rm -rf "$h11_tmp"; fatal "could not install the vendored h11 tree"; }
  mv "$h11_tmp" "$HOME/.local/lib/vendor/h11" || { rm -rf "$h11_tmp"; fatal "could not install the vendored h11 tree"; }
fi
install -m 0644 "$SCRIPT_DIR/launchd/org.microsandbox.MSWMonitor.github-proxy.plist" "$HOME/.local/share/msw/github-proxy.plist"
install -m 0644 "$SCRIPT_DIR/docs/"*.md "$HOME/.local/share/msw/docs/"
install -m 0644 "$SCRIPT_DIR/README.md" "$HOME/.local/share/msw/README.md"

# shellcheck source=/dev/null
source "$HOME/.config/msw/config.sh"

MSW_WORKSPACES_FILE="${MSW_WORKSPACES_FILE:-$HOME/.config/msw/workspaces.json}"
workspace_config_valid() {
  [[ -f "$1" && ! -L "$1" && $(wc -c <"$1") -le 262144 ]] || return 1
  jq -e '
    type == "object" and
    (keys | sort) == ["schemaVersion", "workspaces"] and
    .schemaVersion == 1 and
    (.workspaces | type == "array" and length > 0 and length <= 64) and
    ([.workspaces[].name] | length == (unique | length)) and
    ([.workspaces[] |
      (type == "object") and
      (keys | sort) == ["cpu", "cpuCeiling", "memoryCeilingGiB", "memoryGiB", "name", "runtimeStorageGiB", "workspaceStorageGiB"] and
      (.name | type == "string" and test("^[a-z][a-z0-9-]{0,31}$")) and
      (.cpu | type == "number" and floor == . and IN(4,6,8,12)) and
      (.cpuCeiling | type == "number" and floor == . and IN(4,6,8,12)) and
      (.memoryGiB | type == "number" and floor == . and IN(16,32,48)) and
      (.memoryCeilingGiB | type == "number" and floor == . and IN(16,32,48)) and
      (.workspaceStorageGiB | type == "number" and floor == . and IN(60,80,100,120)) and
      (.runtimeStorageGiB | type == "number" and floor == . and IN(60,80,100,120)) and
      .cpu <= .cpuCeiling and .memoryGiB <= .memoryCeilingGiB
    ] | all)
  ' "$1" >/dev/null 2>&1
}

if [[ ! -f "$MSW_WORKSPACES_FILE" ]]; then
  default_workspace_config="$(mktemp "$HOME/.config/msw/.workspaces-default.XXXXXX")"
  jq -n \
    --argjson devCPU "$MSW_DEV_CPUS" --argjson devMaxCPU "$MSW_DEV_MAX_CPUS" \
    --argjson devMemory "${MSW_DEV_MEMORY%G}" --argjson devMaxMemory "${MSW_DEV_MAX_MEMORY%G}" \
    --argjson devWorkspace "${MSW_DEV_WORKSPACE_SIZE%G}" --argjson devRuntime "${MSW_DEV_RUNTIME_SIZE%G}" \
    --argjson playgroundsCPU "$MSW_PLAYGROUNDS_CPUS" --argjson playgroundsMaxCPU "$MSW_PLAYGROUNDS_MAX_CPUS" \
    --argjson playgroundsMemory "${MSW_PLAYGROUNDS_MEMORY%G}" --argjson playgroundsMaxMemory "${MSW_PLAYGROUNDS_MAX_MEMORY%G}" \
    --argjson playgroundsWorkspace "${MSW_PLAYGROUNDS_WORKSPACE_SIZE%G}" --argjson playgroundsRuntime "${MSW_PLAYGROUNDS_RUNTIME_SIZE%G}" \
    --argjson personalCPU "$MSW_PERSONAL_CPUS" --argjson personalMaxCPU "$MSW_PERSONAL_MAX_CPUS" \
    --argjson personalMemory "${MSW_PERSONAL_MEMORY%G}" --argjson personalMaxMemory "${MSW_PERSONAL_MAX_MEMORY%G}" \
    --argjson personalWorkspace "${MSW_PERSONAL_WORKSPACE_SIZE%G}" --argjson personalRuntime "${MSW_PERSONAL_RUNTIME_SIZE%G}" \
    '{schemaVersion:1,workspaces:[
      {name:"dev",cpu:$devCPU,cpuCeiling:$devMaxCPU,memoryGiB:$devMemory,memoryCeilingGiB:$devMaxMemory,workspaceStorageGiB:$devWorkspace,runtimeStorageGiB:$devRuntime},
      {name:"playgrounds",cpu:$playgroundsCPU,cpuCeiling:$playgroundsMaxCPU,memoryGiB:$playgroundsMemory,memoryCeilingGiB:$playgroundsMaxMemory,workspaceStorageGiB:$playgroundsWorkspace,runtimeStorageGiB:$playgroundsRuntime},
      {name:"personal",cpu:$personalCPU,cpuCeiling:$personalMaxCPU,memoryGiB:$personalMemory,memoryCeilingGiB:$personalMaxMemory,workspaceStorageGiB:$personalWorkspace,runtimeStorageGiB:$personalRuntime}
    ]}' >"$default_workspace_config"
  chmod 0600 "$default_workspace_config"
  mv "$default_workspace_config" "$MSW_WORKSPACES_FILE"
fi
workspace_config_valid "$MSW_WORKSPACES_FILE" || fatal "invalid persisted workspace configuration"
WORKSPACES=()
while IFS= read -r box; do WORKSPACES+=("$box"); done < <(jq -r '.workspaces[].name' "$MSW_WORKSPACES_FILE")
workspace_config_value() {
  jq -er --arg workspace "$1" --arg field "$2" '.workspaces[] | select(.name == $workspace) | .[$field]' "$MSW_WORKSPACES_FILE"
}
workspace_host() { printf '%s.msw.test\n' "$1"; }

# Path C §1: mode defaults to local; validate before any workspace work.
: "${MSW_GITHUB_MODE:=local}"
: "${MSW_GITHUB_PROXY_PORT:=18446}"
case "$MSW_GITHUB_MODE" in
  local|connect) ;;
  *) fatal "invalid MSW_GITHUB_MODE '$MSW_GITHUB_MODE' (expected local or connect)" ;;
esac

verify_installed_proxy_hashes() {
  # Fail-closed: every installed proxy-stack file must match MANIFEST.txt.
  local entry sha actual
  for entry in bin/msw-github-proxy lib/proxycore.py lib/proxy-upstream.py; do
    sha="$(awk -v p="$entry" '$2 == p {print $1}' "$SCRIPT_DIR/MANIFEST.txt")"
    [[ -n "$sha" ]] || fatal "MANIFEST.txt is missing an entry for $entry"
    actual="$("/usr/bin/shasum" -a 256 "$HOME/.local/$entry" 2>/dev/null | awk '{print $1}')"
    [[ "$actual" == "$sha" ]] || fatal "installed $entry failed hash verification (manifest $sha, installed ${actual:-<unreadable>})"
  done
}

launchd_job_pid() {
  # usage: launchd_job_pid LABEL  → prints the job's pid ("" when idle/absent)
  local label="$1" out
  out="$(/bin/launchctl print "gui/$(id -u)/$label" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | awk '/^[[:space:]]*pid = / {print $3; exit}'
}

verify_launchd_job_alive() {
  # usage: verify_launchd_job_alive LABEL [socket]
  # Fail-closed post-bootstrap check: every launchd job must be loaded, and
  # KeepAlive jobs (the per-workspace port forwarders) must be running AND
  # stay alive across a short grace period — catching a crash-looping agent
  # (e.g. one whose log directory never existed on a fresh home). Socket-
  # activated agents (the GitHub proxy, Wait=false) are idle-valid: launchd
  # owns the listener, so a loaded, registered job is a live job even while
  # no process is running. Any failed check fails the install.
  local label="$1" socket_mode="${2:-}" attempt pid1 pid2
  for attempt in 1 2 3; do
    if [[ "$socket_mode" == socket ]]; then
      /bin/launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && return 0
    else
      pid1="$(launchd_job_pid "$label" 2>/dev/null || true)"
      if [[ "$pid1" =~ ^[0-9]+$ ]]; then
        sleep 2
        pid2="$(launchd_job_pid "$label" 2>/dev/null || true)"
        [[ -n "$pid2" && "$pid2" == "$pid1" ]] && return 0
      fi
    fi
    sleep 1
  done
  return 1
}

log "Verifying the installed proxy and vendored h11"
verify_installed_proxy_hashes
MSW_VENDOR_H11_DIR="$HOME/.local/lib/vendor/h11" MSW_MANIFEST_FILE="$SCRIPT_DIR/MANIFEST.txt" \
  "$HOME/.local/bin/msw" __verify-vendored-h11 || fatal "installed vendored h11 failed verification"

log "Rendering the GitHub proxy launch agent"
"$HOME/.local/bin/msw" __proxy-plist-render || fatal "could not render the GitHub proxy launch agent plist"
if [[ "$TEST_MODE" != 1 && "$MSW_GITHUB_MODE" == local ]]; then
  "$HOME/.local/bin/msw" github proxy install || fatal "could not install the GitHub proxy launch agent"
  # Socket-activated agent (Wait=false): a loaded, registered job owns the
  # 127.0.0.1:18446 listener, so loaded == idle-valid and live.
  verify_launchd_job_alive org.microsandbox.MSWMonitor.github-proxy socket \
    || fatal "the GitHub proxy launch agent is not loaded; check ~/Library/Logs/MSWMonitor/github-proxy.log"
fi

log "Checking MicroSandbox"
if ! "$MSB_BIN" doctor; then
  "$MSB_BIN" doctor --fix
  "$MSB_BIN" doctor
fi

log "Configuring browser names, loopback addresses, and SSH"
"$HOME/.local/bin/msw" host repair

HOST_CPUS="${MSW_TEST_HOST_CPUS:-}"
if [[ -z "$HOST_CPUS" ]]; then HOST_CPUS="$(/usr/sbin/sysctl -n hw.logicalcpu)"; fi
cap_cpu() { local requested="$1"; (( requested > HOST_CPUS )) && printf '%s\n' "$HOST_CPUS" || printf '%s\n' "$requested"; }
snapshot_exists() { "$MSB_BIN" snapshot inspect "$MSW_BASE_SNAPSHOT" >/dev/null 2>&1; }
sandbox_exists() { workspace_msb "$1" inspect "$1" >/dev/null 2>&1; }
workspace_msb() {
  local box="$1" token="" status
  shift
  if token="$(keychain_read_token "$box" 2>/dev/null)"; then
    if GH_TOKEN="$token" "$MSB_BIN" "$@"; then
      status=0
    else
      status=$?
    fi
    unset token
    return "$status"
  fi
  if [[ -f "$HOME/.config/msw/github/${box}.conf" || -f "$HOME/.config/msw/github/${box}.quarantine" ]]; then
    if [[ "$MSW_GITHUB_MODE" == local ]]; then
      fatal "GitHub is configured for '$box', but its read token is missing from Keychain. Run: msw github migrate $box, then msw github auth (or connect GitHub in MSW Monitor)"
    else
      fatal "GitHub is configured for '$box', but its read token is missing from Keychain. Reconnect GitHub in MSW Monitor"
    fi
  fi
  "$MSB_BIN" "$@"
}
volume_exists() { "$MSB_BIN" volume inspect "$1" >/dev/null 2>&1; }

# Disk named volumes must exist and finish their one-time ext4 initialization
# before they are attached to a VM. MicroSandbox assigns the first named disk
# mount (/workspace) to /dev/vdc; creating it implicitly during `run` allowed
# agentd to race the formatter and retain a misleading EINVAL mount failure.
# Existing volumes are only inspected. Unknown, blank, or damaged storage is
# never formatted here.
VOLUME_INSPECT_OUTPUT=""

volume_probe() {
  local name="$1" output
  VOLUME_INSPECT_OUTPUT=""
  if output="$(LC_ALL=C "$MSB_BIN" volume inspect "$name" 2>&1)"; then
    VOLUME_INSPECT_OUTPUT="$output"
    return 0
  fi
  [[ "$output" == "error: volume not found: $name" ]] && return 1
  return 2
}

volume_inspect_field() {
  local field="$1"
  printf '%s\n' "$VOLUME_INSPECT_OUTPUT" |
    awk -F: -v field="$field" '$1 == field { sub(/^[[:space:]]+/, "", $2); print $2; exit }'
}

ext4_volume_status() {
  local name="$1" kind filesystem path magic expected probe_status
  if volume_probe "$name"; then :; else probe_status=$?; return "$probe_status"; fi
  kind="$(volume_inspect_field Kind)"
  filesystem="$(volume_inspect_field Filesystem)"
  [[ "$kind" == disk && "$filesystem" == ext4 ]] || return 3
  if [[ "$TEST_MODE" == 1 ]]; then
    magic="$(volume_inspect_field Magic)"
    [[ -z "$magic" || "$magic" == 53ef ]] || return 3
    return 0
  fi
  path="$(volume_inspect_field Path)"
  expected="$HOME/.microsandbox/volumes/$name/disk.raw"
  [[ "$path" == "$expected" && -f "$path" && ! -L "$path" ]] || return 3
  magic="$(dd if="$path" bs=1 skip=1080 count=2 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
  [[ "$magic" == 53ef ]] || return 3
}

ensure_ext4_volume() {
  local name="$1" size="$2" status
  if ext4_volume_status "$name"; then return; else status=$?; fi
  (( status != 2 )) || fatal "could not determine whether workspace storage '$name' exists; no disk was created"
  (( status != 3 )) || fatal "workspace storage '$name' is not a verified ext4 disk; inspect it and restore from backup instead of formatting it"
  # `volume create --kind disk` owns the only formatting transition. We call
  # it only after an authoritative not-found result and never retry it after
  # the name exists, so a newly allocated blank image is formatted once.
  "$MSB_BIN" volume create "$name" --kind disk --size "$size" -q >/dev/null ||
    fatal "could not create workspace storage '$name'"
  ext4_volume_status "$name" ||
    fatal "new workspace storage '$name' did not initialize as ext4; it was retained for inspection"
}

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
  ensure_ext4_volume msw-base-runtime-temporary 24G

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

# Published ports are NOT passed to msb (see create_workspace): they are
# forwarded host-side over SSH by lib/msw-port-forwarder.py, which probes the
# bind address at runtime and skips occupied ports with a warning instead of
# ever failing or recreating a workspace.

wait_for_guest_systemd() {
  local box="$1" attempt=0
  until workspace_msb "$box" exec --no-tty "$box" -- systemctl daemon-reload >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    (( attempt < 120 )) || fatal "$box systemd bus did not become ready"
    sleep 1
  done
}

configure_workspace_guest() {
  local box="$1" browser_host="$2"
  wait_for_guest_systemd "$box"
  workspace_msb "$box" exec --no-tty "$box" -- bash -s -- "$box" "$browser_host" "$MSW_GITHUB_MODE" <<'GUEST'
set -Eeuo pipefail
workspace="$1"; browser_host="$2"; github_mode="$3"
mkdir -p /workspace /var/lib/msw-runtime/docker /var/lib/msw-runtime/containerd
printf 'export MSW_WORKSPACE=%q\nexport MSW_BROWSER_HOST=%q\nexport HOST=%q\nexport BIND_ADDRESS=%q\nexport __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=%q\n' \
  "$workspace" "$browser_host" "0.0.0.0" "0.0.0.0" "$browser_host" \
  >/etc/profile.d/msw-workspace.sh
chmod 0644 /etc/profile.d/msw-workspace.sh
hostnamectl set-hostname "msw-$workspace"
printf '%s\n' "$workspace" >/workspace/.msw-workspace
printf 'MicroSandbox workspace: %s\n\n  Code:       /workspace\n  Browser:    http://%s:<published-port>\n  Docker:     docker compose up --build\n  Runtimes:   mise use <tool>@<version>\n  Python:     uv sync / uv run ...\n' \
  "$workspace" "$browser_host" >/etc/motd
if [ "$github_mode" = local ]; then
  cat >>/etc/motd <<'MOTD'
  GitHub:     use git inside the workspace. GitHub API calls are not supported
              here; run API operations from the Mac.
MOTD
fi
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
  local box="$1" browser_host="$2" cpus="$3" max_cpus="$4" memory="$5" max_memory="$6" workspace_size="$7" runtime_size="$8"
  local effective_cpus effective_max token="" run_args=()
  effective_cpus="$(cap_cpu "$cpus")"; effective_max="$(cap_cpu "$max_cpus")"
  (( effective_cpus > effective_max )) && effective_cpus="$effective_max"

  if sandbox_exists "$box" && [[ "$RECREATE_WORKSPACES" == 1 ]]; then
    warn "recreating $box root; its repository and Docker volumes are preserved"
    workspace_msb "$box" rm -f "$box"
    # A recreated VM regenerates its host keys; drop the stale entry from the
    # dedicated MSW known-hosts file (never ~/.ssh/known_hosts) so the next
    # SSH connection accepts the new key. Only this box's entry is removed.
    if [[ -f "$HOME/.ssh/msw_known_hosts" ]]; then
      ssh-keygen -R "${box}.msb" -f "$HOME/.ssh/msw_known_hosts" >/dev/null 2>&1 || true
    fi
  fi

  if ! sandbox_exists "$box"; then
    log "Creating workspace: $box"
    ensure_ext4_volume "msw-${box}-workspace" "$workspace_size"
    ensure_ext4_volume "msw-${box}-runtime" "$runtime_size"
    run_args+=(--name "$box" --from-snapshot "$MSW_BASE_SNAPSHOT")
    run_args+=(--cpus "$effective_cpus" --max-cpus "$effective_max")
    run_args+=(--memory "$memory" --max-memory "$max_memory")
    run_args+=(--mount-named "msw-${box}-workspace:/workspace:kind=disk,size=${workspace_size}")
    run_args+=(--mount-named "msw-${box}-runtime:/var/lib/msw-runtime:kind=disk,size=${runtime_size}")
    run_args+=(--workdir /workspace --init auto --security default --net public --tls-intercept)
    run_args+=(--label "msw.managed=true" --label "msw.workspace=${box}")
    run_args+=(--env "MSW_WORKSPACE=${box}" --env "MSW_BROWSER_HOST=${browser_host}")
    run_args+=(--env 'PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    run_args+=(--env SHELL=/usr/bin/zsh --env LANG=en_US.UTF-8)
    run_args+=(--env HOST=0.0.0.0 --env BIND_ADDRESS=0.0.0.0)
    run_args+=(--env "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=${browser_host}")
    run_args+=(-- sleep infinity)
    # Ports are NOT passed to msb: published ports are forwarded host-side
    # over SSH by lib/msw-port-forwarder.py, which skips occupied ports with
    # a warning instead of ever failing or recreating the workspace.
    "$MSB_BIN" run --detach "${run_args[@]}"
    "$HOME/.local/bin/msw" __workspace-state-init "$box" || warn "could not record the workspace state for $box"
    configure_workspace_guest "$box" "$browser_host"
    if [[ "$MSW_GITHUB_MODE" == connect ]]; then
      if token="$(keychain_read_token "$box" 2>/dev/null)"; then
        workspace_msb "$box" modify "$box" --secret "GH_TOKEN@${MSW_GITHUB_SECRET_HOSTS}" --next-start >/dev/null
        unset token
      fi
    fi
    workspace_msb "$box" stop -t 90 "$box"
  else
    echo "Workspace already exists: $box"
  fi
}

if [[ "$SKIP_WORKSPACES" != 1 ]]; then
  for box in "${WORKSPACES[@]}"; do
    create_workspace \
      "$box" "$(workspace_host "$box")" \
      "$(workspace_config_value "$box" cpu)" "$(workspace_config_value "$box" cpuCeiling)" \
      "$(workspace_config_value "$box" memoryGiB)G" "$(workspace_config_value "$box" memoryCeilingGiB)G" \
      "$(workspace_config_value "$box" workspaceStorageGiB)G" "$(workspace_config_value "$box" runtimeStorageGiB)G"
  done
fi

if [[ "$TEST_MODE" != 1 && "$SKIP_WORKSPACES" != 1 ]]; then
  log "Starting the host-managed published-port forwarders"
  for box in "${WORKSPACES[@]}"; do
    "$HOME/.local/bin/msw" __port-forwarder-start "$box" || warn "could not start the port forwarder for $box"
  done
  log "Verifying the host-managed published-port forwarders"
  for box in "${WORKSPACES[@]}"; do
    verify_launchd_job_alive "org.microsandbox.MSWMonitor.port-forwarder.$box" \
      || fatal "the published-port forwarder for $box did not stay loaded and running; inspect $HOME/.local/state/msw/port-forwarder-$box.log"
  done
fi

if [[ "$SKIP_WORKSPACES" != 1 ]]; then
  log "Running the complete local VM, Docker, SSH, internet, and browser-port test"
  "$HOME/.local/bin/msw" check --deep
fi

cat <<'DONE'

Setup complete. The installer has already run the full local end-to-end test.

Next:
  1. exec zsh -l
  2. msw identity "YOUR NAME" YOUR_EMAIL@example.com
  3. Connect GitHub per workspace: open MSW Monitor -> GitHub -> Connect,
     then tick the repositories each workspace may access. The installer
     installs the `gh` CLI (Homebrew), so a clean Mac signs in with gh's web
     OAuth flow and msw reuses the authenticated session automatically.
     CLI fallbacks: msw github auth | msw github status

Daily use:
  msw dev
  msw zed dev PATH
  msw open dev 3000
  msw backup
  msw help
DONE
