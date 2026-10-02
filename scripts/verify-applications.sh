#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

check() {
  local name="$1" host="$2" path="$3"
  curl --fail --silent --show-error --noproxy '*' \
    --cacert certs/local-ca.crt \
    --resolve "${host}:443:127.0.0.1" \
    "https://${host}${path}" >/dev/null
  printf '[OK] %s: https://%s%s\n' "$name" "$host" "$path"
}

openssl verify -CAfile certs/local-ca.crt certs/local-dev.crt
check "Go Loose" "auth.dev" "/healthz"
check "Go Guess NMBS" "nmbs.guess.dev" "/api/health"
check "Go Guess YPTO" "ypto.guess.dev" "/api/health"
