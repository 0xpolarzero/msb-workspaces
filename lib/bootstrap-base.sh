#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '\n==> %s\n' "$*"; }
export DEBIAN_FRONTEND=noninteractive HOME=/root

log "Installing Ubuntu development packages"
apt-get update
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y universe
apt-get update
apt-get install -y --no-install-recommends \
  apt-transport-https ca-certificates curl wget gnupg locales tzdata sudo \
  git git-lfs openssh-client \
  build-essential pkg-config ccache clang lld cmake ninja-build make autoconf automake \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libffi-dev liblzma-dev libncurses-dev libxml2-dev libxslt1-dev \
  python3 python3-venv python3-pip python-is-python3 \
  zsh bash-completion man-db neovim \
  jq ripgrep fd-find bat fzf direnv \
  tmux unzip zip xz-utils rsync less tree ncdu file acl \
  htop btop procps lsof strace shellcheck \
  dnsutils iproute2 iputils-ping netcat-openbsd socat sqlite3

for pkg in eza zoxide just; do
  apt-get install -y --no-install-recommends "$pkg" || true
done

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ln -snf /usr/share/zoneinfo/Europe/Paris /etc/localtime
echo Europe/Paris >/etc/timezone
ln -sf /usr/bin/fdfind /usr/local/bin/fd
ln -sf /usr/bin/batcat /usr/local/bin/bat
git lfs install --system --skip-repo

log "Applying development limits"
cat >/etc/sysctl.d/99-silo-development.conf <<'SYSCTL'
fs.inotify.max_user_watches=1048576
fs.inotify.max_user_instances=1024
fs.file-max=2097152
vm.max_map_count=262144
net.core.somaxconn=4096
SYSCTL
sysctl --system

log "Installing Docker Engine, Compose, and Buildx"
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done
install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
cat >/etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO

log "Installing GitHub CLI"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
  "$(dpkg --print-architecture)" >/etc/apt/sources.list.d/github-cli.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh

systemctl stop docker.service docker.socket containerd.service 2>/dev/null || true
mkdir -p /etc/docker /etc/containerd /var/lib/silo-runtime/docker /var/lib/silo-runtime/containerd
cat >/etc/docker/daemon.json <<'DOCKER_CONFIG'
{
  "data-root": "/var/lib/silo-runtime/docker",
  "features": { "containerd-snapshotter": true },
  "live-restore": true,
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "builder": { "gc": { "enabled": true, "defaultReservedSpace": "20GB" } },
  "default-address-pools": [{ "base": "10.200.0.0/16", "size": 24 }]
}
DOCKER_CONFIG
cat >/etc/containerd/config.toml <<'CONTAINERD_CONFIG'
version = 2
root = "/var/lib/silo-runtime/containerd"
CONTAINERD_CONFIG

dockerd --validate --config-file=/etc/docker/daemon.json
systemctl daemon-reload
systemctl enable containerd.service docker.service
systemctl start containerd.service docker.service
timeout 120 bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
docker run --rm hello-world
docker compose version
docker buildx version

log "Installing mise, uv, Node.js LTS, and pnpm"
curl -fsSL https://mise.run | sh
curl -LsSf https://astral.sh/uv/install.sh | sh
cat >/etc/profile.d/silo-tools.sh <<'PROFILE'
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export EDITOR=nvim
export VISUAL=nvim
export PAGER=less
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
PROFILE
chmod 0644 /etc/profile.d/silo-tools.sh
export PATH="/root/.local/bin:/root/.local/share/mise/shims:$PATH"
mise use --global node@lts pnpm@latest
npm config set update-notifier false

for profile in /root/.profile /root/.zprofile; do
  touch "$profile"
  grep -qxF '. /etc/profile.d/silo-tools.sh' "$profile" || echo '. /etc/profile.d/silo-tools.sh' >>"$profile"
done
cat >/root/.zshenv <<'ZSHENV'
. /etc/profile.d/silo-tools.sh
[ -f /etc/profile.d/silo-workspace.sh ] && . /etc/profile.d/silo-workspace.sh
ZSHENV
cat >/root/.zshrc <<'ZSHRC'
. /etc/profile.d/silo-tools.sh
[ -f /etc/profile.d/silo-workspace.sh ] && . /etc/profile.d/silo-workspace.sh

eval "$(mise activate zsh)"
eval "$(direnv hook zsh)"
if command -v zoxide >/dev/null 2>&1; then eval "$(zoxide init zsh)"; fi

autoload -Uz compinit && compinit
bindkey -e
setopt PROMPT_SUBST AUTO_CD INTERACTIVE_COMMENTS SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS
HISTFILE="$HOME/.zsh_history"
HISTSIZE=200000
SAVEHIST=200000
PROMPT='%F{cyan}[${SILO_WORKSPACE:-silo}]%f %F{blue}%~%f %# '

alias ll='ls -lah'
alias la='ls -A'
alias gs='git status --short --branch'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first'
  alias ll='eza -lah --git --group-directories-first'
fi
ZSHRC
chsh -s /usr/bin/zsh root

log "Configuring Git"
git config --system init.defaultBranch main
git config --system fetch.prune true
git config --system pull.ff only
git config --system rerere.enabled true
# Keep clones, submodules, and GitHub CLI operations on HTTPS so the guest
# reaches GitHub through the host's repo-aware proxy (host-proxy §7). No
# credentials are baked into the base image.
git config --system url.https://github.com/.insteadOf git@github.com:
git config --system --add url.https://github.com/.insteadOf ssh://git@github.com/
git config --system --add url.https://github.com/.insteadOf ssh://git@github.com:22/
gh config set git_protocol https --host github.com

# host-proxy §7: never prompt interactively for GitHub credentials inside a
# workspace; the proxy enforces access with the workspace capability.
cat >/etc/profile.d/silo-github.sh <<'PROFILE'
export GIT_TERMINAL_PROMPT=0
PROFILE
chmod 0644 /etc/profile.d/silo-github.sh

mkdir -p /workspace /var/lib/silo-runtime
chmod 0755 /workspace /var/lib/silo-runtime
cat >/etc/motd <<'MOTD'
Silo development workspace

  Code:      /workspace
  Docker:    docker compose up --build
  Runtimes:  mise use <tool>@<version>
  Python:    uv sync / uv run ...
  GitHub:    use git inside the workspace. GitHub API calls are not supported
             here; run API operations from the Mac.
MOTD

log "Validating base image"
printf 'Architecture: '; uname -m
printf 'Docker root: '; docker info --format '{{.DockerRootDir}}'
printf 'Docker storage: '; docker info --format '{{.Driver}}'
printf 'Node: '; node --version
printf 'pnpm: '; pnpm --version
printf 'uv: '; uv --version
printf 'mise: '; mise --version
printf 'gh: '; gh --version | head -n 1

sync
systemctl stop docker.service docker.socket containerd.service || true
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /etc/machine-id /var/lib/dbus/machine-id /var/lib/systemd/random-seed
: >/etc/machine-id
mkdir -p /var/lib/dbus
ln -sfn /etc/machine-id /var/lib/dbus/machine-id
sync
log "Base bootstrap complete"
