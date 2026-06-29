# Grid4Earth DESP — JupyterHub + Argo Workflows on OVHcloud

OpenTofu deployment of JupyterHub, Dask Gateway and Argo Workflows on the GRID4EARTH OVHcloud project (GRA9).

## Stack

- JupyterHub 4.3.2 (Zero-to-JupyterHub)
- Dask Gateway 2025.4.0
- Argo Workflows 0.46.2
- NGINX Ingress Controller
- cert-manager v1.14.4 + Let's Encrypt
- nginx-s3-gateway (S3 public proxy)
- OVHcloud MKS (Managed Kubernetes Service, GRA9)
- State stored in OVH S3 bucket (`g4e-desp-state`)

## Prerequisites

- OpenTofu >= 1.6
- `kubectl`
- `helm`
- OVH API credentials (`OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`)
- S3 credentials for the GRID4EARTH project (see Step 1)

---

## Step 1 — Retrieve S3 credentials

S3 credentials are managed from the OVHcloud Manager:

1. Log in to https://manager.eu.ovhcloud.com with the GRID4EARTH account
2. Navigate to **Public Cloud → GRID4EARTH → Object Storage → Users**
3. Select an existing S3 user (or create one) and click **View credentials**

The `access_key` and `secret_key` values are needed for `backend.tfvars` and `secrets/terraform.tfvars`.

---

## Step 2 — Configure OVH API credentials

Create an API token at https://www.ovh.com/auth/api/createToken with GET/POST/PUT/DELETE rights on `/*`.

Save the credentials in `secrets/ovh-creds.sh` (encrypted with git-crypt):

```bash
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="..."
export OVH_APPLICATION_SECRET="..."
export OVH_CONSUMER_KEY="..."
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="gra"
export AWS_REGION="gra"
```

Source before any Tofu operation:

```bash
git-crypt unlock ~/git-crypt-g4e.key
source secrets/ovh-creds.sh
```

The git-crypt key is stored at `~/git-crypt-g4e.key`. Keep it in a safe place (password manager, USB key) — without it the secrets file cannot be decrypted.

---

## Step 3 — Create the S3 state bucket

The state bucket must exist before running `tofu init`:

```bash
AWS_ACCESS_KEY_ID="<s3_access_key>" \
AWS_SECRET_ACCESS_KEY="<s3_secret_key>" \
aws s3 mb s3://g4e-desp-state \
  --endpoint-url https://s3.gra.io.cloud.ovh.net \
  --region gra
```

---

## Step 4 — Configure secrets

Create `backend.tfvars` (not committed):

```hcl
access_key = "<s3_access_key>"
secret_key = "<s3_secret_key>"
```

Create `secrets/terraform.tfvars` (not committed):

```hcl
harbor_robot_username = "<robot_username>"
harbor_robot_token    = "<robot_token>"
s3_access_key         = "<s3_access_key>"
s3_secret_key         = "<s3_secret_key>"
s3proxy_access_key    = "<s3proxy_access_key>"
s3proxy_secret_key    = "<s3proxy_secret_key>"
```

The `s3proxy_access_key` / `s3proxy_secret_key` are the credentials for the `grid4earth` bucket
served publicly via `https://data.grid4earth.eu`.

---

## Step 5 — Initialize Tofu

```bash
cd tf
git-crypt unlock ~/git-crypt-g4e.key
source secrets/ovh-creds.sh

tofu init -reconfigure
```

If prompted for backend credentials, make sure `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
are set (they come from `secrets/ovh-creds.sh`).

---

## Step 6 — Deploy

The deployment must be done in four passes due to a Tofu limitation: the `kubernetes_manifest`
resource (cert-manager ClusterIssuer) cannot be planned before the cluster exists.

**Pass 1 — Create the cluster and node pool:**

```bash
tofu apply \
  -var-file=secrets/terraform.tfvars \
  -target=ovh_cloud_project_kube.cluster \
  -target=ovh_cloud_project_kube_nodepool.cpu_pool
```

This takes approximately 7–10 minutes.

**Pass 2 — Deploy all Helm releases and Kubernetes resources:**

```bash
tofu apply \
  -var-file=secrets/terraform.tfvars \
  -target=helm_release.cert_manager \
  -target=helm_release.ingress_nginx \
  -target=kubernetes_namespace.jupyterhub \
  -target=kubernetes_namespace.argo \
  -target=kubernetes_namespace.s3proxy \
  -target=kubernetes_secret.harbor_pull_secret \
  -target=kubernetes_secret.harbor_pull_secret_argo \
  -target=kubernetes_secret.argo_s3_credentials \
  -target=kubernetes_secret.s3_credentials_jupyterhub \
  -target=kubernetes_secret.s3proxy_credentials \
  -target=helm_release.jupyterhub \
  -target=helm_release.dask_gateway \
  -target=helm_release.argo_workflows \
  -target=kubernetes_network_policy.singleuser_dask \
  -target=kubernetes_network_policy.singleuser_to_argo
```

This takes approximately 10–15 minutes (first run pulls the singleuser image, ~5.8 GiB).

**Pass 3 — Deploy the cert-manager ClusterIssuer:**

```bash
tofu apply \
  -var-file=secrets/terraform.tfvars \
  -target=kubernetes_manifest.cluster_issuer
```

**Pass 4 — Deploy the STAC stack and S3 proxy:**

```bash
kubectl apply -f grid4earth-stac-stack.yaml
kubectl apply -f grid4earth-s3proxy.yaml
```

Monitor TLS certificate issuance:

```bash
kubectl get certificate -A --watch
```

---

## Step 7 — Configure DNS

The domain `grid4earth.eu` is registered under Tina's OVHcloud account, which is separate from
the GRID4EARTH infrastructure account (Fred's account, `pf81809-ovh`). The DNS zone is managed
by OVH nameservers (`ns109.ovh.net` / `dns109.ovh.net`).

A single wildcard A record covers all subdomains (already configured — no action needed):

```
*.grid4earth.eu  →  <LoadBalancer external IP>  TTL 300
```

After Pass 2, retrieve the LoadBalancer external IP:

```bash
kubectl get svc -n jupyterhub ingress-nginx-controller
```

TLS certificates are issued automatically by cert-manager (Let's Encrypt) within a few minutes
of the DNS record propagating.

---

## Step 8 — Deploy the STAC stack

After the cluster and DNS are in place, deploy the STAC stack:

```bash
kubectl apply -f grid4earth-stac-stack.yaml
```

---

## Step 9 — Retrieve kubeconfig

The kubeconfig is available from the OVHcloud Manager:

**Public Cloud → GRID4EARTH → Managed Kubernetes Service → g4e-desp-cluster → kubeconfig → Download**

```bash
export KUBECONFIG=~/.kube/config-desp
kubectl get pods -n jupyterhub
kubectl get pods -n argo
kubectl get pods -n s3proxy
```

---

## Architecture

```
OVHcloud project: GRID4EARTH (24b43ff90f3044c8923063b0fbb53f26)
│
├── MKS Cluster (GRA9) — g4e-desp-cluster
│   └── Node pool CPU: b3-64, autoscale 1–5
│       label: hub.jupyter.org/node-purpose=user, node-role=cpu
│
├── Namespace: jupyterhub
│   ├── JupyterHub 4.3.2     — https://jupyterhub.grid4earth.eu
│   │   ├── Profile: Standard CPU (✅ operational) — up to 32 GB RAM
│   │   ├── Profile: Sentinel-2 MSI (✅ operational) — up to 64 GB RAM
│   │   │   allowed users: pablo-richard, capetienne, cgueguen, j34ni, annefou
│   │   ├── Profile: Sentinel-3 SYNERGY / s3syn (✅ operational) — up to 32 GB RAM
│   │   │   allowed users: j34ni, annefou, tik65536, tinaok
│   │   │   image: y74y55mn.gra7.container-registry.ovh.net/healpix-private/s3syn:latest
│   │   │   base: quay.io/jupyter/minimal-notebook:2024-05-27
│   │   │   s3syn version: 1.0.6
│   │   └── Profile: GPU (⚠️  disabled — see GPU section below)
│   ├── Dask Gateway 2025.4.0
│   ├── NGINX Ingress (class: nginx-jupyterhub)
│   └── cert-manager — Let's Encrypt TLS
│
├── Namespace: argo
│   └── Argo Workflows 0.46.2 — https://argo.grid4earth.eu
│       └── Artifacts → S3 bucket (TBD — see Argo artifacts section)
│
├── Namespace: stac
│   ├── stac-fastapi-geoparquet — https://stac-api.grid4earth.eu
│   └── stac-browser            — https://stac-browser.grid4earth.eu
│       (custom build: ghcr.io/j34ni/stac-browser:gridlook)
│
├── Namespace: gridlook
│   └── gridlook                — https://gridlook.grid4earth.eu
│
├── Namespace: s3proxy
│   └── nginx-s3-gateway        — https://data.grid4earth.eu
│       Proxies s3://grid4earth/public/ without exposing credentials.
│       Managed by: grid4earth-s3proxy.yaml (Deployment/Service/Ingress)
│                   main.tf (Namespace + Secret)
│       Usage: https://data.grid4earth.eu/<path>
│              maps to s3://grid4earth/public/<path>
│
└── S3 buckets (GRA)
    ├── g4e-desp-state          (Tofu state)
    ├── grid4earth              (public data via data.grid4earth.eu)
    └── <TBD>                   (Argo Workflows artifacts)
```

---

## JupyterHub profiles

### s3syn profile

The s3syn profile provides the Sentinel-3 SYNERGY Level-2 processor environment.

**Image build** — built from source on a VM from the
[synergy-processor](https://gitlab.eopf.copernicus.eu/S3/SYN/synergy-processor) repository,
then pushed to Harbor:

```bash
# Clone
git clone https://<user>:<token>@gitlab.eopf.copernicus.eu/S3/SYN/synergy-processor.git

# Build (token needed for private EOPF package registries)
docker build \
  --build-arg GITLAB_TOKEN="<token>" \
  -t s3syn-jupyter:latest \
  -f Dockerfile_s3syn \
  .

# Push to Harbor
docker tag s3syn-jupyter:latest \
  y74y55mn.gra7.container-registry.ovh.net/healpix-private/s3syn:latest
docker push y74y55mn.gra7.container-registry.ovh.net/healpix-private/s3syn:latest
```

**Private package registries** used during build (full list from the
[s3syn installation manual](https://s3.pages.eopf.copernicus.eu/SYN/synergy-processor/main/sim.html)):

| Project ID | Package |
|---|---|
| 519 | s3syn |
| 118 | s3olci |
| 92 | asgard-legacy |
| 171 | asgard-legacy-drivers |
| 102, 113, 14, 78, 94, 52, 67 | other EOPF dependencies |

**Quick install check** in a notebook:

```python
import s3syn
print(s3syn.__version__)  # should print 1.0.6

from s3syn.sy1.computing.sy1_processor import Sy1Processor
from s3syn.sy2aod.computing.aod_processing_unit import AODProcessing
print("OK:", Sy1Processor, AODProcessing)
```

**Allowed users:** `j34ni`, `annefou`, `tik65536`, `tinaok`

---

## S3 public proxy

The S3 proxy at `https://data.grid4earth.eu` provides public read-only access to the
`grid4earth` S3 bucket without exposing credentials. It is backed by
[nginxinc/nginx-s3-gateway](https://github.com/nginxinc/nginx-s3-gateway).

Files in `s3://grid4earth/public/` are accessible at:

```
https://data.grid4earth.eu/<path>
```

Example:

```bash
curl https://data.grid4earth.eu/tmp/test.zarr/zarr.json
```

CORS is fully open (`Access-Control-Allow-Origin: *`) with support for `Range` requests,
which is required for Zarr and cloud-optimised formats.

CORS headers are injected via an nginx `configuration-snippet` on the Ingress (not via the
`enable-cors` annotations, which only apply to OPTIONS preflight responses). This requires
two settings in the ingress-nginx Helm release, already configured in `main.tf`:

```hcl
controller.allowSnippetAnnotations    = true
controller.config.annotations-risk-level = Critical
```

> **Note on ingress-nginx >= 1.12:** since chart version 4.12, `allowSnippetAnnotations: true`
> alone is not sufficient — `annotations-risk-level: Critical` is also required, otherwise the
> admission webhook rejects `configuration-snippet` annotations.

---

## Harbor — Private Registry

The JupyterHub singleuser image is hosted on the OVHcloud Harbor registry:

```
y74y55mn.gra7.container-registry.ovh.net/healpix-private/g4e-jupyterhub-private:latest
```

The robot account used for pulling is a project-level robot in the `healpix-private` project.
Credentials are stored in `secrets/terraform.tfvars` and injected automatically as a Kubernetes
`imagePullSecret` (`harbor-pull-secret`) in both the `jupyterhub` and `argo` namespaces.

When using `docker login` from the CLI, use single quotes around the username to prevent shell
expansion of the `$` character:

```bash
echo 'TOKEN' | docker login y74y55mn.gra7.container-registry.ovh.net \
  -u 'robot$healpix-private+<robot-name>' \
  --password-stdin
```

---

## GPU support

GRA9 currently offers **Quadro RTX 5000 (16 GB VRAM)** nodes. The GPU profile in JupyterHub
is present in `values.yaml` but marked as unavailable pending a decision on whether this GPU
meets project requirements for HEALPix regridding workloads.

When GPU nodes are provisioned:

1. Verify nodes appear in the cluster:
   ```bash
   kubectl get nodes -l node-role=gpu
   ```

2. Add the GPU node pool in `main.tf` with the correct `flavor_name`.

3. Deploy the NVIDIA device plugin:
   ```bash
   helm upgrade --install nvidia-device-plugin \
     https://nvidia.github.io/k8s-device-plugin/stable/nvidia-device-plugin.tgz \
     -n nvidia-device-plugin --create-namespace \
     -f nvidia-plugin-values.yaml
   ```

4. Update the GPU profile `display_name` in `values.yaml` to remove the "not available yet" warning.

---

## Argo Workflows artifacts

Argo is configured to store artifacts and logs in an S3 bucket. The bucket name is defined in
`argo-values.yaml`. Once the bucket name is confirmed, create it:

```bash
AWS_ACCESS_KEY_ID="<s3_access_key>" \
AWS_SECRET_ACCESS_KEY="<s3_secret_key>" \
aws s3 mb s3://<bucket-name> \
  --endpoint-url https://s3.gra.io.cloud.ovh.net \
  --region gra
```

Then update `argo-values.yaml` accordingly and redeploy:

```bash
tofu apply -var-file=secrets/terraform.tfvars -target=helm_release.argo_workflows
```

---

## STAC catalog

The following subdomains are deployed via `grid4earth-stac-stack.yaml`:

- stac-fastapi-geoparquet → https://stac-api.grid4earth.eu
- stac-browser → https://stac-browser.grid4earth.eu
- gridlook → https://gridlook.grid4earth.eu

---

## GitHub OAuth

The JupyterHub GitHub OAuth callback URL is:

```
https://jupyterhub.grid4earth.eu/hub/oauth_callback
```

This must match the callback URL configured in the GitHub OAuth App settings
(github.com → Settings → Developer settings → OAuth Apps).
