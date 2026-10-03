# Local deployment platform

A Docker Compose development platform with HTTPS routing and separated configuration
and persistent data:

| Service | URL | Purpose |
|---|---|---|
| Forgejo | https://forgejo.dev | Git hosting and Actions |
| SonarQube | https://sonar.dev | Static analysis and quality gates |
| Rancher | https://rancher.dev | Rancher lab server |
| ChartMuseum | https://helm.dev | Private Helm chart repository |
| Go Loose | https://auth.dev | System and tenant authentication |
| Go Guess | https://nmbs.guess.dev | Tenant application, Compose stack |
| Go Tell | https://tell.dev | Content CMS, Kubernetes release |
| Traefik | https://traefik.dev | Proxy dashboard, basic auth |
| Forgejo SSH | `ssh://git@forgejo.dev:2222` | Git over SSH |

Start with [docs/INSTALL.md](docs/INSTALL.md). Generated credentials are written to
the gitignored `secrets/credentials.md`. Forgejo runner keys and CI settings are in
[docs/FORGEJO.md](docs/FORGEJO.md). Migration and recovery are in
[docs/MIGRATION.md](docs/MIGRATION.md). Publishing charts and deploying
applications locally or from Forgejo is covered in
[Helm deployments](docs/HELM-DEPLOYMENTS.md). The downstream Kubernetes cluster,
its prerequisites, the `nmbs.guess.local` and `ypto.guess.local` tenant hosts, and
the `tell.dev` Go Tell release are covered in
[Kubernetes deployments](docs/KUBERNETES-DEPLOYMENTS.md). Writing and maintaining
all of it follows [Platform guidelines](docs/GUIDELINES.md).

Go Loose and Go Guess run from their own Compose projects and join the shared
`local-dev-edge` network. See [Application HTTPS](docs/APPLICATIONS.md). Go Tell
has no Compose project: it runs in the Kubernetes cluster behind ingress-nginx,
while its identity comes from Go Loose in Compose. Until that cluster serves it,
`scripts/go-tell.sh deploy` runs the same image behind the workstation
Traefik as a demo harness, and `scripts/go-tell.sh cluster` verifies the
prerequisites before releasing the chart. `scripts/go-tell.sh urpi` serves the
same names under the real `urpi.be` domain from the workstation, to rehearse a
deployment.

> Rancher's privileged single-container installation is suitable for a local lab,
> not production. It can manage external/imported Kubernetes clusters, but it is
> not itself a local Kubernetes cluster.
