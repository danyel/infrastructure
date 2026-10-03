# Deploy applications with Helm

This guide publishes an application's Helm chart to the local ChartMuseum,
exposes it in Rancher, and deploys it either from a workstation or from Forgejo
Actions.

Rancher is the management interface, not the deployment cluster. Import or
create a downstream Kubernetes cluster in Rancher first, then download that
cluster's kubeconfig. Do not deploy applications into Rancher's internal k3s
cluster.

For the single-node cluster reached through `~/.kube/config`, including the
storage class, ingress controller, cert-manager, and tenant HTTPS hosts, see
[Kubernetes deployments](KUBERNETES-DEPLOYMENTS.md).

## Prerequisites

- The infrastructure stack and runner are running:

  ```bash
  docker compose --profile runner up -d
  ./scripts/verify.sh
  ```

- The application image is in a registry reachable from the downstream cluster.
- `helm.dev`, `rancher.dev`, and any image-registry hostname resolve from the
  workstation and the downstream cluster where required.
- Helm 4.2 or newer is installed locally.
- A kubeconfig for the downstream cluster has been downloaded from Rancher.

Generated ChartMuseum credentials are in the gitignored
`secrets/credentials.md`. Never copy those values into a committed values file
or workflow.

## 1. Create the application chart

Keep the chart in the application repository. This example uses
`deploy/helm/my-app`:

```bash
mkdir -p deploy/helm
helm create deploy/helm/my-app
```

At minimum, update:

- `Chart.yaml`: set `name`, `description`, chart `version`, and `appVersion`;
- `values.yaml`: set the image repository, service port, resource defaults, and
  application configuration;
- `templates/deployment.yaml`: add health probes, environment variables, secret
  references, and security settings;
- `templates/service.yaml`: expose the port expected by the application;
- `values.schema.json`: validate required values and their types.

`Chart.yaml` uses two independent versions:

```yaml
apiVersion: v2
name: my-app
description: My application
type: application
version: 0.1.0
appVersion: "1.0.0"
```

`version` identifies the chart package. `appVersion` identifies the application
inside it. Publish a new chart version whenever a chart package changes;
ChartMuseum is configured to allow overwrites for local development, but
released versions should remain immutable.

Validate the chart before publishing:

```bash
helm lint deploy/helm/my-app
helm template my-app deploy/helm/my-app \
  --namespace my-app \
  --set image.repository=registry.example/my-app \
  --set-string image.tag=1.0.0 \
  > /tmp/my-app-rendered.yaml
```

Review the rendered manifest, especially image names, namespaces, Secrets,
Ingress hosts, persistent volumes, and cluster-scoped resources.

## 2. Package and publish to ChartMuseum

Read the generated username and password from `secrets/credentials.md`, then
export them only in the current shell:

```bash
export CHARTMUSEUM_USERNAME='helm-admin'
read -rsp 'ChartMuseum password: ' CHARTMUSEUM_PASSWORD
export CHARTMUSEUM_PASSWORD
printf '\n'
```

Package and upload the chart:

```bash
mkdir -p dist
helm dependency update deploy/helm/my-app
helm lint deploy/helm/my-app
helm package deploy/helm/my-app --destination dist

curl --fail-with-body --silent --show-error \
  --cacert certs/local-ca.crt \
  --user "${CHARTMUSEUM_USERNAME}:${CHARTMUSEUM_PASSWORD}" \
  --data-binary @dist/my-app-0.1.0.tgz \
  https://helm.dev/api/charts
```

Add the repository to the local Helm client without putting the password on the
command line:

```bash
printf '%s' "$CHARTMUSEUM_PASSWORD" |
  helm repo add local https://helm.dev \
    --username "$CHARTMUSEUM_USERNAME" \
    --password-stdin \
    --ca-file ~/sources/go/infrastructure/certs/local-ca.crt
helm repo update local
helm search repo local/go-guess --versions
```

Helm stores repository credentials in its user configuration. Remove the entry
when it is no longer needed:

```bash
helm repo remove local
unset CHARTMUSEUM_USERNAME CHARTMUSEUM_PASSWORD
```

## 3. Add ChartMuseum to Rancher

Repositories belong to a downstream cluster in Rancher:

1. Open `https://rancher.dev` and select **Cluster Management**.
2. Find the downstream cluster and select **Explore**.
3. Open **Apps > Repositories**, then select **Create**.
4. Choose an HTTP(S) Helm repository and enter:
   - **Name:** `local`
   - **Index URL:** `https://helm.dev`
   - **Authentication:** the ChartMuseum username and password from
     `secrets/credentials.md`
   - **CA certificate:** the contents of `certs/local-ca.crt`
5. Create the repository and wait for it to become active.
6. Open **Apps > Charts** and confirm that `my-app` appears.

The CA certificate is required because ChartMuseum is served with this
infrastructure's private certificate authority. Do not disable TLS verification.
If Rancher cannot refresh the repository, first verify that the Rancher container
can resolve the Traefik network alias:

```bash
docker compose exec rancher getent hosts helm.dev
```

Rancher's **Apps > Charts** screen can install the chart interactively. Select a
namespace, review the values, and install it. Releases installed by Rancher are
ordinary Helm releases and can also be inspected with the Helm CLI.

## 4. Deploy locally

In Rancher, open the downstream cluster and download its kubeconfig. Store it
outside the repository with owner-only permissions:

```bash
install -m 600 ~/Downloads/my-cluster.yaml ~/.kube/my-cluster.yaml
export KUBECONFIG="$HOME/.kube/my-cluster.yaml"
```

Confirm that the context targets the intended downstream cluster:

```bash
kubectl config current-context
kubectl cluster-info
```

Deploy a specific chart version. Use a separate values file per environment and
do not commit plaintext secrets:

```bash
helm upgrade --install my-app local/my-app \
  --version 0.1.0 \
  --namespace my-app \
  --create-namespace \
  --values deploy/helm/values.local.yaml \
  --set image.repository=registry.example/my-app \
  --set-string image.tag=1.0.0 \
  --wait \
  --wait-for-jobs \
  --rollback-on-failure \
  --timeout 10m
```

For a private image registry, create a Kubernetes image pull Secret in the
target namespace and reference it through the chart's `imagePullSecrets` value.
Do not put registry passwords in `values.local.yaml`.

Verify the release:

```bash
helm status my-app --namespace my-app
helm test my-app --namespace my-app
kubectl get deploy,pod,service,ingress --namespace my-app
```

## 5. Publish and deploy from Forgejo

Add these repository or organization Actions settings in Forgejo:

| Type | Name | Value |
|---|---|---|
| Secret | `CHARTMUSEUM_USERNAME` | ChartMuseum username |
| Secret | `CHARTMUSEUM_PASSWORD` | ChartMuseum password |
| Secret | `KUBECONFIG_B64` | Base64-encoded downstream-cluster kubeconfig |
| Variable | `HELM_RELEASE` | `my-app` |
| Variable | `HELM_NAMESPACE` | `my-app` |
| Variable | `IMAGE_REPOSITORY` | Registry path for the application image |

Encode the kubeconfig as one line before saving it as `KUBECONFIG_B64`:

```bash
base64 -w 0 "$HOME/.kube/my-cluster.yaml"
```

Base64 is not encryption; keep the result in an Actions secret. Prefer a
dedicated Kubernetes service account with permissions restricted to the target
namespace instead of an administrator kubeconfig.

Create `.forgejo/workflows/deploy.yaml` in the application repository:

```yaml
name: publish-and-deploy

on:
  push:
    tags:
      - "v*"

jobs:
  deploy:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4

      - name: Install Helm
        shell: bash
        run: |
          set -Eeuo pipefail
          HELM_VERSION=v4.2.2
          ARCHIVE="helm-${HELM_VERSION}-linux-amd64.tar.gz"
          curl --fail --silent --show-error --location \
            --output "$ARCHIVE" "https://get.helm.sh/$ARCHIVE"
          curl --fail --silent --show-error --location \
            --output "$ARCHIVE.sha256sum" \
            "https://get.helm.sh/$ARCHIVE.sha256sum"
          sha256sum --check "$ARCHIVE.sha256sum"
          tar --extract --gzip --file "$ARCHIVE"
          install linux-amd64/helm /usr/local/bin/helm

      - name: Package, publish, and deploy
        shell: bash
        env:
          CHARTMUSEUM_USERNAME: ${{ secrets.CHARTMUSEUM_USERNAME }}
          CHARTMUSEUM_PASSWORD: ${{ secrets.CHARTMUSEUM_PASSWORD }}
          KUBECONFIG_B64: ${{ secrets.KUBECONFIG_B64 }}
          HELM_RELEASE: ${{ vars.HELM_RELEASE }}
          HELM_NAMESPACE: ${{ vars.HELM_NAMESPACE }}
          IMAGE_REPOSITORY: ${{ vars.IMAGE_REPOSITORY }}
        run: |
          set -Eeuo pipefail
          VERSION="${GITHUB_REF_NAME#v}"
          CHART_DIR=deploy/helm/my-app
          CHART_NAME="$(awk '$1 == "name:" { print $2; exit }' "$CHART_DIR/Chart.yaml")"
          CA_FILE=/usr/local/share/ca-certificates/local-dev-ca.crt
          KUBECONFIG="${RUNNER_TEMP:-/tmp}/kubeconfig"
          export KUBECONFIG

          printf '%s' "$KUBECONFIG_B64" | base64 --decode > "$KUBECONFIG"
          chmod 600 "$KUBECONFIG"

          helm dependency update "$CHART_DIR"
          helm lint "$CHART_DIR"
          helm package "$CHART_DIR" \
            --version "$VERSION" \
            --app-version "$VERSION" \
            --destination dist

          curl --fail-with-body --silent --show-error \
            --cacert "$CA_FILE" \
            --user "${CHARTMUSEUM_USERNAME}:${CHARTMUSEUM_PASSWORD}" \
            --data-binary "@dist/${CHART_NAME}-${VERSION}.tgz" \
            https://helm.dev/api/charts

          printf '%s' "$CHARTMUSEUM_PASSWORD" |
            helm repo add local https://helm.dev \
              --username "$CHARTMUSEUM_USERNAME" \
              --password-stdin \
              --ca-file "$CA_FILE"
          helm repo update local

          helm upgrade --install "$HELM_RELEASE" "local/$CHART_NAME" \
            --version "$VERSION" \
            --namespace "$HELM_NAMESPACE" \
            --create-namespace \
            --values deploy/helm/values.production.yaml \
            --set image.repository="$IMAGE_REPOSITORY" \
            --set-string image.tag="$VERSION" \
            --wait \
            --wait-for-jobs \
            --rollback-on-failure \
            --timeout 10m
```

The workflow assumes tags such as `v1.2.3`; that version becomes both the chart
version and application image tag. Build and push the corresponding application
image before the deployment job runs. If image publishing is in the same
workflow, make this job depend on it with `needs`.

## 6. Upgrade, roll back, and uninstall

List release history:

```bash
helm history my-app --namespace my-app
```

Upgrade by publishing a new chart version and running `helm upgrade --install`
with that exact version. Roll back to a known revision:

```bash
helm rollback my-app REVISION \
  --namespace my-app \
  --wait \
  --timeout 10m
```

Uninstall the release:

```bash
helm uninstall my-app --namespace my-app --wait
```

Uninstalling does not necessarily delete persistent volumes or external
resources. Inspect the chart's retention policies and the namespace before
removing data manually.
