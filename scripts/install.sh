#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

for command in docker openssl curl; do
  require "$command"
done
docker compose version >/dev/null
docker info >/dev/null

mkdir -p \
  backups certs charts secrets \
  config/{chartmuseum,forgejo,rancher,runner,sonarqube,traefik} \
  data/{forgejo,forgejo-db,rancher,runner,sonar-db,sonarqube/data,sonarqube/extensions,sonarqube/logs}

for keep in backups certs charts secrets config/forgejo config/rancher config/sonarqube data; do
  touch "$keep/.gitkeep"
done

if [[ ! -f .env ]]; then
  cp .env.example .env
  sed -i \
    -e "s/DOCKER_GID=replace-me/DOCKER_GID=$(stat -c '%g' /var/run/docker.sock)/" \
    -e "s/FORGEJO_DB_PASSWORD=replace-me/FORGEJO_DB_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/FORGEJO_ADMIN_PASSWORD=replace-me/FORGEJO_ADMIN_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/SONAR_DB_PASSWORD=replace-me/SONAR_DB_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/SONAR_ADMIN_PASSWORD=replace-me/SONAR_ADMIN_PASSWORD=A$(openssl rand -hex 23)a1!/" \
    -e "s/RANCHER_BOOTSTRAP_PASSWORD=replace-me/RANCHER_BOOTSTRAP_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/CHARTMUSEUM_PASSWORD=replace-me/CHARTMUSEUM_PASSWORD=$(openssl rand -hex 24)/" \
    .env
  chmod 600 .env
fi

set -a
source .env
set +a

if [[ ! -f certs/local-ca.key ]]; then
  openssl genrsa -out certs/local-ca.key 4096
  openssl req -x509 -new -sha256 -days 3650 \
    -key certs/local-ca.key \
    -out certs/local-ca.crt \
    -subj "/CN=Local Development CA/O=Local Development"
fi

if [[ ! -f certs/local-dev.key ]]; then
  openssl genrsa -out certs/local-dev.key 4096
fi
cat > certs/local-dev.ext <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=forgejo.dev
DNS.2=sonar.dev
DNS.3=rancher.dev
DNS.4=helm.dev
DNS.5=traefik.dev
DNS.6=auth.dev
DNS.7=*.auth.dev
DNS.8=*.guess.dev
DNS.9=tell.dev
EOF

required_sans=(
  "DNS:forgejo.dev"
  "DNS:sonar.dev"
  "DNS:rancher.dev"
  "DNS:helm.dev"
  "DNS:traefik.dev"
  "DNS:auth.dev"
  "DNS:*.auth.dev"
  "DNS:*.guess.dev"
  "DNS:tell.dev"
)
regenerate_certificate=false
if [[ ! -f certs/local-dev.crt ]]; then
  regenerate_certificate=true
else
  certificate_text="$(openssl x509 -in certs/local-dev.crt -noout -ext subjectAltName)"
  for required_san in "${required_sans[@]}"; do
    if [[ "$certificate_text" != *"$required_san"* ]]; then
      regenerate_certificate=true
      break
    fi
  done
fi

if [[ "$regenerate_certificate" == true ]]; then
  openssl req -new -sha256 \
    -key certs/local-dev.key \
    -out certs/local-dev.csr \
    -subj "/CN=auth.dev/O=Local Development"
  openssl x509 -req -sha256 -days 825 \
    -in certs/local-dev.csr \
    -CA certs/local-ca.crt \
    -CAkey certs/local-ca.key \
    -CAcreateserial \
    -extfile certs/local-dev.ext \
    -out certs/local-dev.crt
fi
chmod 600 certs/*.key .env

if [[ ! -f secrets/forgejo-admin-ssh ]]; then
  ssh-keygen -q -t ed25519 -N "" \
    -C "${FORGEJO_ADMIN_USER}@forgejo.dev" \
    -f secrets/forgejo-admin-ssh
fi
chmod 600 secrets/forgejo-admin-ssh

sed -i \
  "s|/home/dnoulet/go/infrasctruture|$ROOT|g" \
  config/runner/config.yaml

cat > secrets/credentials.md <<EOF
# Local development credentials

Generated: $(date --iso-8601=seconds)

| Service | URL / host | Username | Password / key |
|---|---|---|---|
| Forgejo web | https://forgejo.dev | \`${FORGEJO_ADMIN_USER}\` | \`${FORGEJO_ADMIN_PASSWORD}\` |
| Forgejo SSH | ssh://git@forgejo.dev:2222 | \`git\` | \`secrets/forgejo-admin-ssh\` |
| SonarQube | https://sonar.dev | \`admin\` | \`${SONAR_ADMIN_PASSWORD}\` |
| Rancher | https://rancher.dev | \`admin\` | \`${RANCHER_BOOTSTRAP_PASSWORD}\` |
| ChartMuseum | https://helm.dev | \`${CHARTMUSEUM_USER}\` | \`${CHARTMUSEUM_PASSWORD}\` |

The Forgejo API token, runner registration token, and SonarQube token are appended by
\`scripts/bootstrap.sh\`. Database credentials are retained in the root-only \`.env\`.
The local CA certificate is \`certs/local-ca.crt\`; its private key is
\`certs/local-ca.key\` and must never be shared.
EOF
chmod 600 secrets/credentials.md

docker compose config --quiet
printf 'Generated configuration, TLS material, SSH key, and credentials.\n'
printf 'Next: trust certs/local-ca.crt, then run docker compose up -d.\n'
