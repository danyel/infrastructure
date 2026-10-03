#!/usr/bin/env bash
# Go Tell on the local platform: one entry point for everything the application
# needs outside its own repository.
#
#   identity   Go Loose tenant, application, client login, demo accounts
#   rotate     new one-time client secret for an existing application
#   deploy     workstation Traefik and container, the demo harness
#   preflight  report the cluster prerequisites, stop when one is missing
#   cluster    verify the prerequisites, then release through the application
#              Makefile into the Kubernetes cluster
#   verify     application endpoints, through scripts/verify-applications.sh
#   login      full browser login through Go Loose with curl, prints the session
#   status     what exists right now
#   demo       open the applications in Firefox, one tab each
#   record     record the screen while you walk through the demo
#   teardown   remove the container, optionally the platform configuration
#   all        identity, deploy, verify, demo
#
# Every path, name, domain, and image is a variable below and can be overridden
# from the environment, for example:
#
#   TELL_HOST=tell.example.com ./scripts/go-tell.sh all
#
# Steps are idempotent: running one twice changes nothing and reports what it
# found. Nothing is written outside the repositories, the containers named here,
# and the local CA. Client secrets only ever reach gitignored files.
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
CA_KEY=${CA_KEY:-$INFRA_DIR/certs/local-ca.key}
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
PLATFORM_LOGIN_HOST=${PLATFORM_LOGIN_HOST:-$AUTH_DOMAIN}
# Guessed host of the application on the identity domain: <tenant>.<AUTH_DOMAIN>
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
# Accounts as email:display name:role, separated by semicolons.
DEMO_USERS=${DEMO_USERS:-"interview@$GO_LOOSE_TENANT.$AUTH_DOMAIN:Tell Interview:admin;reviewer@$GO_LOOSE_TENANT.$AUTH_DOMAIN:Tell Reviewer:admin"}
DEMO_PASSWORD=${DEMO_PASSWORD:-admin123}
# Registered on Go Loose, the callback has to match exactly.
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

# Cluster, the durable target. Prerequisites are verified here and the release
# itself goes through the Makefile target the application repository owns.
KUBE_CONTEXT=${KUBE_CONTEXT:-local}
HELM_PROFILE=${HELM_PROFILE:-production}
HELM_TIMEOUT=${HELM_TIMEOUT:-10m}
KUBE_REQUIRED_CRD=${KUBE_REQUIRED_CRD:-cert-manager.io}
KUBE_REQUIRED_CLASS=${KUBE_REQUIRED_CLASS:-nginx}

# --------------------------------------------------------------------------- #
# Demo
# --------------------------------------------------------------------------- #
BROWSER=${BROWSER:-firefox}
BROWSER_TAB_DELAY=${BROWSER_TAB_DELAY:-12}
DEMO_URLS=${DEMO_URLS:-"https://$TELL_HOST/ https://$TELL_HOST/api/auth/login https://$PLATFORM_LOGIN_HOST/ https://$GO_GUESS_HOST/"}
SCREEN_OUT=${SCREEN_OUT:-$HOME/Videos}
RECORD_MONITOR=${RECORD_MONITOR:-DP-1}
RECORD_RESOLUTION=${RECORD_RESOLUTION:-2560x720}

SCRIPT_NAME=${0##*/}
WORK_LOG=${WORK_LOG:-/tmp/$SCRIPT_NAME.log}

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require() {
  local name
  for name in "$@"; do
    have "$name" || die "$name is required for this step"
  done
}

confirm() {
  [[ ${ASSUME_YES:-false} == true ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ $answer == [yY] ]]
}

first_line() { head -1 | tr -d '\r'; }

json_field() {
  python3 -c "import json,sys; print(json.load(sys.stdin).get('$1') or '')"
}

# --------------------------------------------------------------------------- #
# Identity: Go Loose tenant, application, client login, accounts
# --------------------------------------------------------------------------- #
# A Go Loose system administrator creates tenants, and the account that owns the
# tenant signs in through Google SSO. The bootstrap therefore runs Go Loose's
# own store code: hash formats, roles, and grant tables are exactly the ones
# the server writes. The program is generated into the module and removed again.
run_go_loose_program() {
  local mode=$1
  require go python3
  [[ -f $GO_LOOSE_DIR/go.mod ]] || die "$GO_LOOSE_DIR is not the Go Loose module"

  local program=$GO_LOOSE_DIR/tmp-platform-bootstrap
  mkdir -p "$program"
  cat >"$program/main.go" <<'GO'
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/danyel/go-loose/internal/database"
	"github.com/danyel/go-loose/internal/key"
	"github.com/danyel/go-loose/internal/password"
	"github.com/danyel/go-loose/internal/store"
)

func env(name string) string { return strings.TrimSpace(os.Getenv(name)) }

func main() {
	ctx := context.Background()
	db, err := database.Open(ctx, env("DATABASE_URL"))
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()
	s := store.New(db)

	report := map[string]any{"mode": env("MODE")}
	defer func() { _ = json.NewEncoder(os.Stdout).Encode(report) }()

	var administratorID, administratorEmail string
	err = db.QueryRowContext(ctx, `
		SELECT u.id, u.email FROM users u
		JOIN system_administrators sa ON sa.user_id = u.id
		WHERE lower(u.email) = lower($1)`, env("SYSTEM_ADMIN_EMAIL")).
		Scan(&administratorID, &administratorEmail)
	if err != nil {
		log.Fatalf("system administrator %q not found: %v", env("SYSTEM_ADMIN_EMAIL"), err)
	}
	report["system_administrator"] = administratorEmail

	tenantSlug, appSlug := env("TENANT_SLUG"), env("APP_SLUG")
	var tenantID, applicationID, clientID string
	var clientReady bool
	err = db.QueryRowContext(ctx, `
		SELECT t.id, a.id, a.client_id, a.client_secret_hash IS NOT NULL
		FROM tenants t LEFT JOIN applications a ON a.tenant_id = t.id AND a.slug = $2
		WHERE t.slug = $1`, tenantSlug, appSlug).Scan(&tenantID, &applicationID, &clientID, &clientReady)

	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		log.Fatalf("read tenant: %v", err)
	}

	// The stored secret is hashed, so an existing application keeps its secret
	// unless a rotation is asked for.
	if exists && env("MODE") != "rotate" && clientReady {
		report["status"] = "exists"
		report["tenant_id"], report["application_id"] = tenantID, applicationID
		report["client_id"] = clientID
		report["note"] = "the secret is hashed and cannot be read back, run rotate for a new one"
		return
	}

	if exists {
		report["status"] = "updated"
		report["tenant_id"] = tenantID
	} else {
		tenant, err := s.CreateTenant(ctx, administratorID, tenantSlug, env("TENANT_NAME"))
		if err != nil {
			log.Fatalf("create tenant: %v", err)
		}
		report["status"] = "created"
		report["tenant_id"], report["tenant_slug"] = tenant.ID, tenant.Slug
	}

	if applicationID == "" {
		app, err := s.CreateApplication(ctx, administratorID, store.Application{
			TenantID: tenantID, Slug: appSlug, Name: env("APP_NAME"),
			Description: env("APP_DESCRIPTION"), AllowedHosts: []string{},
		})
		if err != nil {
			log.Fatalf("create application: %v", err)
		}
		applicationID = app.ID
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
	report["application_id"] = configured.ID
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
		fields := strings.Split(strings.TrimSpace(entry), ":")
		if len(fields) != 3 || fields[0] == "" {
			continue
		}
		user, err := s.InviteUser(ctx, administratorID, tenantID, fields[0], fields[1], fields[2], demoHash)
		if err != nil {
			log.Fatalf("invite %s: %v", fields[0], err)
		}
		if err := s.SetUserAccess(ctx, administratorID, tenantID, user.ID, fields[2], []string{applicationID}); err != nil {
			log.Fatalf("grant access to %s: %v", fields[0], err)
		}
		accounts = append(accounts, fmt.Sprintf("%s (%s)", user.Email, fields[2]))
	}
	report["accounts"] = accounts
}
GO

  local report
  if ! (
    export MODE="$mode" DATABASE_URL="$DATABASE_URL" SYSTEM_ADMIN_EMAIL="$SYSTEM_ADMIN_EMAIL"
    export TENANT_SLUG="$GO_LOOSE_TENANT" TENANT_NAME="$GO_LOOSE_TENANT_NAME"
    export APP_SLUG="$GO_LOOSE_APP_SLUG" APP_NAME="$GO_LOOSE_APP_NAME"
    export APP_DESCRIPTION="$GO_LOOSE_APP_DESCRIPTION" REDIRECT_URIS="$REDIRECT_URIS"
    export DEMO_USERS="$DEMO_USERS" DEMO_PASSWORD="$DEMO_PASSWORD"
    cd "$GO_LOOSE_DIR" && go run ./tmp-platform-bootstrap
  ) >"$WORK_LOG.json" 2>"$WORK_LOG"; then
    cat "$WORK_LOG" >&2
    rm -rf "$program"
    die "Go Loose bootstrap failed"
  fi
  rm -rf "$program"
  report=$(cat "$WORK_LOG.json")
  printf '%s\n' "$report"
}

# The section of the credentials file that this script owns.
record_credentials() {
  local client_id=$1 secret=$2 command=$3
  [[ -n $client_id ]] || return 0
  [[ -f $CREDENTIALS_FILE ]] || die "$CREDENTIALS_FILE does not exist, run the platform install first"
  require python3

  BLOCK_HEADER="## $GO_LOOSE_APP_NAME client login" \
  BLOCK_TENANT="$GO_LOOSE_TENANT" \
  BLOCK_IDENTITY_HOST="$IDENTITY_HOST" \
  BLOCK_CLIENT_ID="$client_id" \
  BLOCK_CLIENT_SECRET="$secret" \
  BLOCK_REDIRECT_URIS="$REDIRECT_URIS" \
  BLOCK_ACCOUNTS="$(cut -d: -f1 <<<"$DEMO_USERS" | paste -sd, -)" \
  BLOCK_SCRIPT="scripts/$SCRIPT_NAME" \
  BLOCK_COMMAND="$command" \
  BLOCK_FILE="$CREDENTIALS_FILE" \
    python3 <<'PYTHON'
import os, re

def read(name):
    return os.environ[name]

header = read("BLOCK_HEADER")
rows = [
    ("Login origin", f"https://{read('BLOCK_IDENTITY_HOST')}/"),
    ("Tenant", f"`{read('BLOCK_TENANT')}`"),
    ("Client ID", f"`{read('BLOCK_CLIENT_ID')}`"),
]
if read("BLOCK_CLIENT_SECRET"):
    rows.append(("Client secret", f"`{read('BLOCK_CLIENT_SECRET')}`"))
rows.append(("Redirect URIs", ", ".join(f"`{uri}`" for uri in read("BLOCK_REDIRECT_URIS").split(","))))
accounts = [account for account in read("BLOCK_ACCOUNTS").split(",") if account]
if accounts:
    rows.append(("Accounts", ", ".join(f"`{account}`" for account in accounts)))

block = "\n".join([
    header,
    "",
    "Go Loose stores the secret hashed, so it is readable only here and in the",
    "gitignored `.env` of the application repository. Rotating it replaces both.",
    "",
    "| Property | Value |",
    "|---|---|",
    *[f"| {name} | {value} |" for name, value in rows],
    "",
    f"Generated by `{read('BLOCK_SCRIPT')} {read('BLOCK_COMMAND')}`.",
    "",
])

path = read("BLOCK_FILE")
text = open(path).read()
pattern = re.compile(rf"^{re.escape(header)}$.*?(?=^## |\Z)", flags=re.M | re.S)
if pattern.search(text):
    text = pattern.sub(block, text)
else:
    text = text.rstrip("\n") + "\n\n" + block
open(path, "w").write(text)
PYTHON
  log "recorded credentials in $CREDENTIALS_FILE"
}

# Merges the values the platform needs into the application .env, creating it
# from .env.example when it is missing.
write_app_env() {
  local client_id=$1 secret=$2
  [[ -n $client_id ]] || return 0
  [[ -f $GO_TELL_ENV_EXAMPLE ]] || die "$GO_TELL_ENV_EXAMPLE does not exist"
  require python3

  ENV_TARGET="$GO_TELL_ENV" ENV_SOURCE="$GO_TELL_ENV_EXAMPLE" \
  ENV_ALLOWED_ORIGINS="$CMS_ALLOWED_ORIGINS" \
  ENV_TENANT="$GO_LOOSE_TENANT" ENV_AUTH_DOMAIN="$AUTH_DOMAIN" \
  ENV_APP_DOMAIN="$TELL_HOST" ENV_CLIENT_ID="$client_id" \
  ENV_CLIENT_SECRET="$secret" ENV_CA_FILE="$CA_CERT" \
    python3 <<'PYTHON'
import os, re

values = {
    "CMS_ALLOWED_ORIGINS": os.environ["ENV_ALLOWED_ORIGINS"],
    "GO_LOOSE_TENANT": os.environ["ENV_TENANT"],
    "GO_LOOSE_AUTH_DOMAIN": os.environ["ENV_AUTH_DOMAIN"],
    "GO_LOOSE_APP_DOMAIN": os.environ["ENV_APP_DOMAIN"],
    "GO_LOOSE_CLIENT_ID": os.environ["ENV_CLIENT_ID"],
    "GO_LOOSE_CLIENT_SECRET": os.environ["ENV_CLIENT_SECRET"],
    "GO_LOOSE_CA_FILE": os.environ["ENV_CA_FILE"],
}
target, source = os.environ["ENV_TARGET"], os.environ["ENV_SOURCE"]
if os.path.exists(target):
    text = open(target).read()
else:
    text = open(source).read()
for key, value in values.items():
    if not value:
        continue
    line = f"{key}={value}"
    if re.search(rf"^{key}=.*$", text, flags=re.M):
        text = re.sub(rf"^{key}=.*$", lambda match, line=line: line, text, flags=re.M)
    else:
        text = text.rstrip("\n") + f"\n{line}\n"
open(target, "w").write(text)
os.chmod(target, 0o600)
PYTHON
  log "wrote $GO_TELL_ENV (mode 600, gitignored)"
}

step_identity() {
  log "Go Loose identity for $GO_LOOSE_APP_NAME"
  local report status client_id secret
  report=$(run_go_loose_program bootstrap)
  status=$(printf '%s' "$report" | json_field status)
  client_id=$(printf '%s' "$report" | json_field client_id)
  secret=$(printf '%s' "$report" | json_field client_secret)
  log "tenant $GO_LOOSE_TENANT: $status, client $client_id"

  if [[ -n $secret ]]; then
    record_credentials "$client_id" "$secret" identity
    write_app_env "$client_id" "$secret"
  else
    warn "an existing secret cannot be read back, $CREDENTIALS_FILE and $GO_TELL_ENV left alone"
  fi
}

step_rotate() {
  log "rotating the client secret of $GO_LOOSE_APP_NAME"
  confirm "the new secret invalidates the current one in $GO_TELL_ENV?" || die "aborted"
  local report client_id secret
  report=$(run_go_loose_program rotate)
  client_id=$(printf '%s' "$report" | json_field client_id)
  secret=$(printf '%s' "$report" | json_field client_secret)
  [[ -n $secret ]] || die "no secret returned"
  record_credentials "$client_id" "$secret" rotate
  write_app_env "$client_id" "$secret"
  log "rotated, redeploy $CONTAINER_NAME to pick it up"
}

# --------------------------------------------------------------------------- #
# Platform: hosts file, certificate, router, alias
# --------------------------------------------------------------------------- #
step_dns() {
  log "hostnames in $HOSTS_FILE"
  if grep -q "$TELL_HOST" "$HOSTS_FILE"; then
    log "$TELL_HOST already resolves through $HOSTS_FILE"
    return 0
  fi
  confirm "add $AUTH_DOMAIN $IDENTITY_HOST $TELL_HOST to $HOSTS_FILE?" || die "aborted"
  require sudo
  sudo sed -i "1s/\$/ $AUTH_DOMAIN $IDENTITY_HOST $TELL_HOST/" "$HOSTS_FILE"
  grep -m1 '^127\.0\.0\.1' "$HOSTS_FILE"
}

# scripts/install.sh owns the certificate SAN list, so patch it there and
# rebuild the extension file from the list it holds.
step_cert() {
  log "certificate SAN for $TELL_HOST"
  if openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$TELL_HOST"; then
    log "certificate already covers $TELL_HOST"
    return 0
  fi
  confirm "add $TELL_HOST to $INFRA_INSTALL and reissue $(basename "$SERVER_CERT")?" || die "aborted"
  [[ -f $SERVER_KEY ]] || die "$SERVER_KEY does not exist, run the platform install first"

  CERT_HOST="$TELL_HOST" CERT_INSTALL="$INFRA_INSTALL" python3 <<'PYTHON'
import os, re

host, path = os.environ["CERT_HOST"], os.environ["CERT_INSTALL"]
text = open(path).read()
if f"DNS.{host}" not in text:
    head, _, tail = text.partition("[alt_names]")
    numbers = [int(number) for number in re.findall(r"^DNS\.(\d+)=", tail, flags=re.M)]
    tail = tail.replace(f"DNS.{max(numbers) if numbers else 0}={host}\n", "")
    tail = tail.rstrip("\n") + f"\nDNS.{max(numbers) + 1 if numbers else 1}={host}\n"
    text = f"{head}[alt_names]{tail}"
if f'"DNS:{host}"' not in text:
    text = re.sub(r'(required_sans=\((?:.|\n)*?\n)(\))', rf'\1  "DNS:{host}"\n\2', text, count=1)
open(path, "w").write(text)
PYTHON
  log "added $TELL_HOST to $(basename "$INFRA_INSTALL")"

  CERT_INSTALL="$INFRA_INSTALL" CERT_EXT="$SERVER_EXT" python3 <<'PYTHON'
import os, re

install, target = os.environ["CERT_INSTALL"], os.environ["CERT_EXT"]
body = open(install).read().partition("[alt_names]")[2]
names = re.findall(r"^DNS\.\d+=(.*)$", body, flags=re.M)
open(target, "w").write(
    "authorityKeyIdentifier=keyid,issuer\n"
    "basicConstraints=CA:FALSE\n"
    "keyUsage=digitalSignature,keyEncipherment\n"
    "extendedKeyUsage=serverAuth\n"
    "subjectAltName=@alt_names\n"
    "\n[alt_names]\n"
    + "".join(f"DNS.{index}={name}\n" for index, name in enumerate(names, start=1))
)
PYTHON

  openssl req -new -sha256 -key "$SERVER_KEY" -out "${SERVER_EXT%.ext}.csr" \
    -subj "/CN=$AUTH_DOMAIN/O=Local Development"
  openssl x509 -req -sha256 -days 825 -in "${SERVER_EXT%.ext}.csr" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
    -extfile "$SERVER_EXT" -out "$SERVER_CERT"
  chmod 600 "$SERVER_KEY"
  openssl verify -CAfile "$CA_CERT" "$SERVER_CERT"
  log "reissued $(basename "$SERVER_CERT")"
}

step_traefik() {
  log "Traefik router for https://$TELL_HOST"
  if grep -q "service: $APP_NAME\$" "$INFRA_TRAEFIK"; then
    log "router already present"
    return 0
  fi
  confirm "add the router and service '$APP_NAME' to $INFRA_TRAEFIK?" || die "aborted"
  ROUTER_NAME="$APP_NAME" ROUTER_HOST="$TELL_HOST" ROUTER_FILE="$INFRA_TRAEFIK" \
  SERVICE_URL="http://$CONTAINER_NAME:$CONTAINER_PORT" python3 <<'PYTHON'
import os

name, host = os.environ["ROUTER_NAME"], os.environ["ROUTER_HOST"]
path, url = os.environ["ROUTER_FILE"], os.environ["SERVICE_URL"]
router = (
    f"    {name}:\n"
    f"      rule: Host(`{host}`)\n"
    "      entryPoints: [websecure]\n"
    "      tls: {}\n"
    f"      service: {name}\n"
)
service = (
    f"    {name}:\n"
    "      loadBalancer:\n"
    "        servers:\n"
    f"          - url: {url}\n"
)
text = open(path).read()
text = text.replace("  services:\n", f"{router}  services:\n", 1)
open(path, "w").write(text.rstrip("\n") + "\n" + service)
PYTHON
  log "router added, Traefik reloads the file provider"
}

step_alias() {
  log "network alias $IDENTITY_HOST for Traefik"
  if grep -qx -- "          - $IDENTITY_HOST" "$INFRA_COMPOSE"; then
    log "alias already present"
    return 0
  fi
  confirm "add the alias '$IDENTITY_HOST' to the Traefik service in $INFRA_COMPOSE?" || die "aborted"
  ALIAS_NAME="$IDENTITY_HOST" ALIAS_ANCHOR="$PLATFORM_LOGIN_HOST" \
  ALIAS_FILE="$INFRA_COMPOSE" python3 <<'PYTHON'
import os

alias, anchor, path = os.environ["ALIAS_NAME"], os.environ["ALIAS_ANCHOR"], os.environ["ALIAS_FILE"]
text = open(path).read()
needle = f"          - {anchor}\n"
if needle not in text:
    raise SystemExit(f"could not find {needle.strip()} in {path}")
open(path, "w").write(text.replace(needle, needle + f"          - {alias}\n", 1))
PYTHON
  log "alias added, the Traefik container has to be recreated for it"
}

step_traefik_reload() {
  log "restarting Traefik so it picks up the certificate and the alias"
  require docker
  (cd "$INFRA_DIR" && docker compose up -d traefik >/dev/null && docker compose restart traefik >/dev/null)
  sleep 5
}

step_image() {
  log "building $IMAGE:$IMAGE_TAG"
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
  if [[ -n $IDENTITY_GATEWAY ]]; then
    arguments+=(--add-host "$IDENTITY_HOST:$IDENTITY_GATEWAY")
  fi
  arguments+=("$IMAGE:$IMAGE_TAG")
  docker "${arguments[@]}" >/dev/null
  sleep 3
  docker logs "$CONTAINER_NAME" 2>&1 | tail -3 | sed 's/^/    /'
}

step_deploy() {
  warn "$CONTAINER_NAME on the workstation Traefik is the demo harness, not the release"
  warn "the durable target is Kubernetes: $SCRIPT_NAME deploy cluster"
  step_dns
  step_cert
  step_traefik
  step_alias
  step_traefik_reload
  step_image
  step_container
  log "$TELL_HOST is served by $CONTAINER_NAME ($IMAGE:$IMAGE_TAG)"
}

# Guideline: verify a prerequisite before deploying a chart that depends on it.
step_preflight() {
  log "cluster prerequisites"
  require kubectl
  local context probe node version classes crds storage
  context=$(kubectl config current-context 2>/dev/null || echo none)
  printf '    context        %s\n' "$context"

  # The kubeconfig embeds the Rancher certificate authority. When the cluster
  # presents a different one, every later call fails with an x509 error, so
  # report that first instead of a missing resource further down.
  if ! probe=$(kubectl get nodes --no-headers 2>&1 >/dev/null || true) || [[ -n $probe ]]; then
    printf '%s\n' "$probe" | grep -m2 . >&2
    die "kubectl cannot reach context '$context', refresh its certificate authority first"
  fi
  [[ $context == "$KUBE_CONTEXT" ]] ||
    warn "context is '$context', the release expects '$KUBE_CONTEXT'"

  node=$(kubectl get nodes -o wide --no-headers 2>/dev/null |
    awk 'NR == 1 {print $1, $6, $7}' || true)
  version=$(kubectl version -o json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown)
  printf '    node           %s\n' "${node:-none}"
  printf '    server         %s\n' "$version"

  classes=$(kubectl get ingressclass -o name 2>/dev/null | sed 's|.*/||' | paste -sd, - || true)
  printf '    ingressclass   %s\n' "${classes:-none}"
  storage=$(kubectl get storageclass -o name 2>/dev/null | sed 's|.*/||' | paste -sd, - || true)
  printf '    storageclass   %s\n' "${storage:-none}"
  crds=$(kubectl get crd -o name 2>/dev/null | sed 's|.*/||' | grep -c "$KUBE_REQUIRED_CRD" || true)
  printf '    %-14s %s\n' "$KUBE_REQUIRED_CRD" "$crds custom resource definition(s)"

  local missing=0
  grep -q "$KUBE_REQUIRED_CLASS" <<<"$classes" || { warn "no '$KUBE_REQUIRED_CLASS' ingress class"; missing=1; }
  [[ -n $storage ]] || { warn "no storage class, the release requests persistent storage"; missing=1; }
  (( crds > 0 )) || { warn "no $KUBE_REQUIRED_CRD CRD, cert-manager is not installed"; missing=1; }
  (( missing == 0 )) || die "cluster is not ready, prepare it before deploying"
  log "prerequisites satisfied"
}

# The release is a Helm release driven by the application Makefile, not by this
# script, so the cluster prerequisites stay with the chart that needs them.
step_cluster() {
  step_preflight
  log "helm release $CONTAINER_NAME into namespace go-tell-$HELM_PROFILE"
  make -C "$GO_TELL_DIR" "helm-deploy-$HELM_PROFILE" HELM_TIMEOUT="$HELM_TIMEOUT"
  log "verify from outside the cluster"
  curl --fail --silent --show-error --cacert "$CA_CERT" "https://$TELL_HOST/api/health" >/dev/null ||
    die "https://$TELL_HOST/api/health did not answer, check the ingress and the domain map"
}

# --------------------------------------------------------------------------- #
# Verification
# --------------------------------------------------------------------------- #
# The guideline keeps platform health in scripts/verify.sh and application
# endpoints in scripts/verify-applications.sh, so verify those instead of
# duplicating the checks here.
step_verify() {
  log "application endpoints through scripts/verify-applications.sh"
  (cd "$INFRA_DIR" && ./scripts/verify-applications.sh)
  log "login redirect into Go Loose"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$TELL_HOST/api/auth/login" || echo 000)
  case $code in
    30*) printf '    %-32s %s ok\n' "$TELL_HOST login" "$code" ;;
    *)   die "$TELL_HOST login answered $code, expected a redirect to $IDENTITY_HOST" ;;
  esac
}

# The whole browser flow without a browser: login redirect, client login page,
# password login, callback, session. Cookies are passed to curl explicitly
# because it keeps Secure cookies out of the jar over plain HTTP.
step_login() {
  log "signing in through Go Loose as the first demo account"
  local jar=$WORK_LOG.jar
  rm -f "$jar" "$jar.html"
  local account=${DEMO_USERS%%;*}
  local email=${account%%:*}
  local client_id state login_state authorize csrf return_url code session payload
  client_id=$(grep '^GO_LOOSE_CLIENT_ID=' "$GO_TELL_ENV" | cut -d= -f2-)
  [[ -n $client_id ]] || die "$GO_TELL_ENV has no GO_LOOSE_CLIENT_ID"
  authorize="https://$IDENTITY_HOST/connect/authorize?client_id=$client_id&response_type=code&redirect_uri=$(urlencode "$REDIRECT_URIS")"

  local headers
  headers=$(curl -sk -D - -o /dev/null "https://$TELL_HOST/api/auth/login")
  state=$(sed -n 's/^[Ll]ocation:.*state=\([^&[:space:]]*\).*/\1/p' <<<"$headers" | first_line)
  login_state=$(sed -n 's/.*go_loose_login_state=\([^;[:space:]]*\).*/\1/p' <<<"$headers" | first_line)
  [[ -n $state && -n $login_state ]] || die "the application did not start a login"

  curl -skL -c "$jar" -b "$jar" -o "$jar.html" "$authorize&state=$state"
  grep -q "$GO_LOOSE_APP_NAME" "$jar.html" ||
    warn "the client login page does not mention $GO_LOOSE_APP_NAME"
  csrf=$(grep -o 'name="csrf_token" value="[^"]*"' "$jar.html" | first_line | sed 's/.*value="//;s/"$//')
  return_url=$(grep -o 'name="return" value="[^"]*"' "$jar.html" | first_line |
    sed 's/.*value="//;s/"$//' | python3 -c 'import html,sys; print(html.unescape(sys.stdin.read().strip()))')

  curl -sk -c "$jar" -b "$jar" -o /dev/null -X POST "https://$IDENTITY_HOST/auth/password" \
    --data-urlencode "email=$email" --data-urlencode "password=$DEMO_PASSWORD" \
    --data-urlencode "csrf_token=$csrf" --data-urlencode "return=$return_url"

  code=$(curl -sk -c "$jar" -b "$jar" -o /dev/null -w '%{redirect_url}' "$authorize&state=$state" |
    sed -n 's/.*[?&]code=\([^&[:space:]]*\).*/\1/p')
  [[ -n $code ]] || die "Go Loose issued no authorization code"

  local callback
  callback=$(curl -sk -D - -o /dev/null -b "go_loose_login_state=$login_state" \
    "https://$TELL_HOST$CALLBACK_PATH?code=$code&state=$state")
  session=$(sed -n 's/.*go_loose_user_session=\([^;[:space:]]*\).*/\1/p' <<<"$callback" | first_line)
  [[ -n $session ]] || { sed -n '1,20p' <<<"$callback"; die "no session cookie"; }

  payload=$(curl -sk -b "go_loose_user_session=$session" "https://$TELL_HOST/api/auth/session")
  python3 -m json.tool <<<"$payload"
  grep -q '"authenticated": *true' <<<"$payload" || die "the session is not authenticated"
  log "signed in as $email"
  rm -f "$jar" "$jar.html"
}

step_status() {
  log "status"
  printf '    hosts file   %s\n' "$(grep -c "$TELL_HOST" "$HOSTS_FILE" || true) line(s) with $TELL_HOST"
  printf '    certificate  %s\n' \
    "$(openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName 2>/dev/null | grep -o "DNS:$TELL_HOST" || echo missing)"
  printf '    traefik      %s router(s)\n' "$(grep -c "service: $APP_NAME\$" "$INFRA_TRAEFIK" || true)"
  printf '    compose      %s alias line(s)\n' "$(grep -cx -- "          - $IDENTITY_HOST" "$INFRA_COMPOSE" || true)"
  printf '    container    %s\n' \
    "$(docker ps --filter "name=^/$CONTAINER_NAME\$" --format '{{.Status}} {{.Image}}' || echo absent)"
  printf '    app env      client %s\n' \
    "$(grep '^GO_LOOSE_CLIENT_ID=' "$GO_TELL_ENV" 2>/dev/null | cut -d= -f2- || echo 'not configured')"
  printf '    go loose     %s\n' "$(docker exec "$GO_LOOSE_DB_CONTAINER" psql -U "$GO_LOOSE_DB_USER" \
    -d "$GO_LOOSE_DB_NAME" -tAc \
    "select t.slug || '/' || a.slug || ' ' || a.client_id from applications a join tenants t on t.id = a.tenant_id where t.slug = '$GO_LOOSE_TENANT'" 2>/dev/null || echo unavailable)"
}

# --------------------------------------------------------------------------- #
# Demo and teardown
# --------------------------------------------------------------------------- #
step_demo() {
  log "opening the demo tabs in $BROWSER"
  require "$BROWSER"
  local url
  for url in $DEMO_URLS; do
    log "$BROWSER --new-tab $url"
    "$BROWSER" --new-tab "$url" >/dev/null 2>&1 &
    sleep "$BROWSER_TAB_DELAY"
  done
  printf '\n  One tab per application:\n\n'
  printf '    %-34s %s\n' "https://$TELL_HOST/" "$GO_LOOSE_APP_NAME, the CMS"
  printf '    %-34s %s\n' "https://$TELL_HOST$CALLBACK_PATH" 'the redirect into Go Loose'
  printf '    %-34s %s\n' "https://$PLATFORM_LOGIN_HOST/" 'Go Loose administration'
  printf '    %-34s %s\n' "https://$GO_GUESS_HOST/" 'Go Guess'
  printf '\n  Record it with: %s record, stop with: pkill -INT -f gpu-screen-recorder\n' "$SCRIPT_NAME"
}

step_record() {
  log "recording the screen to $SCREEN_OUT"
  have gpu-screen-recorder || die "gpu-screen-recorder is not installed"
  mkdir -p "$SCREEN_OUT"
  local file="$SCREEN_OUT/$APP_NAME-platform-demo-$(date +%Y-%m-%d_%H-%M-%S).mp4"
  setsid bash -c "gpu-screen-recorder -w '$RECORD_MONITOR' -s '$RECORD_RESOLUTION' \
    -k auto -f 60 -fm cfr -fallback-cpu-encoding yes -o '$file'" \
    >"$WORK_LOG.record" 2>&1 &
  sleep 10
  ls -la "$file"
  log "recording, stop it with: pkill -INT -f gpu-screen-recorder"
}

step_teardown() {
  log "removing $CONTAINER_NAME"
  require docker
  if docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1; then
    log "container removed"
  else
    log "no container to remove"
  fi
  confirm "also remove the router, the alias, and the certificate SAN?" || return 0

  REMOVE_ROUTER="$APP_NAME" REMOVE_ROUTER_FILE="$INFRA_TRAEFIK" python3 <<'PYTHON'
import os, re

name, path = os.environ["REMOVE_ROUTER"], os.environ["REMOVE_ROUTER_FILE"]
text = open(path).read()
text = re.sub(rf"^    {re.escape(name)}:\n(?:      .*\n)+", "", text, flags=re.M)
text = re.sub(rf"^    {re.escape(name)}:\n(?:        .*\n)+", "", text, flags=re.M)
open(path, "w").write(text)
PYTHON
  REMOVE_ALIAS="$IDENTITY_HOST" REMOVE_ALIAS_FILE="$INFRA_COMPOSE" python3 <<'PYTHON'
import os

alias, path = os.environ["REMOVE_ALIAS"], os.environ["REMOVE_ALIAS_FILE"]
text = open(path).read()
open(path, "w").write(text.replace(f"          - {alias}\n", "", 1))
PYTHON
  REMOVE_HOST="$TELL_HOST" REMOVE_INSTALL="$INFRA_INSTALL" python3 <<'PYTHON'
import os, re

host, path = os.environ["REMOVE_HOST"], os.environ["REMOVE_INSTALL"]
text = open(path).read()
text = re.sub(rf"^DNS\.\d+={re.escape(host)}\n", "", text, flags=re.M)
text = text.replace(f'  "DNS:{host}"\n', "")
open(path, "w").write(text)
PYTHON
  sudo sed -i "s/ *$TELL_HOST//" "$HOSTS_FILE"
  log "platform configuration removed, the certificate keeps $TELL_HOST until it is reissued"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

usage() {
  cat <<USAGE
$SCRIPT_NAME: Go Tell on the local platform

  identity   Go Loose tenant, application, client login, demo accounts
  rotate     new one-time client secret for an existing application
  deploy     workstation Traefik and container, the demo harness
  preflight  report the cluster prerequisites and stop when one is missing
  cluster    verify the prerequisites, then release through the application
             Makefile into the Kubernetes cluster
  verify     application endpoints, through scripts/verify-applications.sh
  login      full browser login through Go Loose with curl, prints the session
  status     what exists right now
  demo       open the applications in Firefox, one tab each
  record     record the screen while you walk through the demo
  teardown   remove the container, optionally the platform configuration
  all        identity, deploy, verify, demo

Variables live at the top of the script and can be overridden from the
environment. $SCRIPT_NAME --help shows the commands, read the file for the list.
USAGE
}

# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
[[ -n $IDENTITY_HOST ]] || IDENTITY_HOST="$GO_LOOSE_TENANT.$AUTH_DOMAIN"

command=${1:-all}
case "$command" in
  identity)  step_identity ;;
  rotate)    step_rotate ;;
  deploy)    step_deploy ;;
  cluster)   step_cluster ;;
  preflight) step_preflight ;;
  verify)    step_verify ;;
  login)     step_login ;;
  status)    step_status ;;
  demo)      step_demo ;;
  record)    step_record ;;
  teardown)  step_teardown ;;
  all)       step_identity; step_deploy; step_verify; step_demo ;;
  -h | --help | help) usage ;;
  *)         die "unknown command '$command', try --help" ;;
esac