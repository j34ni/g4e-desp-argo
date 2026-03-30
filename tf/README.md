# Grid4Earth DESP — JupyterHub + Argo Workflows on OVHcloud

OpenTofu deployment of JupyterHub, Dask Gateway and Argo Workflows on the GRID4EARTH OVHcloud project (GRA9).

## Stack

- JupyterHub 4.3.2 (Zero-to-JupyterHub)
- Dask Gateway 2025.4.0
- Argo Workflows 0.46.2
- NGINX Ingress Controller
- cert-manager v1.14.4 + Let's Encrypt
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

Save the credentials in `tf/secrets/ovh-creds.sh` (already listed in `.gitignore`):

```bash
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="..."
export OVH_APPLICATION_SECRET="..."
export OVH_CONSUMER_KEY="..."
```

Source before any Tofu operation:

```bash
source tf/secrets/ovh-creds.sh
```

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

Create `tf/backend.tfvars` (not committed):

```hcl
access_key = "<s3_access_key>"
secret_key = "<s3_secret_key>"
```

Create `tf/secrets/terraform.tfvars` (not committed):

```hcl
harbor_robot_username = "<robot_username>"
harbor_robot_token    = "<robot_token>"
s3_access_key         = "<s3_access_key>"
s3_secret_key         = "<s3_secret_key>"
```

---

## Step 5 — Initialize Tofu

```bash
cd tf
source secrets/ovh-creds.sh

tofu init \
  -backend-config=backend.tfvars \
  -backend-config="endpoint=https://s3.gra.io.cloud.ovh.net" \
  -backend-config="region=gra" \
  -backend-config="skip_credentials_validation=true" \
  -backend-config="skip_requesting_account_id=true" \
  -backend-config="skip_region_validation=true"
```

If a previous backend configuration exists, add `-reconfigure`.

---

## Step 6 — Deploy

The deployment must be done in three passes due to a Tofu limitation: the `kubernetes_manifest` resource (cert-manager ClusterIssuer) cannot be planned before the cluster exists.

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
  -target=kubernetes_secret.harbor_pull_secret \
  -target=kubernetes_secret.harbor_pull_secret_argo \
  -target=kubernetes_secret.argo_s3_credentials \
  -target=kubernetes_secret.s3_credentials_jupyterhub \
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

---

## Step 7 — Configure DNS

After Pass 2, retrieve the LoadBalancer external IP:

```bash
kubectl get svc -n jupyterhub ingress-nginx-controller
```

Update the following DuckDNS entries to point to the external IP:

- `g4e-desp.duckdns.org` → JupyterHub
- `argo-g4e.duckdns.org` → Argo Workflows

The TLS certificate will be issued automatically by cert-manager within a few minutes.

---

## Step 8 — Retrieve kubeconfig

The kubeconfig is available from the OVHcloud Manager:

**Public Cloud → GRID4EARTH → Managed Kubernetes Service → g4e-desp-cluster → kubeconfig → Download**

```bash
export KUBECONFIG=~/.kube/config-desp
kubectl get pods -n jupyterhub
kubectl get pods -n argo
```

---

## Architecture

```
OVHcloud project: GRID4EARTH (24b43ff90f3044c8923063b0fbb53f26)
│
├── MKS Cluster (GRA9) — g4e-desp-cluster
│   └── Node pool CPU: b3-32, autoscale 1–5
│       label: hub.jupyter.org/node-purpose=user, node-role=cpu
│
├── Namespace: jupyterhub
│   ├── JupyterHub 4.3.2     — https://g4e-desp.duckdns.org
│   │   ├── Profile: Standard CPU (✅ operational)
│   │   └── Profile: GPU (⚠️  disabled — see GPU section below)
│   ├── Dask Gateway 2025.4.0
│   ├── NGINX Ingress (class: nginx-jupyterhub)
│   └── cert-manager — Let's Encrypt TLS
│
├── Namespace: argo
│   └── Argo Workflows 0.46.2 — https://argo-g4e.duckdns.org
│       └── Artifacts → S3 bucket (TBD — see Argo artifacts section)
│
└── S3 buckets (GRA)
    ├── g4e-desp-state          (Tofu state)
    └── <TBD>                   (Argo Workflows artifacts)
```

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

## Example Argo workflow (CPU)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: healpix-regrid-
  namespace: argo
spec:
  entrypoint: regrid
  templates:
    - name: regrid
      container:
        image: y74y55mn.gra7.container-registry.ovh.net/healpix-private/g4e-jupyterhub-private:latest
        command: [python, /scripts/regrid_healpix.py]
        resources:
          limits:
            memory: "16G"
            cpu: "8"
          requests:
            memory: "8G"
            cpu: "4"
      nodeSelector:
        node-role: cpu
```
