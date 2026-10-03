# Deploy applications with Kubernetes

This guide covers the single-node k3s cluster reached through `~/.kube/config`:
the prerequisites an application chart expects, the deployment of Go Guess and
Go Tell, the HTTPS hosts they publish, and the checks that prove a release
works.

The cluster in `~/.kube/config` is the downstream cluster managed by Rancher at
`rancher.urpi.be`. It is not the k3s cluster inside the `rancher.dev` container.
Applications belong in the downstream cluster, as stated in
[Helm deployments](HELM-DEPLOYMENTS.md).

## Prerequisites

- A kubeconfig downloaded from Rancher is installed at `~/.kube/config` with the
  `local` context selected.
- `kubectl` and Helm 4.2 or newer are installed on the workstation.
- The cluster node resolves the image registry and can reach its port.
- The application chart lives in the application repository. Go Guess keeps it in
  `~/sources/go/go-guess/deploy/helm/go-guess` and Go Tell in
  `~/sources/go/go-tell/deploy/helm/go-tell`.

Generated credentials stay in the gitignored `secrets/credentials.md` or in the
application repository's deployment workflow. Never copy them into a committed
values file.

## 1. Identify the cluster

```bash
kubectl config get-contexts
kubectl get nodes -o wide
kubectl get storageclass
```

The current lab cluster reports:

| Property | Value |
|---|---|
| Node | `local-node`, roles `control-plane,etcd` |
| Node address | `172.22.0.6` |
| Kubernetes | `v1.36.2+k3s1` |
| Runtime | `containerd` |
| Ingress class | none installed yet |
| Storage class | none installed yet |

`kubectl get storageclass` returning nothing means persistent volumes cannot be
bound, so the production profile stays undeployable until step 2 adds one.

## 2. Install the cluster prerequisites

Run the targets from the application repository. They are idempotent:

```bash
cd ~/sources/go/go-guess
make cluster-prepare
```

`make cluster-prepare` runs the three steps below in order.

### Storage

```bash
kubectl apply -f deploy/rancher/local-path.yaml
kubectl get storageclass
```

The manifest installs the local-path provisioner and a `local-path` storage
class for single-node use. Run it once per cluster, before the first deployment
with `persistence.enabled: true`.

### Ingress

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.hostPort.enabled=true \
  --set controller.kind=DaemonSet \
  --set controller.admissionWebhooks.enabled=false \
  --wait --timeout 10m
kubectl get ingressclass
```

The controller binds `80` and `443` on the node with host ports, because the
applications publish plain HTTP inside the cluster and terminate TLS at the
controller. Admission webhooks are disabled so the chart deploys without a
cert-manager webhook Service being reachable first.

The expected class name is `nginx`, which is the `ingress.className` used by the
Go Guess chart.

### Certificates

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 10m
kubectl get crd | grep cert-manager.io
kubectl -n cert-manager rollout status deployment/cert-manager-webhook
```

The chart issues its own self-signed certificate for every tenant host, so
cert-manager is what turns `ingress.tls.enabled: true` into a working HTTPS
host. An internal CA or an ACME issuer is used instead by setting
`certManager.issuerRef`.

### Registry trust

The private registry serves HTTP, so the node must be told to trust it.
`deploy/rancher/registries.yaml` in the Go Guess repository is the containerd
configuration for that, and it belongs at `/etc/rancher/k3s/registries.yaml` on
the node:

```bash
scp deploy/rancher/registries.yaml \
  <node-user>@172.22.0.6:/tmp/registries.yaml
ssh <node-user>@172.22.0.6 \
  'sudo install -m 0644 /tmp/registries.yaml /etc/rancher/k3s/registries.yaml && sudo systemctl restart k3s'
```

Confirm the node resolves the registry before deploying, because an unresolvable
hostname surfaces as `ErrImagePull` with no useful message:

```bash
getent hosts batty1039.startdedicated.net
```

## 3. Deploy Go Guess

The chart deploys two images, `go-guess-api` and `go-guess-web`, with PostgreSQL
and RabbitMQ alongside them. One web deployment serves every tenant host.

| Profile | Namespace | Images | Storage | Fixtures |
|---|---|---|---|---|
| Development | `go-insane-development` | `latest` | ephemeral | development |
| Production | `go-insane-production` | `0.0.1` | persistent | production |

```bash
cd ~/sources/go/go-guess
make helm-lint
make helm-deploy-development
```

Production takes the released tags and persistent volumes:

```bash
export GO_LOOSE_NMBS_CLIENT_ID=... GO_LOOSE_NMBS_CLIENT_SECRET=...
export GO_LOOSE_YPTO_CLIENT_ID=... GO_LOOSE_YPTO_CLIENT_SECRET=...
make helm-deploy-production
```

Watch the rollout. The API applies migrations and seeds before it becomes ready,
so the first start takes longer than later ones:

```bash
kubectl -n go-insane-production get pods,svc,ingress
kubectl -n go-insane-production rollout status deployment/go-guess-api --timeout=5m
kubectl -n go-insane-production rollout status deployment/go-guess-web --timeout=5m
```

## 4. Tenant hosts on guess.local

The chart serves `nmbs.guess.local` and `ypto.guess.local` from `tenants`, and
derives `GO_LOOSE_APP_DOMAIN` from `domain`. The API resolves the tenant from the
request `Host` header, so adding a tenant needs one new entry in `tenants`, a DNS
record, and no new deployment.

Add the host records on the workstation, pointing at the node address:

```text
/etc/hosts
```

```text
172.22.0.6  nmbs.guess.local
172.22.0.6  ypto.guess.local
```

The certificate is self-signed, so export the CA the chart issued and trust it:

```bash
kubectl -n go-insane-production get secret go-guess-web-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/go-guess-ca.crt

sudo install -m 0644 ~/go-guess-ca.crt /usr/local/share/ca-certificates/go-guess-ca.crt
sudo update-ca-certificates
```

On Firefox, import the same file in Settings, Privacy and Security, Certificates,
View Certificates, Authorities.

Verify each tenant independently:

```bash
curl --fail https://nmbs.guess.local/api/health
curl --fail https://ypto.guess.local/api/health
openssl s_client -connect nmbs.guess.local:443 -servername nmbs.guess.local </dev/null
```

## 5. Deploy Go Tell

Go Tell is the content CMS in `~/sources/go/go-tell`: one image that serves the
API and the React frontend, one host, no tenants. The chart is at
`deploy/helm/go-tell`.

| Profile | Namespace | Image | Storage | Sign-in |
|---|---|---|---|---|
| Development | `go-tell-development` | `latest` | ephemeral | demo sudo terminal |
| Production | `go-tell-production` | `latest` | persistent | Go Loose |

```bash
cd ~/sources/go/go-tell
make helm-lint
make helm-deploy-development
```

Production needs the Go Loose credentials, which the chart refuses to deploy
without:

```bash
export GO_LOOSE_CLIENT_ID=... GO_LOOSE_CLIENT_SECRET=...
make helm-deploy-production \
  --set-string goLoose.ca.existingSecret=local-ca
```

`goLoose.ca.existingSecret` names a Secret holding the platform CA, so the pod
trusts `tell.auth.dev`. Create it once per namespace:

```bash
kubectl -n go-tell-production create secret generic local-ca \
  --from-file=ca.crt=~/sources/go/infrastructure/certs/local-ca.crt
```

The host is `tell.dev`, published by ingress-nginx like the Go Guess tenant
hosts. Add it to the workstation `/etc/hosts` and trust the certificate the
chart issued:

```bash
kubectl -n go-tell-production get secret go-tell-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/go-tell-ca.crt

sudo install -m 0644 ~/go-tell-ca.crt /usr/local/share/ca-certificates/go-tell-ca.crt
sudo update-ca-certificates
```

Verify the release and the login redirect:

```bash
curl --fail https://tell.dev/health
curl -I https://tell.dev/api/auth/login
```

The login request answers `302` towards `https://tell.auth.dev/connect/authorize`.
A `404` means the release has no Go Loose credentials, because the chart fails
before rendering an unconfigured production release.

## 6. Browser sign-in with Go Loose

Browser sign-in needs the application to reach `https://<tenant>.auth.dev` from
inside the cluster, and the identity provider to accept the registered callback:
`https://<tenant>.guess.local/api/auth/callback` for Go Guess, and
`https://tell.dev/api/auth/callback` for Go Tell.

The platform DNS in `/etc/hosts` points `auth.dev` at the workstation Traefik,
which cluster pods cannot reach. Until Go Loose runs inside the cluster or a
reachable address is published, deploy with password login instead:

```bash
helm upgrade --install go-guess deploy/helm/go-guess \
  --namespace go-insane-production -f deploy/helm/go-guess/values-production.yaml \
  --set api.goLoose.enabled=false
```

With Go Loose enabled and credentials supplied, the Go Guess API reads
`GO_LOOSE_<TENANT>_CLIENT_ID` and `GO_LOOSE_<TENANT>_CLIENT_SECRET` from the
release secret. A tenant without credentials keeps password login while the other
tenant signs in through Go Loose. Go Tell reads `GO_LOOSE_CLIENT_ID` and
`GO_LOOSE_CLIENT_SECRET` and logs in through the tenant named by
`goLoose.tenant`, which is `tell` and therefore redirects through
`https://tell.auth.dev`.

Client secrets are shown once when an application is configured in the Go Loose
console. A `404` from `/api/auth/login` means the deployment is missing them:
Go Guess now answers with the exact variables to set, and Go Tell refuses to
deploy without them.

## 7. Upgrade, roll back, and remove

```bash
helm -n go-insane-production history go-guess
helm -n go-insane-production rollback go-guess 1
make helm-down-production
```

Generated secrets are read back on upgrade, so leaving `secrets.jwtSecret` empty
keeps existing sessions valid. Uninstalling deletes the release secrets, so store
the JWT secret and the two connection URLs outside the cluster before removing a
release whose database must survive.

## 8. Troubleshoot

| Symptom | Cause | Fix |
|---|---|---|
| `ErrImagePull`, `no such host` | Node cannot resolve the registry | Section 2, registry trust, then restart `k3s` |
| Pending `PersistentVolumeClaim` | No storage class | Section 2, storage, then reapply the claim |
| `503` on a tenant host | Ingress has no ready endpoint | Check `go-guess-web` pods and the certificate |
| TLS handshake error | Certificate not ready or CA untrusted | `kubectl -n <ns> get certificate`, then re-export the CA |
| `404` on `/api/auth/login` | Go Loose enabled without tenant credentials | Add credentials or set `api.goLoose.enabled=false` |
| `502` on `/api/health` | Web image cannot resolve `api` | Confirm the Service is named `api` in the namespace |
| Login works but links point at one tenant | `api.frontendURL` unset | Set it, or reorder `tenants` |
| Go Tell login answers `404` | Release deployed without Go Loose credentials | Pass `goLoose.clientID` and `goLoose.clientSecret` |
| Go Tell login answers `502` on the callback | Pod cannot reach `tell.auth.dev` | Section 6, publish a reachable identity address |
| Chart template fails on `goLoose.clientSecret` | Go Loose enabled without a secret | Expected guard, pass the credential |

## 9. Platform domain map

| Context | Domain | Mechanism |
|---|---|---|
| Compose platform | `nmbs.guess.dev`, `ypto.guess.dev` | Traefik on the workstation, single certificate |
| Kubernetes cluster | `nmbs.guess.local`, `ypto.guess.local` | ingress-nginx and cert-manager in the cluster |
| Kubernetes cluster | `tell.dev` | ingress-nginx and cert-manager in the cluster, single host |
| Dedicated server | `goguess.urpi.be` | Host Nginx with Certbot, NodePort `31374` |
| Identity | `auth.dev`, `nmbs.auth.dev` | Traefik router to Go Loose |
| Proxy dashboard | `traefik.dev`, `traefik.urpi.be` | Traefik router to `api@internal` behind basic auth |
| Workstation simulation | `*.urpi.be`, `*.auth.urpi.be`, `*.guess.urpi.be` | Traefik on the workstation, `/etc/hosts` override |

Compose and Kubernetes use different parent domains on purpose. The Compose stack
terminates TLS with the platform CA on the workstation, while the cluster
terminates TLS with its own certificate issued by cert-manager. Keep them apart
so a certificate trusted in one place is never assumed in the other.