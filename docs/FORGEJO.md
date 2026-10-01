# Forgejo configuration and keys

All generated values are in `secrets/credentials.md`.

## Required keys and secrets

| Item | Location / Forgejo setting | Purpose |
|---|---|---|
| Admin SSH public key | User Settings > SSH/GPG Keys | Git clone/push over SSH; bootstrap uploads it |
| Admin SSH private key | `secrets/forgejo-admin-ssh` | Local SSH client; never upload or commit |
| Runner registration token | Site Administration > Actions > Runners | Registers the site-wide Docker runner |
| `SONAR_TOKEN` | Repository/organization Settings > Actions > Secrets | Authenticates scans with SonarQube |
| `SONAR_HOST_URL` | Repository/organization Settings > Actions > Variables | Must be `https://sonar.local` |
| Local CA certificate | `certs/local-ca.crt` | Trusts HTTPS from clients and CI jobs |

Configure the generated SSH key locally:

```sshconfig
Host forgejo.local
  HostName forgejo.local
  Port 2222
  User git
  IdentityFile /home/dnoulet/go/infrasctruture/secrets/forgejo-admin-ssh
  IdentitiesOnly yes
```

Test it:

```bash
ssh -T forgejo.local
```

Use an SSH repository remote:

```bash
git remote add origin ssh://git@forgejo.local:2222/forgejo-admin/REPOSITORY.git
```

## SonarQube Actions example

Add `SONAR_TOKEN` as an Actions secret and `SONAR_HOST_URL` as an Actions variable.
The runner mounts the local CA into job containers and configures Git and Node to
trust it.

```yaml
name: quality
on:
  push:
  pull_request:

jobs:
  sonar:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - uses: SonarSource/sonarqube-scan-action@v5
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
          SONAR_HOST_URL: ${{ vars.SONAR_HOST_URL }}
```

If an action uses Java or another runtime-specific trust store, import
`/usr/local/share/ca-certificates/local-dev-ca.crt` in the workflow before calling
that tool.

## Helm repository

Install Helm on Arch if needed:

```bash
sudo pacman -S --needed helm
```

Add the private chart repository:

```bash
helm repo add local https://helm.local \
  --username helm-admin \
  --password 'PASSWORD_FROM_secrets/credentials.md' \
  --ca-file certs/local-ca.crt
helm repo update
```

Upload a packaged chart:

```bash
curl --fail --cacert certs/local-ca.crt \
  -u 'helm-admin:PASSWORD_FROM_secrets/credentials.md' \
  --data-binary '@my-chart-0.1.0.tgz' \
  https://helm.local/api/charts
```

