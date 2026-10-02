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
| Go Guess | https://nmbs.guess.dev | Tenant application |
| Forgejo SSH | `ssh://git@forgejo.dev:2222` | Git over SSH |

Start with [docs/INSTALL.md](docs/INSTALL.md). Generated credentials are written to
the gitignored `secrets/credentials.md`. Forgejo runner keys and CI settings are in
[docs/FORGEJO.md](docs/FORGEJO.md). Migration and recovery are in
[docs/MIGRATION.md](docs/MIGRATION.md). Publishing charts and deploying
applications locally or from Forgejo is covered in
[Helm deployments](docs/HELM-DEPLOYMENTS.md).

Go Loose and Go Guess run from their own Compose projects and join the shared
`local-dev-edge` network. See [Application HTTPS](docs/APPLICATIONS.md).

> Rancher's privileged single-container installation is suitable for a local lab,
> not production. It can manage external/imported Kubernetes clusters, but it is
> not itself a local Kubernetes cluster.
