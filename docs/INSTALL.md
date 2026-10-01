# Installation

## 1. Prerequisites

The host needs Docker Engine, Docker Compose v2+, OpenSSL, curl, jq, and an SSH
client. This machine already had them installed. SonarQube needs at least 4 GB
available RAM and `vm.max_map_count >= 524288`; this host reports `1048576`.

Verify:

```bash
docker info
docker compose version
sysctl vm.max_map_count
```

## 2. Local DNS

All service names must resolve to the Docker host. If local DNS already provides
these records, verify them with `getent hosts <name>`. Otherwise add:

```text
127.0.0.1 forgejo.local sonar.local rancher.local helm.local traefik.local
```

to `/etc/hosts`:

```bash
sudoedit /etc/hosts
```

If clients are on another machine, use the Docker host's LAN IP instead of
`127.0.0.1`.

## 3. Generate credentials, TLS, and directories

From this directory:

```bash
chmod +x scripts/*.sh
./scripts/install.sh
```

The script creates:

- `.env`: service and database passwords (mode 0600)
- `secrets/credentials.md`: documented user credentials (mode 0600)
- `secrets/forgejo-admin-ssh`: Forgejo administrator SSH private key
- `certs/local-ca.{crt,key}`: local certificate authority
- `certs/local-dev.{crt,key}`: server certificate for all local names
- separate `config/`, `data/`, `charts/`, and `backups/` trees

Back up the CA private key securely. Do not install or distribute
`certs/local-ca.key`; only distribute the `.crt`.

## 4. Trust the local CA

On Arch Linux:

```bash
sudo trust anchor --store certs/local-ca.crt
```

If `trust` is unavailable:

```bash
sudo pacman -S --needed ca-certificates-utils
sudo trust anchor --store certs/local-ca.crt
```

Firefox may use its own certificate store. Either enable
`security.enterprise_roots.enabled` in `about:config`, or import
`certs/local-ca.crt` under Settings > Privacy & Security > Certificates >
Authorities.

For another client machine, copy only `certs/local-ca.crt` and trust it using that
operating system's CA mechanism.

## 5. Start the base services

```bash
docker compose pull
docker compose up -d
docker compose ps
```

The first SonarQube and Rancher startup can take several minutes. Follow logs with:

```bash
docker compose logs -f sonarqube rancher
```

## 6. Bootstrap accounts and the Actions runner

```bash
./scripts/bootstrap.sh
```

This idempotent script creates the Forgejo administrator, uploads the generated
SSH public key, gets the site-wide Actions runner token, registers and starts the
Docker runner, changes SonarQube's default password, and creates its analysis
token. Resulting secrets are in `secrets/credentials.md`.

## 7. Verify

```bash
./scripts/verify.sh
```

Then open each URL from the table in `README.md`. Rancher initially uses the
bootstrap password from `secrets/credentials.md`; confirm the server URL is
`https://rancher.local` at first login.

## 8. Lifecycle

```bash
# Start, including the runner profile
docker compose --profile runner up -d

# Stop containers but retain data
docker compose --profile runner down

# View logs
docker compose --profile runner logs -f

# Create a database and file backup
./scripts/backup.sh

# Update images, recreate, and verify
docker compose pull
docker compose --profile runner up -d
./scripts/verify.sh
```

Never use `docker compose down -v` for this stack. Persistent state uses bind
mounts, but deletion of `data/`, `config/`, `charts/`, `certs/`, `.env`, or
`secrets/` is destructive.

The backup script briefly stops the Compose services after making PostgreSQL
logical dumps, archives a consistent filesystem snapshot (including root-owned
Rancher state), and restarts the entire stack including the runner.
