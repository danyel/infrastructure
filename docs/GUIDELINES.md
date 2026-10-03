# Platform guidelines

These rules keep the platform, the application repositories, and the cluster
descriptions consistent. They apply to this repository and to the repositories
that deploy into the cluster described in
[Kubernetes deployments](KUBERNETES-DEPLOYMENTS.md).

## Documentation

- One `#` heading per file, in sentence case, with no trailing period. Numbers
  only for ordered procedures, as in `## 2. Install the prerequisites`.
- Guide filenames are upper kebab case: `INSTALL.md`, `KUBERNETES-DEPLOYMENTS.md`,
  `GUIDELINES.md`.
- Wrap prose at 80 columns. Fenced blocks always carry a language tag: `bash`,
  `yaml`, `json`, `text`.
- Put a one to three sentence orientation paragraph directly under the heading,
  in the present tense, without first-person pronouns.
- Lists requirements as bullets before a procedure, never as numbered steps.
- Tables use `|---|---|---|` and inline code for every literal.
- Document the reason next to the action. A workaround without its cause gets
  repeated, and then removed by mistake.
- Link between documents with relative paths: `[Helm deployments](HELM-DEPLOYMENTS.md)`.
- Keep the root `README.md` a service table plus a link index. Procedures belong
  in `docs/`.

## Secrets

- `.env.example` documents every variable name and never a real value. Real
  values live in the gitignored `.env` and in the gitignored
  `secrets/credentials.md`.
- Reference a secret by where it is stored, never by writing the value into a
  committed file. This includes values files, workflow files, and documentation.
- Base64 in a Kubernetes `Secret` is encoding, not encryption. Rely on RBAC for
  confidentiality.
- Distribute `certs/local-ca.crt`. Never distribute `certs/local-ca.key`.
- Rotate a secret by passing it at install time with `--set-string` or through a
  Forgejo or GitHub environment secret. A generated secret that is empty on every
  upgrade is stable, not rotated.

## Naming

| Thing | Rule | Example |
|---|---|---|
| Compose project | lower kebab, shared network `local-dev-edge` | `local-dev-platform` |
| DNS name | short label plus platform TLD | `forgejo.dev`, `nmbs.guess.dev` |
| Cluster tenant host | `<tenant>.guess.local` | `nmbs.guess.local` |
| Chart | application name, chart `version` separate from `appVersion` | `go-guess` `0.3.0` / `0.3.0` |
| Release namespace | `<namespace>-<profile>` | `go-insane-production` |
| Resource names | Helm `fullname` plus component | `go-guess-web`, `go-guess-postgresql` |

## Domain separation

Compose serves `*.guess.dev` and `*.auth.dev` from the workstation Traefik with
the platform certificate. Kubernetes serves `*.guess.local` from ingress-nginx
with a cert-manager certificate. The dedicated server serves `goguess.urpi.be`
from host Nginx with Certbot.

Never point a Compose certificate at a cluster host, and never assume a
certificate trusted in one place is trusted in another. When a new environment
appears, add a row to the domain map in
[Kubernetes deployments](KUBERNETES-DEPLOYMENTS.md) and an entry to the service
table in the root `README.md`.

## Helm charts

- Keep the chart in the application repository, under `deploy/helm/<name>`.
- Ship no subchart dependency that is not vendored, so `helm template` works
  offline and `helm lint` reports a real problem instead of a missing
  dependency.
- One deployment per independently scalable component. In Go Guess that is an API
  and a web front end, not one combined container.
- Never hardcode a DNS name in a chart that the image also hardcodes. The Go
  Guess API Service is named `api` because the web image proxies to `api:8080`;
  that coupling is documented in the chart README and must not be broken
  silently.
- Derive every generated name from `domain` and `tenants`, so adding a tenant is
  a values change.
- Give every deployment a readiness probe and a liveness probe on the real
  health endpoint, and pin `strategy` deliberately: `Recreate` when startup runs
  migrations, rolling with `maxUnavailable: 0` for stateless replicas.
- Add ingress annotations for what the application actually does. Streaming
  responses need buffering off and a long read timeout; uploads need a body size
  at least as large as the application's own limit.
- Keep secrets in a chart-managed Secret with `lookup` reuse across upgrades, and
  reference them with `secretKeyRef`, never with literal environment values.
- Set `automountServiceAccountToken: false` on every pod that does not call the
  Kubernetes API.
- Relax a security context only when the image requires it, and document why in
  the chart README. nginx binds port `80`, so the web pod runs with
  `NET_BIND_SERVICE` instead of the non-root default used everywhere else.

## Platform changes

- Make `scripts/install.sh` and `scripts/bootstrap.sh` idempotent. Both run again
  on every new host.
- Keep Compose configuration in `config/` and mutable state in `data/`. Never
  commit either.
- Adding a service means a Compose service, a Traefik router, a certificate SAN
  in `install.sh`, an `/etc/hosts` entry in the documentation, and a row in the
  root `README.md` table.
- A health check belongs in `scripts/verify.sh`. A tenant or application endpoint
  belongs in `scripts/verify-applications.sh`.
- Record what was actually done, including failures and workarounds, in
  `docs/ACTIONS-LOG.md`. That file is why the Rancher entrypoint patch is
  understood rather than merely present.
- Delete dead tooling. A script that no document references and that contradicts
  the current certificate mechanism is a trap for the next reader.

## Clusters

- Rancher is the management interface. Applications deploy into the downstream
  cluster from `~/.kube/config`, never into the k3s cluster inside the
  `rancher.dev` container.
- Keep cluster prerequisites in the application repository as Makefile targets
  (`make cluster-prepare`) so a new cluster is reproducible instead of tribal
  knowledge.
- Verify a prerequisite with `kubectl get storageclass`, `kubectl get
  ingressclass`, and `kubectl get crd` before deploying a chart that depends on
  it.
- Verify a release from inside the cluster with `helm test` and from outside with
  `curl --fail https://<tenant>.<domain>/api/health`.
- Record the expected cluster facts, such as node address and version, in a table
  that is easy to re-verify after a rebuild.