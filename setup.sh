#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD_BASE=0
RECREATE_WORKSPACES=0
RESET_CONFIG=0
SKIP_WORKSPACES=0
TEST_MODE="${SILO_TEST_MODE:-0}"

usage() {
  cat <<'HELP'
Usage: ./setup.sh [OPTIONS]

Options:
  --rebuild-base         Rebuild the reusable development snapshot.
  --recreate-workspaces  Recreate VM roots; repository and Docker volumes survive.
  --reset-config         Replace ~/.config/silo/config.sh with packaged defaults.
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

# ~/.local/state/silo must exist (private) BEFORE the GitHub proxy and
# port-forwarder launch agents are rendered/loaded: their launchd plists
# point StandardOutPath/StandardErrorPath into it, and a missing directory
# makes the jobs fail immediately on a clean home. setup.sh verifies every
# loaded job stays alive before reporting success.
mkdir -p "$HOME/.local/bin" "$HOME/.local/libexec" "$HOME/.config/silo" "$HOME/.local/share/silo/docs" "$HOME/.local/state/silo"
chmod 0700 "$HOME/.local/state/silo"
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

MSB_BIN="${SILO_MSB_BIN:-$(command -v msb 2>/dev/null || true)}"
[[ -n "$MSB_BIN" && -x "$MSB_BIN" ]] || fatal "msb is unavailable"
PYTHON_BIN="${SILO_PYTHON_BIN:-/usr/bin/python3}"
[[ -x "$PYTHON_BIN" ]] || fatal "python3 is unavailable"

log "Installing the Silo CLI and documentation"
if [[ "$RESET_CONFIG" == 1 || ! -f "$HOME/.config/silo/config.sh" ]]; then
  install -m 0644 "$SCRIPT_DIR/config.sh" "$HOME/.config/silo/config.sh"
else
  echo "Keeping existing $HOME/.config/silo/config.sh"
fi
install -m 0755 "$SCRIPT_DIR/lib/bootstrap-base.sh" "$HOME/.config/silo/bootstrap-base.sh"
install -m 0755 "$SCRIPT_DIR/bin/silo" "$HOME/.local/bin/silo"
install -m 0755 "$SCRIPT_DIR/bin/silo-ssh-proxy" "$HOME/.local/bin/silo-ssh-proxy"
install -m 0755 "$SCRIPT_DIR/bin/silo-git-askpass" "$HOME/.local/libexec/silo-git-askpass"
install -m 0755 "$SCRIPT_DIR/bin/silo-github-host-token" "$HOME/.local/libexec/silo-github-host-token"
install -m 0755 "$SCRIPT_DIR/bin/silo-keychain-bridge" "$HOME/.local/libexec/silo-keychain-bridge"
install -m 0755 "$SCRIPT_DIR/lib/silo-github-relay.py" "$HOME/.local/libexec/silo-github-relay.py"
install -m 0755 "$SCRIPT_DIR/lib/silo-github-shuttle.py" "$HOME/.local/libexec/silo-github-shuttle.py"
install -m 0755 "$SCRIPT_DIR/lib/silo-port-forwarder.py" "$HOME/.local/libexec/silo-port-forwarder.py"
# GitHub proxy stack: wrapper + core + upstream + vendored h11. The
# wrapper resolves ../lib relative to its own location, so these exact
# destinations keep it working unchanged.
install -m 0755 "$SCRIPT_DIR/bin/silo-github-proxy" "$HOME/.local/bin/silo-github-proxy"
install -d -m 0755 "$HOME/.local/lib"
install -m 0644 "$SCRIPT_DIR/lib/proxycore.py" "$HOME/.local/lib/proxycore.py"
install -m 0644 "$SCRIPT_DIR/lib/proxy-upstream.py" "$HOME/.local/lib/proxy-upstream.py"
if [[ -d "$SCRIPT_DIR/lib/vendor/h11" ]]; then
  # Replace the installed subtree atomically (never copy over it): a proxy
  # import may have left __pycache__/*.pyc behind, which the vendored-h11
  # hash gate rejects as unlisted files. Populate a fresh tree, then swap.
  # Stage beside the destination so the final swap is a same-filesystem
  # atomic rename (mktemp under TMPDIR can be a different volume).
  h11_tmp="$HOME/.local/lib/.silo-h11.$$"
  rm -rf "$h11_tmp"
  mkdir -p "$h11_tmp" || fatal "could not stage the vendored h11 tree"
  (
    cd "$SCRIPT_DIR/lib/vendor/h11" || exit 1
    find . -type d -name __pycache__ -prune -o -type d -exec mkdir -p "$h11_tmp/{}" \;
    find . -type d -name __pycache__ -prune -o -type f ! -name '*.pyc' -exec install -m 0644 "{}" "$h11_tmp/{}" \;
  ) || { rm -rf "$h11_tmp"; fatal "could not stage the vendored h11 tree"; }
  find "$h11_tmp" -type d -exec chmod 0755 {} \;
  rm -rf "$HOME/.local/lib/vendor/h11"
  mkdir -p "$HOME/.local/lib/vendor" || { rm -rf "$h11_tmp"; fatal "could not install the vendored h11 tree"; }
  mv "$h11_tmp" "$HOME/.local/lib/vendor/h11" || { rm -rf "$h11_tmp"; fatal "could not install the vendored h11 tree"; }
fi
install -m 0644 "$SCRIPT_DIR/launchd/org.silo.Silo.github-proxy.plist" "$HOME/.local/share/silo/github-proxy.plist"
install -m 0644 "$SCRIPT_DIR/docs/"*.md "$HOME/.local/share/silo/docs/"
install -m 0644 "$SCRIPT_DIR/README.md" "$HOME/.local/share/silo/README.md"

# shellcheck source=/dev/null
source "$HOME/.config/silo/config.sh"

SILO_WORKSPACES_FILE="${SILO_WORKSPACES_FILE:-$HOME/.config/silo/workspaces.json}"
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

if [[ ! -f "$SILO_WORKSPACES_FILE" ]]; then
  default_workspace_config="$(mktemp "$HOME/.config/silo/.workspaces-default.XXXXXX")"
  jq -n \
    --argjson devCPU "$SILO_DEV_CPUS" --argjson devMaxCPU "$SILO_DEV_MAX_CPUS" \
    --argjson devMemory "${SILO_DEV_MEMORY%G}" --argjson devMaxMemory "${SILO_DEV_MAX_MEMORY%G}" \
    --argjson devWorkspace "${SILO_DEV_WORKSPACE_SIZE%G}" --argjson devRuntime "${SILO_DEV_RUNTIME_SIZE%G}" \
    --argjson playgroundsCPU "$SILO_PLAYGROUNDS_CPUS" --argjson playgroundsMaxCPU "$SILO_PLAYGROUNDS_MAX_CPUS" \
    --argjson playgroundsMemory "${SILO_PLAYGROUNDS_MEMORY%G}" --argjson playgroundsMaxMemory "${SILO_PLAYGROUNDS_MAX_MEMORY%G}" \
    --argjson playgroundsWorkspace "${SILO_PLAYGROUNDS_WORKSPACE_SIZE%G}" --argjson playgroundsRuntime "${SILO_PLAYGROUNDS_RUNTIME_SIZE%G}" \
    --argjson personalCPU "$SILO_PERSONAL_CPUS" --argjson personalMaxCPU "$SILO_PERSONAL_MAX_CPUS" \
    --argjson personalMemory "${SILO_PERSONAL_MEMORY%G}" --argjson personalMaxMemory "${SILO_PERSONAL_MAX_MEMORY%G}" \
    --argjson personalWorkspace "${SILO_PERSONAL_WORKSPACE_SIZE%G}" --argjson personalRuntime "${SILO_PERSONAL_RUNTIME_SIZE%G}" \
    '{schemaVersion:1,workspaces:[
      {name:"dev",cpu:$devCPU,cpuCeiling:$devMaxCPU,memoryGiB:$devMemory,memoryCeilingGiB:$devMaxMemory,workspaceStorageGiB:$devWorkspace,runtimeStorageGiB:$devRuntime},
      {name:"playgrounds",cpu:$playgroundsCPU,cpuCeiling:$playgroundsMaxCPU,memoryGiB:$playgroundsMemory,memoryCeilingGiB:$playgroundsMaxMemory,workspaceStorageGiB:$playgroundsWorkspace,runtimeStorageGiB:$playgroundsRuntime},
      {name:"personal",cpu:$personalCPU,cpuCeiling:$personalMaxCPU,memoryGiB:$personalMemory,memoryCeilingGiB:$personalMaxMemory,workspaceStorageGiB:$personalWorkspace,runtimeStorageGiB:$personalRuntime}
    ]}' >"$default_workspace_config"
  chmod 0600 "$default_workspace_config"
  mv "$default_workspace_config" "$SILO_WORKSPACES_FILE"
fi
workspace_config_valid "$SILO_WORKSPACES_FILE" || fatal "invalid persisted workspace configuration"
WORKSPACES=()
while IFS= read -r box; do WORKSPACES+=("$box"); done < <(jq -r '.workspaces[].name' "$SILO_WORKSPACES_FILE")
workspace_config_value() {
  jq -er --arg workspace "$1" --arg field "$2" '.workspaces[] | select(.name == $workspace) | .[$field]' "$SILO_WORKSPACES_FILE"
}
workspace_host() { printf '%s.silo.test\n' "$1"; }

# Silo uses one repo-aware host-side GitHub transport.
: "${SILO_GITHUB_PROXY_PORT:=18446}"

verify_installed_proxy_hashes() {
  # Fail-closed: every installed proxy-stack file must match MANIFEST.txt.
  local entry sha actual
  for entry in bin/silo-github-proxy lib/proxycore.py lib/proxy-upstream.py; do
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
SILO_VENDOR_H11_DIR="$HOME/.local/lib/vendor/h11" SILO_MANIFEST_FILE="$SCRIPT_DIR/MANIFEST.txt" \
  "$HOME/.local/bin/silo" __verify-vendored-h11 || fatal "installed vendored h11 failed verification"

log "Rendering the GitHub proxy launch agent"
"$HOME/.local/bin/silo" __proxy-plist-render || fatal "could not render the GitHub proxy launch agent plist"
if [[ "$TEST_MODE" != 1 ]]; then
  "$HOME/.local/bin/silo" github proxy install || fatal "could not install the GitHub proxy launch agent"
  # Socket-activated agent (Wait=false): a loaded, registered job owns the
  # 127.0.0.1:18446 listener, so loaded == idle-valid and live.
  verify_launchd_job_alive org.silo.Silo.github-proxy socket \
    || fatal "the GitHub proxy launch agent is not loaded; check ~/Library/Logs/Silo/github-proxy.log"
fi

log "Checking MicroSandbox"
if ! "$MSB_BIN" doctor; then
  "$MSB_BIN" doctor --fix
  "$MSB_BIN" doctor
fi

log "Configuring browser names, loopback addresses, and SSH"
"$HOME/.local/bin/silo" host repair

HOST_CPUS="${SILO_TEST_HOST_CPUS:-}"
if [[ -z "$HOST_CPUS" ]]; then HOST_CPUS="$(/usr/sbin/sysctl -n hw.logicalcpu)"; fi
cap_cpu() { local requested="$1"; (( requested > HOST_CPUS )) && printf '%s\n' "$HOST_CPUS" || printf '%s\n' "$requested"; }
snapshot_exists() { "$MSB_BIN" snapshot inspect "$SILO_BASE_SNAPSHOT" >/dev/null 2>&1; }
sandbox_exists() { workspace_msb "$1" inspect "$1" >/dev/null 2>&1; }
workspace_msb() {
  local box="$1"
  shift
  "$MSB_BIN" "$@"
}
volume_exists() { "$MSB_BIN" volume inspect "$1" >/dev/null 2>&1; }

# Disk named volumes must exist and finish their one-time ext4 initialization
# before they are attached to a VM. MicroSandbox assigns the first named disk
# mount (/workspace) to /dev/vdc. Explicit creation makes MicroSandbox's atomic
# format-before-publish contract visible here, and the geometry check catches a
# truncated sparse image before agentd reports mount EINVAL. Existing volumes
# are only inspected. Unknown, blank, or damaged storage is never formatted.
VOLUME_INSPECT_OUTPUT=""
VOLUME_EXT4_DETAIL=""

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

file_size_bytes() {
  local path="$1" size=""
  size="$(/usr/bin/stat -f %z "$path" 2>/dev/null || true)"
  if [[ "$size" =~ ^[0-9]+$ ]]; then printf '%s\n' "$size"; return 0; fi
  size="$(/usr/bin/stat -c %s "$path" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$size"
}

ext4_u32_le() {
  local path="$1" offset="$2" raw b0 b1 b2 b3 extra=""
  raw="$(/bin/dd if="$path" bs=1 skip="$offset" count=4 2>/dev/null |
    /usr/bin/od -An -v -tx1)"
  read -r b0 b1 b2 b3 extra <<<"$raw"
  [[ "$b0" =~ ^[0-9a-fA-F]{2}$ && "$b1" =~ ^[0-9a-fA-F]{2}$ &&
     "$b2" =~ ^[0-9a-fA-F]{2}$ && "$b3" =~ ^[0-9a-fA-F]{2}$ && -z "$extra" ]] || return 1
  printf '%u\n' "$((16#$b0 + (16#$b1 << 8) + (16#$b2 << 16) + (16#$b3 << 24)))"
}

ext4_declared_bytes() {
  local path="$1" blocks_lo blocks_hi log_block_size block_size limit_blocks declared_blocks
  VOLUME_EXT4_DETAIL=""
  blocks_lo="$(ext4_u32_le "$path" 1028)" || {
    VOLUME_EXT4_DETAIL="The ext4 block count could not be read safely."
    return 1
  }
  log_block_size="$(ext4_u32_le "$path" 1048)" || {
    VOLUME_EXT4_DETAIL="The ext4 block size could not be read safely."
    return 1
  }
  blocks_hi="$(ext4_u32_le "$path" 1360)" || {
    VOLUME_EXT4_DETAIL="The ext4 high block count could not be read safely."
    return 1
  }
  if (( log_block_size > 6 )); then
    VOLUME_EXT4_DETAIL="The ext4 superblock declares an invalid block size."
    return 1
  fi
  block_size=$((1024 << log_block_size))
  limit_blocks=$((9223372036854775807 / block_size))
  if (( blocks_lo == 0 || blocks_hi > limit_blocks / 4294967296 )); then
    VOLUME_EXT4_DETAIL="The ext4 superblock declares an unsupported filesystem size."
    return 1
  fi
  limit_blocks=$((limit_blocks - blocks_hi * 4294967296))
  if (( blocks_lo > limit_blocks )); then
    VOLUME_EXT4_DETAIL="The ext4 superblock declares an unsupported filesystem size."
    return 1
  fi
  declared_blocks=$((blocks_hi * 4294967296 + blocks_lo))
  printf '%s\n' "$((declared_blocks * block_size))"
}

ext4_geometry_is_valid() {
  local path="$1" file_bytes declared_bytes
  file_bytes="$(file_size_bytes "$path")" || {
    VOLUME_EXT4_DETAIL="The backing image size could not be read safely."
    return 1
  }
  declared_bytes="$(ext4_declared_bytes "$path")" || return 1
  if (( file_bytes < declared_bytes )); then
    VOLUME_EXT4_DETAIL="The backing image is shorter than the filesystem declared by its ext4 superblock."
    return 1
  fi
}

fresh_ext4_image_finalize_fd() {
  local path="$1" requested_size="$2"
  [[ "${SILO_FAKE_FRESH_EXT4_FINALIZE_FAIL:-0}" != 1 ]] || return 1
  "$PYTHON_BIN" - "$path" "$requested_size" <<'PY'
import fcntl
import os
import re
import stat
import struct
import sys

path, requested = sys.argv[1:]
match = re.fullmatch(r"([1-9][0-9]*)G", requested)
if match is None:
    raise SystemExit(1)
expected_bytes = int(match.group(1)) * 1024 * 1024 * 1024
flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(path, flags)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    before = os.fstat(fd)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or before.st_nlink != 1
    ):
        raise SystemExit(1)

    def u32(offset: int) -> int:
        raw = os.pread(fd, 4, offset)
        if len(raw) != 4:
            raise SystemExit(1)
        return struct.unpack("<I", raw)[0]

    if os.pread(fd, 2, 1080) != b"\x53\xef":
        raise SystemExit(1)
    blocks_lo = u32(1028)
    log_block_size = u32(1048)
    blocks_hi = u32(1360)
    if blocks_lo == 0 or log_block_size > 6:
        raise SystemExit(1)
    block_size = 1024 << log_block_size
    declared_bytes = ((blocks_hi << 32) | blocks_lo) * block_size
    if declared_bytes != expected_bytes or before.st_size > declared_bytes:
        raise SystemExit(1)
    if before.st_size < declared_bytes:
        os.ftruncate(fd, declared_bytes)
        os.fsync(fd)
    after = os.fstat(fd)
    if (
        after.st_dev != before.st_dev
        or after.st_ino != before.st_ino
        or after.st_size != declared_bytes
        or os.pread(fd, 2, 1080) != b"\x53\xef"
        or u32(1028) != blocks_lo
        or u32(1048) != log_block_size
        or u32(1360) != blocks_hi
    ):
        raise SystemExit(1)
finally:
    os.close(fd)
PY
}

remove_owned_volume() {
  local name="$1" status
  "$MSB_BIN" volume rm "$name" >/dev/null 2>&1 || return 1
  if volume_probe "$name"; then return 1; else status=$?; fi
  (( status == 1 ))
}

finalize_fresh_ext4_volume() {
  local name="$1" requested_size="$2" kind format filesystem path expected magic
  volume_probe "$name" || return 1
  kind="$(volume_inspect_field Kind)"
  format="$(volume_inspect_field Format)"
  filesystem="$(volume_inspect_field Filesystem)"
  [[ "$kind" == disk && "$format" == raw && "$filesystem" == ext4 ]] || return 1
  if [[ "$TEST_MODE" == 1 && "${SILO_TEST_VALIDATE_RAW_DISKS:-0}" != 1 ]]; then
    magic="$(volume_inspect_field Magic)"
    [[ -z "$magic" || "$magic" == 53ef ]]
    return
  fi
  path="$(volume_inspect_field Path)"
  expected="$HOME/.microsandbox/volumes/$name/disk.raw"
  [[ "$path" == "$expected" && -f "$path" && ! -L "$path" ]] || return 1
  fresh_ext4_image_finalize_fd "$path" "$requested_size" || return 1
  ext4_volume_status "$name"
}

ext4_volume_status() {
  local name="$1" kind filesystem path magic expected probe_status
  VOLUME_EXT4_DETAIL=""
  if volume_probe "$name"; then :; else probe_status=$?; return "$probe_status"; fi
  kind="$(volume_inspect_field Kind)"
  filesystem="$(volume_inspect_field Filesystem)"
  [[ "$kind" == disk && "$filesystem" == ext4 ]] || return 3
  if [[ "$TEST_MODE" == 1 && "${SILO_TEST_VALIDATE_RAW_DISKS:-0}" != 1 ]]; then
    magic="$(volume_inspect_field Magic)"
    [[ -z "$magic" || "$magic" == 53ef ]] || return 3
    return 0
  fi
  path="$(volume_inspect_field Path)"
  expected="$HOME/.microsandbox/volumes/$name/disk.raw"
  [[ "$path" == "$expected" && -f "$path" && ! -L "$path" ]] || return 3
  magic="$(dd if="$path" bs=1 skip=1080 count=2 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
  [[ "$magic" == 53ef ]] || return 3
  ext4_geometry_is_valid "$path" || return 3
}

ensure_ext4_volume() {
  local name="$1" size="$2" status
  if ext4_volume_status "$name"; then return; else status=$?; fi
  (( status != 2 )) || fatal "could not determine whether workspace storage '$name' exists; no disk was created"
  (( status != 3 )) || fatal "workspace storage '$name' is not a verified ext4 disk.${VOLUME_EXT4_DETAIL:+ $VOLUME_EXT4_DETAIL} Restore a known-good backup or complete an offline filesystem assessment; existing storage was not changed"
  # `volume create --kind disk` owns the only formatting transition. We call
  # it only after an authoritative not-found result and never retry it after
  # the name exists, so a newly allocated blank image is formatted once.
  "$MSB_BIN" volume create "$name" --kind disk --size "$size" -q >/dev/null ||
    fatal "could not create workspace storage '$name'"
  if ! finalize_fresh_ext4_volume "$name" "$size"; then
    if remove_owned_volume "$name"; then
      fatal "new workspace storage '$name' was invalid; the fresh artifact was removed before any VM used it"
    fi
    fatal "new workspace storage '$name' was invalid and could not be removed safely; no VM used it, so remove that named volume before retrying"
  fi
}

validate_ports() {
  local token start end port seen=" "
  local old_ifs="$IFS"; IFS=','
  for token in $SILO_PUBLISHED_PORTS; do
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
  "$MSB_BIN" snapshot rm "$SILO_BASE_SNAPSHOT" --force
fi

if ! snapshot_exists; then
  log "Building the reusable Ubuntu development base"
  sandbox_exists "$SILO_BASE_BUILDER" && "$MSB_BIN" rm -f "$SILO_BASE_BUILDER" || true
  volume_exists silo-base-runtime-temporary && "$MSB_BIN" volume rm silo-base-runtime-temporary || true
  ensure_ext4_volume silo-base-runtime-temporary 24G

  BASE_CPUS="$(cap_cpu 8)"
  BASE_MAX_CPUS="$(cap_cpu 12)"
  (( BASE_CPUS > BASE_MAX_CPUS )) && BASE_CPUS="$BASE_MAX_CPUS"

  "$MSB_BIN" create "$SILO_BASE_IMAGE" \
    --name "$SILO_BASE_BUILDER" \
    --cpus "$BASE_CPUS" --max-cpus "$BASE_MAX_CPUS" \
    --memory 16G --max-memory 24G \
    --root-disk "$SILO_ROOT_DISK" \
    --mount-named "silo-base-runtime-temporary:/var/lib/silo-runtime:kind=disk,size=24G" \
    --mkdir /workspace --mkdir /var/lib/silo-runtime \
    --workdir /workspace --init auto --security default --net public \
    --label silo.role=base-builder

  "$MSB_BIN" exec --no-tty "$SILO_BASE_BUILDER" -- bash -s <"$HOME/.config/silo/bootstrap-base.sh"
  "$MSB_BIN" stop -t 120 "$SILO_BASE_BUILDER"
  "$MSB_BIN" snapshot create "$SILO_BASE_SNAPSHOT" --from "$SILO_BASE_BUILDER" --integrity --label silo.role=development-base
  "$MSB_BIN" snapshot verify "$SILO_BASE_SNAPSHOT"
  "$MSB_BIN" rm "$SILO_BASE_BUILDER"
  "$MSB_BIN" volume rm silo-base-runtime-temporary
else
  echo "Using existing base snapshot: $SILO_BASE_SNAPSHOT"
fi

# setup.sh and native app bootstrap share the CLI-owned safety probe. Keeping
# one implementation prevents the installer and app from attesting different
# disk behavior for the same msb binary.
if ! runtime_attestation="$("$HOME/.local/bin/silo" app runtime-attest --format json)"; then
  runtime_attestation_detail="$(printf '%s\n' "$runtime_attestation" | jq -r '
    if .error then
      (.error.message + " " + (.error.recovery // ""))
    else
      "MicroSandbox failed the Silo disk-safety check."
    end
  ' 2>/dev/null || true)"
  fatal "${runtime_attestation_detail:-MicroSandbox failed the Silo disk-safety check.}"
fi
if printf '%s\n' "$runtime_attestation" | jq -e '.result.cached == true' >/dev/null 2>&1; then
  echo "Raw-disk discard safety already attested for this msb binary; skipping the disposable probe"
else
  log "Raw-disk discard safety attested for $(basename "$MSB_BIN")"
fi

# Published ports are NOT passed to msb (see create_workspace): they are
# forwarded host-side over SSH by lib/silo-port-forwarder.py, which probes the
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
  workspace_msb "$box" exec --no-tty "$box" -- bash -s -- "$box" "$browser_host" <<'GUEST'
set -Eeuo pipefail
workspace="$1"; browser_host="$2"
mkdir -p /workspace /var/lib/silo-runtime/docker /var/lib/silo-runtime/containerd
printf 'export SILO_WORKSPACE=%q\nexport SILO_BROWSER_HOST=%q\nexport HOST=%q\nexport BIND_ADDRESS=%q\nexport __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=%q\n' \
  "$workspace" "$browser_host" "0.0.0.0" "0.0.0.0" "$browser_host" \
  >/etc/profile.d/silo-workspace.sh
chmod 0644 /etc/profile.d/silo-workspace.sh
hostnamectl set-hostname "silo-$workspace"
printf '%s\n' "$workspace" >/workspace/.silo-workspace
printf 'Silo workspace: %s\n\n  Code:       /workspace\n  Browser:    http://%s:<published-port>\n  Docker:     docker compose up --build\n  Runtimes:   mise use <tool>@<version>\n  Python:     uv sync / uv run ...\n' \
  "$workspace" "$browser_host" >/etc/motd
cat >>/etc/motd <<'MOTD'
  GitHub:     use git inside the workspace. GitHub API calls are not supported
              here; run API operations from the Mac.
MOTD
systemctl daemon-reload
systemctl enable containerd.service docker.service
systemctl restart containerd.service docker.service
timeout 120 bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
docker run --rm alpine:latest true
mkdir -p /workspace/.silo-docker-smoke
printf 'host\n' >/workspace/.silo-docker-smoke/in
docker run --rm -v /workspace/.silo-docker-smoke:/work alpine:latest sh -ceu 'grep -qx host /work/in; printf "container\n" >/work/out'
grep -qx container /workspace/.silo-docker-smoke/out
rm -rf /workspace/.silo-docker-smoke
sync
GUEST
}

create_workspace() {
  local box="$1" browser_host="$2" cpus="$3" max_cpus="$4" memory="$5" max_memory="$6" workspace_size="$7" runtime_size="$8"
  local effective_cpus effective_max run_args=()
  effective_cpus="$(cap_cpu "$cpus")"; effective_max="$(cap_cpu "$max_cpus")"
  (( effective_cpus > effective_max )) && effective_cpus="$effective_max"

  if sandbox_exists "$box" && [[ "$RECREATE_WORKSPACES" == 1 ]]; then
    warn "recreating $box root; its repository and Docker volumes are preserved"
    workspace_msb "$box" rm -f "$box"
    # A recreated VM regenerates its host keys; drop the stale entry from the
    # dedicated Silo known-hosts file (never ~/.ssh/known_hosts) so the next
    # SSH connection accepts the new key. Only this box's entry is removed.
    if [[ -f "$HOME/.ssh/silo_known_hosts" ]]; then
      ssh-keygen -R "${box}.msb" -f "$HOME/.ssh/silo_known_hosts" >/dev/null 2>&1 || true
    fi
  fi

  if ! sandbox_exists "$box"; then
    log "Creating workspace: $box"
    ensure_ext4_volume "silo-${box}-workspace" "$workspace_size"
    ensure_ext4_volume "silo-${box}-runtime" "$runtime_size"
    run_args+=(--name "$box" --from-snapshot "$SILO_BASE_SNAPSHOT")
    run_args+=(--cpus "$effective_cpus" --max-cpus "$effective_max")
    run_args+=(--memory "$memory" --max-memory "$max_memory")
    run_args+=(--mount-named "silo-${box}-workspace:/workspace:kind=disk,size=${workspace_size}")
    run_args+=(--mount-named "silo-${box}-runtime:/var/lib/silo-runtime:kind=disk,size=${runtime_size}")
    run_args+=(--workdir /workspace --init auto --security default --net public --tls-intercept)
    run_args+=(--label "silo.managed=true" --label "silo.workspace=${box}")
    run_args+=(--env "SILO_WORKSPACE=${box}" --env "SILO_BROWSER_HOST=${browser_host}")
    run_args+=(--env 'PATH=/root/.local/bin:/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    run_args+=(--env SHELL=/usr/bin/zsh --env LANG=en_US.UTF-8)
    run_args+=(--env HOST=0.0.0.0 --env BIND_ADDRESS=0.0.0.0)
    run_args+=(--env "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=${browser_host}")
    run_args+=(-- sleep infinity)
    # Ports are NOT passed to msb: published ports are forwarded host-side
    # over SSH by lib/silo-port-forwarder.py, which skips occupied ports with
    # a warning instead of ever failing or recreating the workspace.
    "$MSB_BIN" run --detach "${run_args[@]}"
    "$HOME/.local/bin/silo" __workspace-state-init "$box" || warn "could not record the workspace state for $box"
    configure_workspace_guest "$box" "$browser_host"
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
    "$HOME/.local/bin/silo" __port-forwarder-start "$box" || warn "could not start the port forwarder for $box"
  done
  log "Verifying the host-managed published-port forwarders"
  for box in "${WORKSPACES[@]}"; do
    verify_launchd_job_alive "org.silo.Silo.port-forwarder.$box" \
      || fatal "the published-port forwarder for $box did not stay loaded and running; inspect $HOME/.local/state/silo/port-forwarder-$box.log"
  done
fi

if [[ "$SKIP_WORKSPACES" != 1 ]]; then
  log "Running the complete local VM, Docker, SSH, internet, and browser-port test"
  "$HOME/.local/bin/silo" check --deep
fi

cat <<'DONE'

Setup complete. The installer has already run the full local end-to-end test.

Next:
  1. exec zsh -l
  2. silo identity "YOUR NAME" YOUR_EMAIL@example.com
  3. Configure GitHub per workspace: open Silo -> GitHub,
     then tick the repositories each workspace may access. The installer
     installs the `gh` CLI (Homebrew), so a clean Mac signs in with gh's web
     OAuth flow and silo reuses the authenticated session automatically.
     Terminal: silo github auth | silo github status

Daily use:
  silo dev
  silo zed dev PATH
  silo open dev 3000
  silo backup
  silo help
DONE
