#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
set -a
source .env
set +a

CA="$ROOT/certs/local-ca.crt"
CURL=(
  curl --fail --silent --show-error --noproxy '*' --cacert "$CA"
  --resolve forgejo.dev:443:127.0.0.1
  --resolve sonar.dev:443:127.0.0.1
  --resolve rancher.dev:443:127.0.0.1
  --resolve helm.dev:443:127.0.0.1
)

wait_for() {
  local name="$1" url="$2" attempts="${3:-120}"
  printf 'Waiting for %s' "$name"
  for ((i=1; i<=attempts; i++)); do
    if "${CURL[@]}" "$url" >/dev/null 2>&1; then
      printf ' ready\n'
      return 0
    fi
    printf '.'
    sleep 5
  done
  printf '\n%s did not become ready: %s\n' "$name" "$url" >&2
  return 1
}

wait_for Forgejo https://forgejo.dev/api/healthz

if ! "${CURL[@]}" -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  https://forgejo.dev/api/v1/user >/dev/null 2>&1; then
  docker compose exec -T -u git forgejo forgejo admin user create \
    --username "$FORGEJO_ADMIN_USER" \
    --password "$FORGEJO_ADMIN_PASSWORD" \
    --email "$FORGEJO_ADMIN_EMAIL" \
    --admin \
    --must-change-password=false
fi

PUBLIC_KEY="$(cat secrets/forgejo-admin-ssh.pub)"
if ! "${CURL[@]}" -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  https://forgejo.dev/api/v1/user/keys | jq -e \
  --arg key "$PUBLIC_KEY" '.[] | select(.key == $key)' >/dev/null; then
  jq -n --arg title "local-admin-key" --arg key "$PUBLIC_KEY" \
    '{title:$title,key:$key}' |
    "${CURL[@]}" -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
      -H 'Content-Type: application/json' \
      -X POST --data-binary @- https://forgejo.dev/api/v1/user/keys >/dev/null
fi

RUNNER_TOKEN="$("${CURL[@]}" \
  -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
  https://forgejo.dev/api/v1/admin/runners/registration-token |
  jq -r '.token')"
[[ -n "$RUNNER_TOKEN" && "$RUNNER_TOKEN" != "null" ]]

if [[ ! -s config/runner/.runner ]]; then
  docker compose --profile runner run --rm --no-deps runner \
    forgejo-runner register \
    --config /config/config.yaml \
    --no-interactive \
    --instance https://forgejo.dev \
    --token "$RUNNER_TOKEN" \
    --name local-docker-runner \
    --labels docker:docker://node:20-bookworm,ubuntu-latest:docker://node:20-bookworm
fi
docker compose --profile runner up -d runner

if ! grep -q '^## Forgejo Actions runner$' secrets/credentials.md; then
  cat >> secrets/credentials.md <<EOF

## Forgejo Actions runner

- Runner registration token: \`${RUNNER_TOKEN}\`
- Runner name: \`local-docker-runner\`
- Labels: \`docker\`, \`ubuntu-latest\`
EOF
fi

printf 'Waiting for SonarQube'
for ((i=1; i<=180; i++)); do
  SONAR_STATUS="$("${CURL[@]}" https://sonar.dev/api/system/status 2>/dev/null |
    jq -r '.status // empty' 2>/dev/null || true)"
  if [[ "$SONAR_STATUS" == "UP" ]]; then
    printf ' ready\n'
    break
  fi
  if ((i == 180)); then
    printf '\nSonarQube did not reach UP status (last status: %s)\n' \
      "${SONAR_STATUS:-unreachable}" >&2
    exit 1
  fi
  printf '.'
  sleep 5
done

if "${CURL[@]}" -u admin:admin https://sonar.dev/api/authentication/validate |
  jq -e '.valid == true' >/dev/null; then
  "${CURL[@]}" -u admin:admin -X POST \
    --data-urlencode login=admin \
    --data-urlencode previousPassword=admin \
    --data-urlencode "password=${SONAR_ADMIN_PASSWORD}" \
    https://sonar.dev/api/users/change_password >/dev/null
fi

if ! grep -q '^## SonarQube analysis token$' secrets/credentials.md; then
  SONAR_TOKEN="$("${CURL[@]}" -u "admin:${SONAR_ADMIN_PASSWORD}" -X POST \
    --data-urlencode name=forgejo-actions \
    https://sonar.dev/api/user_tokens/generate | jq -r '.token')"
  cat >> secrets/credentials.md <<EOF

## SonarQube analysis token

- Token name: \`forgejo-actions\`
- Token: \`${SONAR_TOKEN}\`
- Forgejo secret name: \`SONAR_TOKEN\`
- Forgejo variable name: \`SONAR_HOST_URL\`
- Forgejo variable value: \`https://sonar.dev\`
EOF
fi

wait_for Rancher https://rancher.dev/ping 180
printf 'Waiting for ChartMuseum'
for ((i=1; i<=60; i++)); do
  if "${CURL[@]}" -u "${CHARTMUSEUM_USER}:${CHARTMUSEUM_PASSWORD}" \
    https://helm.dev/health >/dev/null 2>&1; then
    printf ' ready\n'
    break
  fi
  if ((i == 60)); then
    printf '\nChartMuseum did not become ready\n' >&2
    exit 1
  fi
  printf '.'
  sleep 5
done
chmod 600 secrets/credentials.md config/runner/.runner
printf 'Bootstrap complete. Credentials: %s/secrets/credentials.md\n' "$ROOT"
