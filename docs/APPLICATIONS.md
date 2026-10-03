# Application HTTPS

The infrastructure Traefik instance terminates browser TLS for Go Loose and Go
Guess. Their containers serve HTTP only on the shared `local-dev-edge` Docker
network. Private keys stay in this repository's ignored `certs/` directory and
are never copied into an application image or committed.

## Names and certificate

Add these names to `/etc/hosts`:

```text
127.0.0.1 auth.dev nmbs.auth.dev ypto.auth.dev tell.auth.dev
127.0.0.1 nmbs.guess.dev ypto.guess.dev
127.0.0.1 tell.dev
```

Run the installer whenever the certificate is absent or predates application
support:

```bash
cd /home/dnoulet/go/infrasctruture
./scripts/install.sh
sudo trust anchor --store certs/local-ca.crt
docker compose up -d traefik
```

The generated certificate covers `auth.dev`, `*.auth.dev`, and
`*.guess.dev`. The CA private key and server private key remain gitignored.

## Start the applications

```bash
cd /home/dnoulet/go/go-loose
docker compose up -d --build

cd /home/dnoulet/go/go-guess
docker compose up -d --build
```

Open:

- `https://auth.dev` for tenant-independent system-administrator SSO;
- `https://nmbs.auth.dev/login` or `https://ypto.auth.dev/login` for tenant
  username/password administration;
- `https://nmbs.guess.dev` or `https://ypto.guess.dev` for Go Guess.

The Google OAuth client must allow
`https://auth.dev/auth/callback`. Go Guess reaches Go Loose over HTTPS using the
same local CA mounted read-only into its API container.

## Verify routing

```bash
curl --fail --cacert certs/local-ca.crt https://auth.dev/healthz
curl --fail --cacert certs/local-ca.crt https://nmbs.guess.dev/api/health
openssl verify -CAfile certs/local-ca.crt certs/local-dev.crt
```

Or run `./scripts/verify-applications.sh` after both application stacks are up.

## Go Tell

Go Tell is released into the Kubernetes cluster, not into a Compose project, and
takes its identity from Go Loose. Its identity-side setup and the demo harness
are driven by one script:

```bash
./scripts/go-tell.sh identity   # Go Loose tenant, application, client login
./scripts/go-tell.sh preflight  # ingress class, storage class, cert-manager CRD
./scripts/go-tell.sh cluster    # release through the application Makefile
./scripts/go-tell.sh deploy     # the same image behind the workstation Traefik
./scripts/go-tell.sh verify     # endpoints, through verify-applications.sh
./scripts/go-tell.sh teardown   # remove the demo harness
```

`deploy` exists because the cluster does not serve `tell.dev` yet. It adds the
`tell.dev` certificate SAN through `scripts/install.sh`, the Traefik router, the
`tell.auth.dev` network alias that lets Traefik resolve the tenant host, and
then runs the image on `local-dev-edge`. `cluster` is the durable path: it stops
on a missing prerequisite instead of deploying into a cluster that cannot serve
the release.

The client secret is hashed by Go Loose, so it is readable only where it was
generated: the gitignored `secrets/credentials.md` and the gitignored `.env` of
the application repository. `./scripts/go-tell.sh rotate` issues a new one and
rewrites both.

### The Secure Way (Adding the CA Data)
If you prefer to fix the error properly by making your local client trust the certificate, you need to pull Rancher's self-signed Root CA certificate and inject it directly into your kubeconfig.
1. Download the CA certificate from your Rancher server using openssl:bash
```bash
openssl s_client -showcerts -connect rancher.dev:443 </dev/null 2>/dev/null | openssl x509 -outform PEM > current-rancher-ca.crt
``` 
2. Inject the downloaded certificate into your active cluster context:bash 
``` bash
kubectl config set-cluster $(kubectl config current-context) --certificate-authority=current-rancher-ca.crt --embed-certs=true
```
3. Clean up the temporary file:bash
```bash
rm current-rancher-ca.crt
```
4. Check if you can fetch the cluster info
```bash
kubectl cluster-info
```