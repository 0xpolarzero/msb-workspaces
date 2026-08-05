# MSW command cheatsheet

## Enter and edit

```bash
msw dev [PATH]                 # Ghostty shell in dev
msw playgrounds [PATH]         # Shell in playgrounds
msw personal [PATH]            # Shell in personal
msw shell WORKSPACE [PATH]     # Generic form
msw zed WORKSPACE [PATH]       # Open in Zed
msw exec WORKSPACE COMMAND...  # Run command from /workspace
```

Examples:

```bash
msw dev
msw dev clients/acme/backend
msw zed personal apps/site
msw exec playgrounds node --version
```

## Repositories

```bash
msw clone WORKSPACE OWNER/REPO [PATH]
msw repos WORKSPACE
msw pull WORKSPACE [PATH|all]
msw identity "NAME" EMAIL [WORKSPACE|all]
```

Examples:

```bash
msw clone dev acme/backend clients/acme/backend
msw clone dev acme/frontend clients/acme/frontend
msw repos dev
msw pull dev clients/acme/backend
msw pull dev all
msw identity "Ada Lovelace" ada@example.com
```

## GitHub permissions

```bash
msw github setup WORKSPACE OWNER/VERIFICATION-REPO
msw github verify WORKSPACE [OWNER/REPO]
msw github status [WORKSPACE|all]
msw github remove WORKSPACE
```

Set up every group:

```bash
msw github setup dev OWNER/msw-verification
msw github setup playgrounds OWNER/msw-verification
msw github setup personal OWNER/msw-verification
```

## Push from the Mac

```bash
msw push WORKSPACE PATH
msw push WORKSPACE PATH --yes
msw push WORKSPACE PATH --force-with-lease
```

Examples:

```bash
msw push dev clients/acme/backend
msw push personal apps/site --yes
msw push dev clients/acme/backend --force-with-lease
```

Default pushes are fast-forward-only. Only the current committed branch is sent.

## Websites and ports

```bash
msw open WORKSPACE [PORT] [http|https]
msw url WORKSPACE [PORT] [http|https]
msw ports [WORKSPACE|all]
msw tunnel WORKSPACE REMOTE_PORT [LOCAL_PORT]
```

Examples:

```bash
msw open dev 3000
msw open playgrounds 5173
msw url personal 8080
msw tunnel dev 12345
msw tunnel dev 12345 9001
```

Fixed names:

```text
http://dev.msw.test:<port>
http://playgrounds.msw.test:<port>
http://personal.msw.test:<port>
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
msw exec dev docker ps
msw exec dev docker compose -f /workspace/PROJECT/compose.yml ps
```

Cleanup:

```bash
msw clean [WORKSPACE|all]             # Preserve Docker volumes
msw clean [WORKSPACE|all] --volumes   # Also delete unused volumes
```

## Lifecycle

```bash
msw start [WORKSPACE|all]
msw stop [WORKSPACE|all]
msw restart [WORKSPACE|all]
msw status
msw logs WORKSPACE [MSB LOG OPTIONS]
```

Examples:

```bash
msw start all
msw stop playgrounds
msw restart dev
msw status
msw logs dev
```

Entering with Ghostty, opening in Zed, or using `msw open` starts a stopped VM automatically.

## Resources and maintenance

```bash
msw metrics [WORKSPACE|all]
msw disk [WORKSPACE|all]
msw resize WORKSPACE MEMORY [CPUS]
msw upgrade [WORKSPACE|all]
msw update
msw check
msw check --deep
msw host repair
```

Examples:

```bash
msw metrics dev
msw disk all
msw resize dev 32G 10
msw upgrade all
msw check --deep
```

## Backup and restore

```bash
msw backup [DIRECTORY]
msw restore ARCHIVE
msw restore ARCHIVE --yes
```

Examples:

```bash
msw backup
msw backup /Volumes/EncryptedBackup/MicroSandbox
msw restore ~/Backups/microsandbox/microsandbox-all-20260805-120000.tar.zst
```

A backup automatically stops and restarts only the VMs that were running. Restore leaves all VMs stopped.

## Documentation and version

```bash
msw docs
msw docs cheatsheet
msw docs setup
msw docs github
msw docs tests
msw version
msw help
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
