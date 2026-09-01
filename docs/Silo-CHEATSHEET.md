# Silo command cheatsheet

## Enter and edit

```bash
silo dev [PATH]                 # Ghostty shell in dev
silo playgrounds [PATH]         # Shell in playgrounds
silo personal [PATH]            # Shell in personal
silo shell WORKSPACE [PATH]     # Generic form
silo zed WORKSPACE [PATH]       # Open in Zed
silo exec WORKSPACE COMMAND...  # Run command from /workspace
```

Examples:

```bash
silo dev
silo dev clients/acme/backend
silo zed personal apps/site
silo exec playgrounds node --version
```

## Repositories

```bash
silo clone WORKSPACE OWNER/REPO [PATH]
silo repos WORKSPACE
silo pull WORKSPACE [PATH|all]
silo identity "NAME" EMAIL [WORKSPACE|all]
```

Examples:

```bash
silo clone dev acme/backend clients/acme/backend
silo clone dev acme/frontend clients/acme/frontend
silo repos dev
silo pull dev clients/acme/backend
silo pull dev all
silo identity "Ada Lovelace" ada@example.com
```

## GitHub permissions

GitHub setup presents **Connect GitHub** and **Skip GitHub** in connect mode.
Local mode (`SILO_GITHUB_MODE=local`, the default) never binds a token into a
workspace: git reaches GitHub through a host proxy that enforces a per-workspace
capability, and the Mac holds one host credential (`silo github auth`) that the
proxy uses for every outbound request.

```bash
silo github auth [--force] [--json]        # Provision/rotate the host credential
silo github auth --device [--json]         # Start OAuth Device Flow (prints code once)
silo github auth --device-complete CODE    # One device-flow exchange attempt
silo github repos [--owner O] [--json]     # Discover GitHub repositories (picker)
silo github migrate [WORKSPACE|all]        # Retire legacy GitHub state (local mode)
silo github proxy-configure [WORKSPACE]    # Install the repo-aware proxy transport
silo github capability rotate WORKSPACE    # Rotate that workspace's capability
silo github verify WORKSPACE [OWNER/REPO]
silo github status [WORKSPACE|all]
silo github status [WORKSPACE|all] --format json
silo github remove WORKSPACE               # Revoke the host credential (local mode)
silo app github-policy-get [--workspace W] --format json
silo app github-policy-set --workspace W --repository OWNER/REPO --mode read-only|read-write [--remove] [--clear] --format json
```

`silo github remove` in local mode revokes the host credential (metadata first,
fail-closed). In connect mode it refuses current Connect grants because
revocation must be performed by Silo; use the app's workspace removal or
account disconnect action so the service grant and local credential state are
updated together.

## Host-held API secrets

Use **Silo → Secrets**. Configure a name, workspace scope, and allowed
HTTPS destinations (`api.example.com`, `*.example.com`, or `*`). Values remain
in macOS Keychain; guests receive placeholders. `*` requires explicit
confirmation. Add/edit/remove changes show **Restart required** for running
workspaces or **Applies on next start** for stopped workspaces.

## Push from the Mac

```bash
silo push WORKSPACE PATH
silo push WORKSPACE PATH --yes
silo push WORKSPACE PATH --force-with-lease
```

Examples:

```bash
silo push dev clients/acme/backend
silo push personal apps/site --yes
silo push dev clients/acme/backend --force-with-lease
```

Default pushes are fast-forward-only. Only the current committed branch is sent.

## Websites and ports

```bash
silo open WORKSPACE [PORT] [http|https]
silo url WORKSPACE [PORT] [http|https]
silo ports [WORKSPACE|all]
silo tunnel WORKSPACE REMOTE_PORT [LOCAL_PORT]
```

Examples:

```bash
silo open dev 3000
silo open playgrounds 5173
silo url personal 8080
silo tunnel dev 12345
silo tunnel dev 12345 9001
```

Fixed names:

```text
http://dev.silo.test:<port>
http://playgrounds.silo.test:<port>
http://personal.silo.test:<port>
```

The service inside the VM/container must listen on `0.0.0.0`.

Prepublished TCP ports:

```text
1234, 1337, 24678-24679, 3000-3010, 3100, 3333,
3306-3308, 4000-4005, 4173, 4200, 4321, 5001-5005,
5173-5180, 5432-5435, 5555, 6006, 6379-6382,
7001-7005, 8000-8010, 8080-8090, 8787, 8888,
9000-9005, 9229-9230, 27017-27019
```

Ports 24678 and 24679 are reserved for deep health checks.

Published ports are forwarded host-side over SSH by a per-workspace manager
(`lib/silo-port-forwarder.py`), so msb itself never binds them. A port that is
already in use is skipped with a warning instead of failing; the port is
forwarded again automatically once it is free. `silo app state` reports
`skippedPorts` and a `portWarning` per workspace.

## Docker

Inside a workspace:

```bash
docker compose up --build
docker compose up -d --build
docker compose ps
docker compose logs -f
docker compose down
```

From the Mac:

```bash
silo exec dev docker ps
silo exec dev docker compose -f /workspace/PROJECT/compose.yml ps
```

Cleanup:

```bash
silo clean [WORKSPACE|all]             # Preserve Docker volumes
silo clean [WORKSPACE|all] --volumes   # Also delete unused volumes
```

## Lifecycle

```bash
silo start [WORKSPACE|all]
silo stop [WORKSPACE|all]
silo restart [WORKSPACE|all]
silo status
silo logs WORKSPACE [MSB LOG OPTIONS]
```

Examples:

```bash
silo start all
silo stop playgrounds
silo restart dev
silo status
silo logs dev
```

Entering with Ghostty, opening in Zed, or using `silo open` starts a stopped VM automatically.

## Resources and maintenance

```bash
silo metrics [WORKSPACE|all]
silo disk [WORKSPACE|all]
silo resize WORKSPACE MEMORY [CPUS]
silo upgrade [WORKSPACE|all]
silo update
silo check
silo check --deep
silo host repair
```

Examples:

```bash
silo metrics dev
silo disk all
silo resize dev 32G 10
silo upgrade all
silo check --deep
```

## Backup and restore

```bash
silo backup [DIRECTORY]
silo restore ARCHIVE
silo restore ARCHIVE --yes
```

Examples:

```bash
silo backup
silo backup /Volumes/EncryptedBackup/Silo
silo restore ~/Backups/silo/silo-all-20260805-120000.tar.zst
```

A backup automatically stops and restarts only the VMs that were running. Restore leaves all VMs stopped.

## Documentation and version

```bash
silo docs
silo docs cheatsheet
silo docs setup
silo docs github
silo docs tests
silo version
silo help
```

## Installer repair modes

Run from the extracted package directory:

```bash
./setup.sh
./setup.sh --rebuild-base
./setup.sh --recreate-workspaces
./setup.sh --reset-config
```

Persistent `/workspace` and Docker runtime volumes survive workspace-root recreation. Always keep current backups before destructive maintenance.
