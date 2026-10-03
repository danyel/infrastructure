#!/usr/bin/env bash
# Go Tell on the local platform: one entry point for everything the application
# needs outside its own repository.
#
#   identity   Go Loose tenant, application, client login, demo accounts
#   rotate     new one-time client secret for an existing application
#   deploy     /etc/hosts, certificate SAN, Traefik router, container
#   verify     health, session, and login redirect over HTTPS
#   login      full browser login through Go Loose with curl, prints the session
#   demo       open the three applications in Firefox, one tab each
#   status     what exists right now
#   teardown   remove the container, optionally the platform configuration
#   all        identity, deploy, verify, demo
#
# Every path, name, domain, and image is a variable below; override any of them
# from the environment, for example:
#
#   TELL_HOST=tell.example.com POD_NAMESPACE=other ./scripts/go-tell.sh deploy
#
# Steps are idempotent: running them twice changes nothing and reports what it
# found. Nothing is written outside the repositories and the containers named
# here, and client secrets only ever reach gitignored files.
set -euo pipefail

# --------------------------------------------------------------------------- #
# Repositories and files
# --------------------------------------------------------------------------- #
INFRA_DIR=${INFRA_DIR:-$HOME/sources/go/infrastructure}
GO_TELL_DIR=${GO_TELL_DIR:-$HOME/sources/go/go-tell}
GO_LOOSE_DIR=${GO_LOOSE_DIR:-$HOME/sources/go/go-loose}

INFRA_COMPOSE=${INFRA_COMPOSE:-$INFRA_DIR/compose.yaml}
INFRA_TRAEFIK=${INFRA_TRAEFIK:-$INFRA_DIR/config/traefik/tls.yaml}
INFRA_INSTALL=${INFRA_INSTALL:-$INFRA_DIR/scripts/install.sh}
CA_CERT=${CA_CERT:-$INFRA_DIR/certs/local-ca.crt}
SERVER_CERT=${SERVER_CERT:-$INFRA_DIR/certs/local-dev.crt}
SERVER_KEY=${SERVER_KEY:-$INFRA_DIR/certs/local-dev.key}
SERVER_EXT=${SERVER_EXT:-$INFRA_DIR/certs/local-dev.ext}
CREDENTIALS_FILE=${CREDENTIALS_FILE:-$INFRA_DIR/secrets/credentials.md}
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}

GO_TELL_ENV=${GO_TELL_ENV:-$GO_TELL_DIR/.env}
GO_TELL_ENV_EXAMPLE=${GO_TELL_ENV_EXAMPLE:-$GO_TELL_DIR/.env.example}
DOCKERFILE=${DOCKERFILE:-$GO_TELL_DIR/Dockerfile}

# --------------------------------------------------------------------------- #
# Names, domains, image
# --------------------------------------------------------------------------- #
APP_NAME=${APP_NAME:-go-tell}
IMAGE=${IMAGE:-$APP_NAME}
IMAGE_TAG=${IMAGE_TAG:-latest}
CONTAINER_NAME=${CONTAINER_NAME:-$APP_NAME}
DOCKER_NETWORK=${DOCKER_NETWORK:-local-dev-edge}
CONTAINER_PORT=${CONTAINER_PORT:-8080}
TELL_HOST=${TELL_HOST:-tell.dev}
AUTH_DOMAIN=${AUTH_DOMAIN:-auth.dev}
# Guessed for the local hostname of the application: <tenant>.<AUTH_DOMAIN>.
IDENTITY_HOST=${IDENTITY_HOST:-}
# Gateway the application calls to reach the identity domain. Empty means
# "resolve it like every other container on the network".
IDENTITY_GATEWAY=${IDENTITY_GATEWAY:-}
CMS_ALLOWED_ORIGINS=${CMS_ALLOWED_ORIGINS:-https://$TELL_HOST}

# Go Loose identity: tenant, application, accounts.
GO_LOOSE_TENANT=${GO_LOOSE_TENANT:-tell}
GO_LOOSE_TENANT_NAME=${GO_LOOSE_TENANT_NAME:-Tell}
GO_LOOSE_APP_SLUG=${GO_LOOSE_APP_SLUG:-$GO_LOOSE_TENANT}
GO_LOOSE_APP_NAME=${GO_LOOSE_APP_NAME:-Tell}
GO_LOOSE_APP_DESCRIPTION=${GO_LOOSE_APP_DESCRIPTION:-Seeded Tell content CMS application}
SYSTEM_ADMIN_EMAIL=${SYSTEM_ADMIN_EMAIL:-daniel.noulet@gmail.com}
# email:display name:role, one per account. Role is admin or viewer.
DEMO_USERS=${DEMO_USERS:-"interview@$GO_LOOSE_TENANT.$AUTH_DOMAIN:Tell Interview:admin reviewer@$GO_LOOSE_TENANT.$AUTH_DOMAIN:Tell Reviewer:admin"}
DEMO_PASSWORD=${DEMO_PASSWORD:-admin123}
# Registered on Go Loose, exact match required.
CALLBACK_PATH=${CALLBACK_PATH:-/api/auth/callback}
REDIRECT_URIS=${REDIRECT_URIS:-https://$TELL_HOST$CALLBACK_PATH}

# Go Loose database, reached through the container it runs in.
GO_LOOSE_DB_CONTAINER=${GO_LOOSE_DB_CONTAINER:-go-loose-postgres-1}
GO_LOOSE_DB_USER=${GO_LOOSE_DB_USER:-goloose}
GO_LOOSE_DB_NAME=${GO_LOOSE_DB_NAME:-goloose}
GO_LOOSE_DB_PASSWORD=${GO_LOOSE_DB_PASSWORD:-goloose}
GO_LOOSE_DB_PORT=${GO_LOOSE_DB_PORT:-5433}
DATABASE_URL=${DATABASE_URL:-postgres://$GO_LOOSE_DB_USER:$GO_LOOSE_DB_PASSWORD@127.0.0.1:$GO_LOOSE_DB_PORT/$GO_LOOSE_DB_NAME?sslmode=disable}

# Go Guess, the neighbouring application the demo visits.
GO_GUESS_HOST=${GO_GUESS_HOST:-nmbs.guess.dev}
PLATFORM_LOGIN_HOST=${PLATFORM_LOGIN_HOST:-auth.dev}

# --------------------------------------------------------------------------- #
# Demo
# --------------------------------------------------------------------------- #
BROWSER=${BROWSER:-firefox}
BROWSER_TAB_DELAY=${BROWSER_TAB_DELAY:-12}
DEMO_URLS=${DEMO_URLS:-"https://$TELL_HOST/ https://$TELL_HOST/api/auth/login https://$PLATFORM_LOGIN_HOST/ https://$GO_GUESS_HOST/"}
SCREEN_OUT=${SCREEN_OUT:-$HOME/Videos}

SCRIPT_NAME=${0##*/}

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require() {
  for command_name in "$@"; do
    have "$command_name" || die "$command_name is required for this step"
  done
}

confirm() {
  [[ ${ASSUME_YES:-false} == true ]] && return 0
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] ]]
}

# Rewrite a file through python: the argument is a script that receives the path
# as argv[1] and must leave the result in place.
patch_file() {
  local file=$1 script=$2
  [[ -f $file ]] || die "$file does not exist"
  python3 - "$file" "$script" <<PYTHON
import sys
path, snippet = sys.argv[1], sys.argv[2]
text = open(path).read()
exec(snippet.replace("@FILE@", repr(path)))
open(path, "w").write(text)
PYTHON
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------- #
# Identity: Go Loose tenant, application, client login, accounts
# --------------------------------------------------------------------------- #
# A Go Loose system administrator creates tenants, and the only account here
# signs in through Google SSO. The bootstrap therefore goes through Go Loose's
# own store code, generated into the module so the hash formats, roles, and
# grant tables are exactly the ones the server writes.
run_go_loose_program() {
  local mode=$1
  require go
  [[ -f $GO_LOOSE_DIR/go.mod ]] || die "$GO_LOOSE_DIR is not the Go Loose module"

  local program=$GO_LOOSE_DIR/tmp-platform-bootstrap
  mkdir -p "$program"
  cat >"$program/main.go" <<'GO'
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/danyel/go-loose/internal/database"
	"github.com/danyel/go-loose/internal/key"
	"github.com/danyel/go-loose/internal/password"
	"github.com/danyel/go-loose/internal/store"
)

func main() {
	ctx := context.Background()
	db, err := database.Open(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	s := store.New(db)

	env := func(name string) string { return strings.TrimSpace(os.Getenv(name)) }
	report := map[string]any{"mode": env("MODE")}
	defer func() {
		_ = json.NewEncoder(os.Stdout).Encode(report)
	}()

	var administratorID, administratorEmail string
	err = db.QueryRowContext(ctx, `
		SELECT u.id, u.email FROM users u
		JOIN system_administrators sa ON sa.user_id = u.id
		WHERE lower(u.email) = lower($1)`, env("SYSTEM_ADMIN_EMAIL")).Scan(&administratorID, &administratorEmail)
	if err != nil {
		log.Fatalf("system administrator %q not found: %v", env("SYSTEM_ADMIN_EMAIL"), err)
	}
	report["system_administrator"] = administratorEmail

	tenantSlug, appSlug := env("TENANT_SLUG"), env("APP_SLUG")
	var tenantID, applicationID, clientID string
	var ready bool
	err = db.QueryRowContext(ctx, `
		SELECT t.id, a.id, a.client_id, a.client_secret_hash IS NOT NULL
		FROM tenants t LEFT JOIN applications a ON a.tenant_id = t.id AND a.slug = $2
		WHERE t.slug = $1`, tenantSlug, appSlug).Scan(&tenantID, &applicationID, &clientID, &ready)
	exists := err == nil
	if err != nil && err.Error() != "sql: no rows in result set" {
		log.Fatalf("read tenant: %v", err)
	}

	if exists && env("MODE") != "rotate" && ready {
		report["status"] = "exists"
		report["tenant_id"], report["application_id"] = tenantID, applicationID
		report["client_id"] = clientID
		report["redirect_uris"] = strings.Split(env("REDIRECT_URIS"), ",")
		report["note"] = "client secret is hashed and cannot be read back; run rotate for a new one"
		return
	}

	if !exists {
		tenant, err := s.CreateTenant(ctx, administratorID, tenantSlug, env("TENANT_NAME"))
		if err != nil {
			log.Fatalf("create tenant: %v", err)
		}
		tenantID = tenant.ID
		report["status"] = "created"
		report["tenant_id"] = tenantID
		report["tenant_slug"] = tenant.Slug
	} else {
		report["status"] = "updated"
		report["tenant_id"] = tenantID
	}

	if applicationID == "" {
		app, err := s.CreateApplication(ctx, administratorID, store.Application{
			TenantID: tenantID, Slug: appSlug, Name: env("APP_NAME"),
			Description: env("APP_DESCRIPTION"), AllowedHosts: []string{},
		})
		if err != nil {
			log.Fatalf("create application: %v", err)
		}
		applicationID, clientID = app.ID, app.ClientID
	}

	secret, _, hash, err := key.GenerateToken("glc_secret_")
	if err != nil {
		log.Fatalf("generate client secret: %v", err)
	}
	configured, err := s.ConfigureClient(ctx, administratorID, applicationID,
		strings.Split(env("REDIRECT_URIS"), ","), hash)
	if err != nil {
		log.Fatalf("configure client login: %v", err)
	}
	report["application_id"] = applicationID
	report["client_id"] = configured.ClientID
	report["client_secret"] = secret
	report["redirect_uris"] = configured.RedirectURIs
	report["client_ready"] = configured.ClientReady

	if err := s.SetUserAccess(ctx, administratorID, tenantID, administratorID, "owner", []string{applicationID}); err != nil {
		log.Fatalf("grant administrator access: %v", err)
	}
	demoHash, err := password.HashDemo(env("DEMO_PASSWORD"))
	if err != nil {
		log.Fatalf("hash demo password: %v", err)
	}
	var accounts []string
	for _, entry := range strings.Split(env("DEMO_USERS"), ";") {
		fields := strings.Split(entry, ":")
		if len(fields) != 3 || fields[0] == "" {
			continue
		}
		user, err := s.InviteUser(ctx, administratorID, tenantID, fields[0], fields[1], fields[2], demoHash)
		if err != nil {
			log.Fatalf("invite %s: %v", fields[0], err)
		}
		if err := s.SetUserAccess(ctx, administratorID, tenantID, user.ID, fields[2], []string{applicationID}); err != nil {
			log.Fatalf("grant access %s: %v", fields[0], err)
		}
		accounts = append(accounts, fmt.Sprintf("%s (%s)", user.Email, fields[2]))
	}
	report["accounts"] = accounts
	fmt.Fprintln(os.Stderr, "identity written")
}
GO

  MODE=$mode \
  DATABASE_URL="$DATABASE_URL" \
  SYSTEM_ADMIN_EMAIL="$SYSTEM_ADMIN_EMAIL" \
  TENANT_SLUG="$GO_LOOSE_TENANT" \
  TENANT_NAME="$GO_LOOSE_TENANT_NAME" \
  APP_SLUG="$GO_LOOSE_APP_SLUG" \
  APP_NAME="$GO_LOOSE_APP_NAME" \
  APP_DESCRIPTION="$GO_LOOSE_APP_DESCRIPTION" \
  REDIRECT_URIS="$REDIRECT_URIS" \
  DEMO_USERS="$DEMO_USERS" \
  DEMO_PASSWORD="$DEMO_PASSWORD" \
    (cd "$GO_LOOSE_DIR" && go run ./tmp-platform-bootstrap 2>/tmp/platform-bootstrap.log) || {
      rm -rf "$program"
      cat /tmp/platform-bootstrap.log >&2
      die "Go Loose bootstrap failed"
    }
  rm -rf "$program"
}

# Read one field from the JSON the program prints on stdout.
json_field() {
  python3 -c "import json,sys; print(json.load(sys.stdin).get('$1') or '')"
}

record_credentials() {
  local client_id=$1 secret=$2 status=$3
  require python3

  [[ -n $client_id ]] || return 0
  local block
  block=$(cat <<MARKDOWN
## $GO_LOOSE_APP_NAME client login

Tenant \`$GO_LOOSE_TENANT\` of the Go Loose identity domain \`$AUTH_DOMAIN\`, shown on
\`.md
MARKDOWN
)
  block=$(cat <<MARKDOWN
## $GO_LOOSE_APP_NAME client login

Go Loose hashes the stored secret, so it is readable only in the line below and in
the gitignored \`.env\` of the application repository. Rotating it replaces both.

| Property | Value |
|---|---|
| Login origin | https://$IDENTITY_HOST/ |
| Tenant | \`$GO_LOOSE_TENANT\` |
| Client ID | \`$client_id\` |
| Client secret | \`$secret\` |
| Redirect URIs | $(printf '`%s`, ' $REDIRECT_URIS | sed 's/, $//') |
| Accounts | $(printf '`%s`, ' $DEMO_USERS | cut -d: -f1 | sed 's/, $//') |

Generated by \`scripts/$SCRIPT_NAME $status\`.
MARKDOWN
)

  [[ -f $CREDENTIALS_FILE ]] || die "$CREDENTIALS_FILE does not exist"
  patch_file "$CREDENTIALS_FILE" "
header = '## $GO_LOOSE_APP_NAME client login'
if header in text:
    start = text.index(header)
    end = text.find('\n## ', start + len(header))
    end = len(text) if end == -1 else end + 1
    text = text[:start] + '''$block''' + text[end:]
else:
    text = text.rstrip('\n') + '\n\n' + '''$block'''
"
  log "recorded credentials in $CREDENTIALS_FILE"
}

write_app_env() {
  local client_id=$1 secret=$2
  [[ -n $client_id && -n $secret ]] || return 0
  [[ -f $GO_TELL_ENV_EXAMPLE ]] || die "$GO_TELL_ENV_EXAMPLE does not exist"

  python3 - "$GO_TELL_ENV_EXAMPLE" "$GO_TELL_ENV" <<PYTHON
import os, re, sys
source, target = sys.argv[1], sys.argv[2]
values = {
    "CMS_ALLOWED_ORIGINS": "$CMS_ALLOWED_ORIGINS",
    "GO_LOOSE_TENANT": "$GO_LOOSE_TENANT",
    "GO_LOOSE_AUTH_DOMAIN": "$AUTH_DOMAIN",
    "GO_LOOSE_APP_DOMAIN": "$TELL_HOST",
    "GO_LOOSE_CLIENT_ID": "$client_id",
    "GO_LOOSE_CLIENT_SECRET": "$secret",
    "GO_LOOSE_CA_FILE": "$CA_CERT",
}
text = open(source).read()
if os.path.exists(target):
    existing = open(target).read()
    for key, value in values.items():
        existing = re.sub(rf"^{key}=.*$", f"{key}={value}", existing, flags=re.M)
    open(target, "w").write(existing)
else:
    for key, value in values.items():
        text = re.sub(rf"^{key}=.*$", f"{key}={value}", text, flags=re.M)
    open(target, "w").write(text)
os.chmod(target, 0o600)
PYTHON
  log "wrote $GO_TELL_ENV (mode 600, gitignored)"
}

step_identity() {
  log "Go Loose identity for $GO_LOOSE_APP_NAME"
  local report
  report=$(run_go_loose_program bootstrap)
  local status client_id secret
  status=$(printf '%s' "$report" | json_field status)
  client_id=$(printf '%s' "$report" | json_field client_id)
  secret=$(printf '%s' "$report" | json_field client_secret)
  log "tenant $GO_LOOSE_TENANT: $status, client $client_id"
  if [[ -n $secret ]]; then
    record_credentials "$client_id" "$secret" identity
    write_app_env "$client_id" "$secret"
  else
    warn "secret not recoverable; $CREDENTIALS_FILE and $GO_TELL_ENV unchanged"
    write_app_env "$client_id" ""
  fi
}

step_rotate() {
  log "rotating the client secret of $GO_LOOSE_APP_NAME"
  confirm "A new secret invalidates the current one in $GO_TELL_ENV?" || die "aborted"
  local report client_id secret
  report=$(run_go_loose_program rotate)
  client_id=$(printf '%s' "$report" | json_field client_id)
  secret=$(printf '%s' "$report" | json_field client_secret)
  [[ -n $secret ]] || die "no secret returned"
  record_credentials "$client_id" "$secret" rotate
  write_app_env "$client_id" "$secret"
  log "rotated; restart or redeploy $CONTAINER_NAME to pick it up"
}

# --------------------------------------------------------------------------- #
# Platform: hosts file, certificate, router, alias
# --------------------------------------------------------------------------- #
step_dns() {
  log "hostnames in $HOSTS_FILE"
  local hosts="$AUTH_DOMAIN $IDENTITY_HOST $TELL_HOST"
  grep -q "$TELL_HOST" "$HOSTS_FILE" || {
    confirm "add $hosts to $HOSTS_FILE?" || die "aborted"
    require sudo
    sudo sed -i "s/^\(127\.0\.0\.1 \)\(.*\)$/\1\2 $hosts/" "$HOSTS_FILE"
  }
  grep -o "127.0.0.1.*" "$HOSTS_FILE" | head -1
}

step_cert() {
  log "certificate SAN for $TELL_HOST"
  if openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$TELL_HOST"; then
    log "certificate already covers $TELL_HOST"
    return 0
  fi
  confirm "add $TELL_HOST to $INFRA_INSTALL and reissue $(basename "$SERVER_CERT")?" || die "aborted"

  # scripts/install.sh owns the SAN list, so patch it first and build the
  # extension file from the list it then generates.
  patch_file "$INFRA_INSTALL" "
block = text.split('[alt_names]', 1)
if len(block) == 2 and 'DNS:$TELL_HOST' not in block[1]:
    numbers = [int(line.split('=')[0][4:]) for line in block[1].splitlines() if line.startswith('DNS.')]
    block[1] = block[1].replace('[alt_names]', '[alt_names]', 1).rstrip('\n')
    block[1] += '\nDNS.%d=$TELL_HOST\n' % (max(numbers) + 1)
    text = block[0] + '[alt_names]' + block[1]
"
  patch_file "$INFRA_INSTALL" "
needle = '  \"DNS:*.guess.dev\"'
if '  \"DNS:$TELL_HOST\"' not in text:
    text = text.replace(needle, needle + '\n  \"DNS:$TELL_HOST\"', 1)
"
  log "added $TELL_HOST to $INFRA_INSTALL"

  python3 - "$INFRA_INSTALL" "$SERVER_EXT" <<'PYTHON'
import re, sys
install, target = sys.argv[1], sys.argv[2]
body = open(install).read().split("[alt_names]", 1)[1]
names = re.findall(r"^DNS\.\d+=(.*)$", body, flags=re.M)
extension = (
    "authorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\n"
    "keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
    "subjectAltName=@alt_names\n\n[alt_names]\n"
    + "".join(f"DNS.{index}={name}\n" for index, name in enumerate(names, start=1))
)
open(target, "w").write(extension)
PYTHON

  [[ -f $SERVER_KEY ]] || die "$SERVER_KEY does not exist"
  openssl req -new -sha256 -key "$SERVER_KEY" -out "${SERVER_EXT%.ext}.csr" \
    -subj "/CN=$AUTH_DOMAIN/O=Local Development"
  openssl x509 -req -sha256 -days 825 -in "${SERVER_EXT%.ext}.csr" \
    -CA "$CA_CERT" -CAkey "${CA_CERT%.crt}.key" -CAcreateserial \
    -extfile "$SERVER_EXT" -out "$SERVER_CERT"
  chmod 600 "$SERVER_KEY"
  openssl verify -CAfile "$CA_CERT" "$SERVER_CERT"
  log "reissued $(basename "$SERVER_CERT") with $(openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName | tail -1)"
  echo "$SERVER_CERT" >/tmp/platform-cert-changed
}

step_traefik() {
  log "Traefik router for https://$TELL_HOST"
  if grep -q "service: $APP_NAME\$" "$INFRA_TRAEFIK"; then
    log "router already present"
    return 0
  fi
  confirm "add router and service '$APP_NAME' to $INFRA_TRAEFIK?" || die "aborted"
  patch_file "$INFRA_TRAEFIK" "
router = '''    $APP_NAME:
      rule: Host(\\\`$TELL_HOST\\\`)
      entryPoints: [websecure]
      tls: {}
      service: $APP_NAME
'''
service = '''    $APP_NAME:
      loadBalancer:
        servers:
          - url: http://$CONTAINER_NAME:$CONTAINER_PORT
'''
if 'service: $APP_NAME' not in text:
    text = text.replace('  services:\n', router + '  services:\n', 1)
    text = text.rstrip('\n') + '\n' + service
"
  log "router added; Traefik reloads the file provider"
}

step_alias() {
  log "network alias $IDENTITY_HOST for Traefik"
  if grep -q -- "- $IDENTITY_HOST\$" "$INFRA_COMPOSE"; then
    log "alias already present"
    return 0
  fi
  confirm "add alias '$IDENTITY_HOST' to the Traefik service in $INFRA_COMPOSE?" || die "aborted"
  patch_file "$INFRA_COMPOSE" "
if '          - $IDENTITY_HOST\n' not in text:
    text = text.replace('          - $PLATFORM_LOGIN_HOST\n',
                        '          - $PLATFORM_LOGIN_HOST\n          - $IDENTITY_HOST\n', 1)
"
  log "alias added; run the traefik step to recreate the container"
}

step_traefik_reload() {
  log "restarting Traefik so it picks up the certificate and alias"
  require docker
  (cd "$INFRA_DIR" && docker compose up -d traefik >/dev/null && docker compose restart traefik >/dev/null)
  sleep 5
}

step_image() {
  log "building $IMAGE:$IMAGE_TAG from $DOCKERFILE"
  require docker
  docker build -t "$IMAGE:$IMAGE_TAG" -f "$DOCKERFILE" "$GO_TELL_DIR"
}

step_container() {
  log "running $CONTAINER_NAME on $DOCKER_NETWORK"
  require docker
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  local -a arguments=(
    run -d --name "$CONTAINER_NAME" --network "$DOCKER_NETWORK" --restart unless-stopped
    --env-file "$GO_TELL_ENV"
    -e "GO_LOOSE_CA_FILE=/certs/$(basename "$CA_CERT")"
    -e "CMS_ALLOWED_ORIGINS=$CMS_ALLOWED_ORIGINS"
    -v "$INFRA_DIR/certs:/certs:ro"
  )
  [[ -n $IDENTITY_GATEWAY ]] && arguments+=(--add-host "$IDENTITY_HOST:$IDENTITY_GATEWAY")
  arguments+=("$IMAGE:$IMAGE_TAG")
  docker "${arguments[@]}"
  sleep 3
  docker logs "$CONTAINER_NAME" 2>&1 | tail -3 | sed 's/^/    /'
}

step_deploy() {
  step_dns
  step_cert
  step_traefik
  step_alias
  step_traefik_reload
  step_image
  step_container
  log "$TELL_HOST is served by $CONTAINER_NAME ($IMAGE:$IMAGE_TAG)"
}

# --------------------------------------------------------------------------- #
# Verification
# --------------------------------------------------------------------------- #
step_verify() {
  log "health and login redirect"
  local failures=0
  check() {
    local name=$1 url=$2 expect=${3:-200}
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo 000)
    if [[ $code == "$expect" || ( $expect == 30x && $code == 30* ) ]]; then
      printf '    %-34s %s ok\n' "$name" "$code"
    else
      printf '    %-34s %s FAIL (expected %s)\n' "$name" "$code" "$expect" >&2
      failures=$((failures + 1))
    fi
  }
  check "$TELL_HOST health"        "https://$TELL_HOST/health"
  check "$TELL_HOST application"   "https://$TELL_HOST/api/content"
  check "$TELL_HOST login"         "https://$TELL_HOST/api/auth/login" 30x
  check "$PLATFORM_LOGIN_HOST"     "https://$PLATFORM_LOGIN_HOST/"
  check "$IDENTITY_HOST login"     "https://$IDENTITY_HOST/login?application=$GO_LOOSE_APP_NAME"
  check "$GO_GUESS_HOST health"    "https://$GO_GUESS_HOST/api/health"
  (( failures == 0 )) || die "$failures check(s) failed"
}

# The full browser flow without a browser: authorize, password login, callback,
# session. Cookies are handed to the shell explicitly because curl keeps
# Secure cookies out of the jar when they arrive over plain HTTP.
step_login() {
  log "signing in through Go Loose as the first demo account"
  local jar; jar=$(mktemp)
  trap 'rm -f "$jar"' RETURN
  local account=${DEMO_USERS%%;*}
  local email=${account%%:*}
  local client_id
  client_id=$(grep '^GO_LOOSE_CLIENT_ID=' "$GO_TELL_ENV" | cut -d= -f2-)
  [[ -n $client_id ]] || die "$GO_TELL_ENV has no GO_LOOSE_CLIENT_ID"
  local authorize="https://$IDENTITY_HOST/connect/authorize?client_id=$client_id&redirect_uri=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$REDIRECT_URIS")&response_type=code"

  local headers state login_state
  headers=$(curl -sk -D - -o /dev/null "https://$TELL_HOST/api/auth/login")
  state=$(sed -n 's/^[Ll]ocation:.*state=\([^&]*\).*/\1/p' <<<"$headers" | head -1)
  login_state=$(sed -n 's/.*go_loose_login_state=\([^;]*\).*/\1/p' <<<"$headers" | head -1)
  [[ -n $state && -n $login_state ]] || die "the application did not start a login"

  curl -skL -c "$jar" -b "$jar" -o "$jar.html" "$authorize&state=$state"
  grep -q "$GO_LOOSE_APP_NAME" "$jar.html" || warn "the client login page does not mention $GO_LOOSE_APP_NAME"
  local csrf return_url
  csrf=$(grep -o 'name="csrf_token" value="[^"]*"' "$jar.html" | head -1 | sed 's/.*value="//;s/"$//')
  return_url=$(grep -o 'name="return" value="[^"]*"' "$jar.html" | head -1 | sed 's/.*value="//;s/"$//' |
    python3 -c 'import html,sys;print(html.unescape(sys.stdin.read().strip()))')

  curl -sk -c "$jar" -b "$jar" -o /dev/null -X POST "https://$IDENTITY_HOST/auth/password" \
    --data-urlencode "email=$email" --data-urlencode "password=$DEMO_PASSWORD" \
    --data-urlencode "csrf_token=$csrf" --data-urlencode "return=$return_url"

  local code
  code=$(curl -sk -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' "$authorize&state=$state" |
    sed -n 's/.*code=\([^&]*\).*/\1/p')
  [[ -n $code ]] || die "Go Loose issued no authorization code"

  local callback
  callback=$(curl -sk -D - -o /dev/null -b "go_loose_login_state=$login_state" \
    "https://$TELL_HOST$CALLBACK_PATH?code=$code&state=$state")
  local session
  session=$(sed -n 's/.*go_loose_user_session=\([^;]*\).*/\1/p' <<<"$callback" | head -1)
  [[ -n $session ]] || { echo "$callback" | head -20; die "no session cookie"; }

  local payload
  payload=$(curl -sk -b "go_loose_user_session=$session" "https://$TELL_HOST/api/auth/session")
  python3 -m json.tool <<<"$payload"
  grep -q '"authenticated": *true' <<<"$payload" || die "the session is not authenticated"
  rm -f "$jar.html"
}

step_status() {
  log "status"
  printf '    hosts      %s\n' "$(grep -c "$TELL_HOST" "$HOSTS_FILE" || true) match(es) for $TELL_HOST"
  printf '    certificate %s\n' "$(openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName 2>/dev/null | grep -o "DNS:$TELL_HOST" || echo 'missing')"
  printf '    router     %s\n' "$(grep -c "service: $APP_NAME\$" "$INFRA_TRAEFIK" || true)"
  printf '    container  %s\n' "$(docker ps --filter "name=^/$CONTAINER_NAME\$" --format '{{.Status}} {{.Image}}' || echo absent)"
  printf '    client id  %s\n' "$(grep '^GO_LOOSE_CLIENT_ID=' "$GO_TELL_ENV" 2>/dev/null | cut -d= -f2- || echo 'not configured')"
  printf '    go-loose   %s\n' "$(docker exec "$GO_LOOSE_DB_CONTAINER" psql -U "$GO_LOOSE_DB_USER" -d "$GO_LOOSE_DB_NAME" -tAc \
    "select t.slug || '/' || a.slug || ' ' || a.client_id from applications a join tenants t on t.id = a.tenant_id where t.slug = '$GO_LOOSE_TENANT'" 2>/dev/null || echo 'unavailable')"
}

# --------------------------------------------------------------------------- #
# Demo and teardown
# --------------------------------------------------------------------------- #
step_demo() {
  log "opening $SCRIPT_NAME demo tabs in $BROWSER"
  require $BROWSER
  for url in $DEMO_URLS; do
    log "$BROWSER --new-tab $url"
    "$BROWSER" --new-tab "$url" >/dev/null 2>&1 &
    sleep "$BROWSER_TAB_DELAY"
  done
  cat <<NOTE

  Firefox now holds one tab per application:

    https://$TELL_HOST/            $GO_LOOSE_APP_NAME, the CMS
    https://$TELL_HOST$CALLBACK_PATH      redirect into Go Loose
    https://$PLATFORM_LOGIN_HOST/         Go Loose administration
    https://$GO_GUESS_HOST/        Go Guess

  To record it: omarchy screenrecord --fullscreen, then
  omarchy screenrecord --stop-recording.
NOTE
}

step_record() {
  log "recording the screen to $SCREEN_OUT"
  have gpu-screen-recorder || die "gpu-screen-recorder is not installed"
  mkdir -p "$SCREEN_OUT"
  local file="$SCREEN_OUT/$APP_NAME-platform-demo-$(date +%Y-%m-%d_%H-%M-%S).mp4"
  setsid bash -c "gpu-screen-recorder -w \"${RECORD_MONITOR:-DP-1}\" -s \"${RECORD_RESOLUTION:-2560x720}\" -k auto -f 60 -fm cfr -fallback-cpu-encoding yes -o '$file' >/tmp/$SCRIPT_NAME.log 2>&1 &"
  sleep 10
  ls -la "$file"
  cat <<NOTE

  Recording. Stop it with:

    pkill -INT -f gpu-screen-recorder

  The file is $file
NOTE
}

step_teardown() {
  log "removing $CONTAINER_NAME"
  require docker
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 && log "container removed" || log "no container"
  if confirm "also remove the Traefik router, the alias, and the certificate SAN?"; then
    patch_file "$INFRA_TRAEFIK" "
import re
text = re.sub(r'    $APP_NAME:\n(?:      .*\n|        .*\n)+', '', text)
"
    patch_file "$INFRA_COMPOSE" "
text = text.replace('          - $IDENTITY_HOST\n', '', 1)
"
    patch_file "$INFRA_INSTALL" "
text = text.replace('DNS.%d=$TELL_HOST\n' % 0, '')
text = text.replace('\n  \"DNS:$TELL_HOST\"', '')
"
    sudo sed -i "s/ *$IDENTITY_HOST//" "$HOSTS_FILE"
    log "platform configuration removed; $TELL_HOST stays in the certificate until it is reissued"
  fi
}

# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
[[ -n $IDENTITY_HOST ]] || IDENTITY_HOST="$GO_LOOSE_TENANT.$AUTH_DOMAIN"

command=${1:-all}
shift || true
(( $# == 0 )) || set -- "$@" || true

case "$command" in
  identity) step_identity ;;
  rotate)   step_rotate ;;
  deploy)   step_deploy ;;
  verify)   step_verify ;;
  login)    step_login ;;
  status)   step_status ;;
  demo)     step_demo ;;
  record)   step_record ;;
  teardown) step_teardown "$@" ;;
  all)      step_identity; step_deploy; step_verify; step_demo ;;
  -h | --help | help) usage ;;
  *)        die "unknown command '$command'; try --help" ;;
esac