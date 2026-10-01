# Local deployment platform

A Docker Compose development platform with HTTPS routing and separated configuration
and persistent data:

| Service | URL | Purpose |
|---|---|---|
| Forgejo | https://forgejo.local | Git hosting and Actions |
| SonarQube | https://sonar.local | Static analysis and quality gates |
| Rancher | https://rancher.local | Rancher lab server |
| ChartMuseum | https://helm.local | Private Helm chart repository |
| Forgejo SSH | `ssh://git@forgejo.local:2222` | Git over SSH |

Start with [docs/INSTALL.md](docs/INSTALL.md). Generated credentials are written to
the gitignored `secrets/credentials.md`. Forgejo runner keys and CI settings are in
[docs/FORGEJO.md](docs/FORGEJO.md). Migration and recovery are in
[docs/MIGRATION.md](docs/MIGRATION.md).

> Rancher's privileged single-container installation is suitable for a local lab,
> not production. It can manage external/imported Kubernetes clusters, but it is
> not itself a local Kubernetes cluster.

