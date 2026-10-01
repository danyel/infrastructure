#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a
source .env
set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$ROOT/backups/$STAMP"
mkdir -p "$DEST"

docker compose exec -T forgejo-db pg_dump -U forgejo -d forgejo -Fc > "$DEST/forgejo.dump"
docker compose exec -T sonar-db pg_dump -U sonar -d sonar -Fc > "$DEST/sonar.dump"

restart_stack() {
  docker compose --profile runner up -d
}
trap restart_stack EXIT
docker compose --profile runner stop
docker run --rm \
  -v "$ROOT:/source:ro" \
  "${POSTGRES_IMAGE}" \
  tar -czf - -C /source \
  .env compose.yaml certs config data/forgejo data/rancher data/sonarqube charts secrets \
  > "$DEST/files.tar.gz"
restart_stack
trap - EXIT
printf 'Backup written to %s\n' "$DEST"
