#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a
source .env
set +a

check() {
  local name="$1" url="$2"
  local host
  host="$(sed -E 's#https://([^/]+).*#\1#' <<<"$url")"
  for ((i=1; i<=180; i++)); do
    if curl --fail --silent --show-error --noproxy '*' --cacert certs/local-ca.crt \
      --resolve "${host}:443:127.0.0.1" "$url" >/dev/null 2>&1; then
      printf '[OK] %s: %s\n' "$name" "$url"
      return 0
    fi
    sleep 5
  done
  printf '[FAIL] %s: %s\n' "$name" "$url" >&2
  return 1
}

docker compose --profile runner ps
check Forgejo https://forgejo.dev/api/healthz

for ((i=1; i<=180; i++)); do
  SONAR_STATUS="$(curl --fail --silent --show-error --noproxy '*' \
    --cacert certs/local-ca.crt \
    --resolve sonar.dev:443:127.0.0.1 \
    https://sonar.dev/api/system/status 2>/dev/null |
    jq -r '.status // empty' 2>/dev/null || true)"
  if [[ "$SONAR_STATUS" == "UP" ]]; then
    printf '[OK] SonarQube: https://sonar.dev (UP)\n'
    break
  fi
  if ((i == 180)); then
    printf '[FAIL] SonarQube status: %s\n' "${SONAR_STATUS:-unreachable}" >&2
    exit 1
  fi
  sleep 5
done

check Rancher https://rancher.dev/ping

for ((i=1; i<=180; i++)); do
  if curl --fail --silent --show-error --noproxy '*' \
    --cacert certs/local-ca.crt \
    --resolve helm.dev:443:127.0.0.1 \
    -u "${CHARTMUSEUM_USER}:${CHARTMUSEUM_PASSWORD}" \
    https://helm.dev/health >/dev/null 2>&1; then
    printf '[OK] ChartMuseum: https://helm.dev\n'
    break
  fi
  if ((i == 180)); then
    printf '[FAIL] ChartMuseum: https://helm.dev\n' >&2
    exit 1
  fi
  sleep 5
done

if [[ "$(docker inspect -f '{{.State.Running}}' local-dev-platform-runner-1)" != true ]]; then
  printf '[FAIL] Forgejo runner is not running\n' >&2
  exit 1
fi
printf '[OK] Forgejo runner is running\n'
openssl verify -CAfile certs/local-ca.crt certs/local-dev.crt
