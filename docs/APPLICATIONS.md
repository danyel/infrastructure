# Application HTTPS

The infrastructure Traefik instance terminates browser TLS for Go Loose and Go
Guess. Their containers serve HTTP only on the shared `local-dev-edge` Docker
network. Private keys stay in this repository's ignored `certs/` directory and
are never copied into an application image or committed.

## Names and certificate

Add these names to `/etc/hosts`:

```text
127.0.0.1 auth.dev nmbs.auth.dev ypto.auth.dev
127.0.0.1 nmbs.guess.dev ypto.guess.dev
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