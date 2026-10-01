# Migration and recovery

## Move the environment

1. Stop writes and create a consistent backup:
   `./scripts/backup.sh`.
2. Stop the stack:
   `docker compose --profile runner down`.
3. Copy the entire project directory, including hidden `.env` and all ignored
   `certs/`, `config/`, `data/`, `charts/`, `secrets/`, and `backups/` content.
4. Preserve file ownership and modes, for example with
   `rsync -aHAX --numeric-ids SOURCE/ DEST/`.
5. On the destination, update the absolute paths in
   `config/runner/config.yaml`, or rerun `./scripts/install.sh` to replace the old
   project root with the new root.
6. Point the four DNS names to the destination host.
7. Ensure the destination trusts `certs/local-ca.crt`.
8. Run `docker compose --profile runner up -d`, then `./scripts/verify.sh`.

The CA and service certificate can move unchanged while the DNS names remain the
same. Protect `certs/local-ca.key`, `.env`, runner registration state, and all
private keys as secrets.

## What is persistent

| Path | Content |
|---|---|
| `config/` | Proxy/runner configuration and Forgejo runner registration; Rancher configuration lives with its data |
| `data/forgejo*` | Forgejo repositories and PostgreSQL database |
| `data/sonar*`, `data/sonarqube/` | SonarQube database, indexes, plugins, logs |
| `data/rancher/` | Rancher state |
| `data/runner/` | Runner cache |
| `charts/` | ChartMuseum packages and index |
| `certs/` | CA and server TLS keys/certificates |
| `secrets/` | Human credentials, SSH keys, API/runner tokens |

## Restore

For a whole-environment recovery, extract the `files.tar.gz` created by
`scripts/backup.sh` into a clean project copy before starting Compose. The
PostgreSQL custom dumps are additional logical recovery points. To restore one,
start its empty database container and run `pg_restore --clean --if-exists` using
the corresponding dump.
