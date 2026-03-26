# Déploiement Grid4Earth DESP-SP-IFREMER

## Prérequis

- OpenTofu >= 1.6
- `openstack` CLI configuré avec les credentials du projet DESP-SP-IFREMER
- Variables d'environnement OVH API (`OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`)

---

## Étape 1 — Générer les credentials S3 OVH

Les credentials S3 OVH sont des credentials OpenStack EC2 liés à ton compte dans le projet.

```bash
# Source ton openrc.sh du projet DESP-SP-IFREMER (téléchargeable depuis la console OVH)
source ~/openrc-desp-sp-ifremer.sh

# Créer les credentials S3
openstack ec2 credentials create

# Le résultat ressemble à :
# +------------+------------------------------------------------------------------+
# | Field      | Value                                                            |
# +------------+------------------------------------------------------------------+
# | access     | xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  <-- c'est ton s3_access_key   |
# | secret     | yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy  <-- c'est ton s3_secret_key   |
# | project_id | 08ad49ea89ef4352b77db6908230c763                                 |
# +------------+------------------------------------------------------------------+
```

Note les valeurs `access` et `secret` — tu en auras besoin pour `tofu apply`.

---

## Étape 2 — Initialiser le backend S3

Le bucket de state (`g4e-desp-state`) doit exister avant `tofu init`.

**Option A — Créer le bucket manuellement d'abord (recommandé) :**
```bash
aws s3 mb s3://g4e-desp-state \
  --endpoint-url https://s3.gra.io.cloud.ovh.net \
  --region gra
```

**Option B — Commenter le bloc `backend "s3"` dans main.tf, faire un premier `tofu apply`
pour créer les buckets, puis décommenter et `tofu init -migrate-state`.**

---

## Étape 3 — Initialiser Tofu

```bash
tofu init \
  -backend-config="access_key=<s3_access_key>" \
  -backend-config="secret_key=<s3_secret_key>"
```

---

## Étape 4 — Appliquer

Via le fichier `secrets/terraform.tfvars` (ne pas committer) :
```hcl
harbor_robot_username = "robot$dest-sp+pull-jupyterhub"
harbor_robot_token    = "..."
s3_access_key         = "..."
s3_secret_key         = "..."
```

```bash
tofu apply -var-file=secrets/terraform.tfvars
```

### Note : premier déploiement cert-manager

Lors du premier déploiement, cert-manager doit être installé avant que le ClusterIssuer
puisse être créé. Appliquer en deux étapes :

```bash
# Étape 1 — installer cert-manager seul
tofu apply -var-file=secrets/terraform.tfvars -target=helm_release.cert_manager

# Étape 2 — appliquer le reste
tofu apply -var-file=secrets/terraform.tfvars
```

---

## Architecture déployée

```
Projet OVH DESP-SP-IFREMER (08ad49ea...)
│
├── K8s Cluster (GRA7) — g4e-desp-cluster
│   ├── Node pool CPU  : b3-32, autoscale 1-5, label node-role=cpu
│   └── Node pool GPU  : à provisionner par Serco/ESA (flavor a10-45 ou similaire)
│                        taint nvidia.com/gpu=true:NoSchedule
│
├── Namespace jupyterhub
│   ├── JupyterHub 4.3.2  — https://g4e-desp.duckdns.org
│   │   ├── Profil CPU standard (✅ opérationnel)
│   │   └── Profil GPU A10 (🚫 en attente des nœuds GPU Serco/ESA)
│   ├── Dask Gateway 2025.4.0
│   ├── NGINX Ingress (classe nginx-jupyterhub)
│   └── cert-manager — TLS Let's Encrypt (ClusterIssuer: letsencrypt-jupyterhub)
│
├── Namespace argo
│   └── Argo Workflows 0.46.2
│       └── Artifacts → S3 g4e-desp-argo-artifacts
│
├── Namespace nvidia-device-plugin
│   └── NVIDIA Device Plugin — à déployer quand les nœuds GPU seront disponibles
│
└── Buckets S3 (GRA)
    ├── g4e-desp-state          (état Tofu)
    └── g4e-desp-argo-artifacts (artifacts Argo Workflows)
```

---

## Harbor — Registry privée

L'image singleuser JupyterHub est hébergée sur le Harbor OVH :
`4763110s.eu-west-par.container-registry.ovh.net/dest-sp/g4e_jupyterhub_private`

Le robot account utilisé pour le pull est un **project-level robot** (dans le projet `dest-sp`) :
- **Username** : `robot$dest-sp+pull-jupyterhub`
- **Secret** : dans `secrets/terraform.tfvars`

Le secret Kubernetes correspondant (`harbor-pull-secret`) est créé automatiquement par Tofu
dans le namespace `jupyterhub`.

> **Important** : lors du `docker login` en CLI, utiliser des **single quotes** autour du username
> pour éviter que le `$` soit interprété par le shell :
> ```bash
> echo 'TOKEN' | docker login 4763110s.eu-west-par.container-registry.ovh.net \
>   -u 'robot$dest-sp+pull-jupyterhub' \
>   --password-stdin
> ```

---

## Activer les GPUs (quand Serco/ESA aura provisionné les ressources)

1. Vérifier que les nœuds GPU apparaissent dans le cluster :
   ```bash
   kubectl get nodes -l node-role=gpu
   ```

2. Vérifier le flavor disponible :
   ```bash
   openstack flavor list | grep -i a10
   ```

3. Ajouter le node pool GPU dans `main.tf` avec le bon `flavor_name`.

4. Déployer le NVIDIA device plugin (voir `nvidia-plugin-values.yaml`).

5. Mettre à jour le `display_name` du profil GPU dans `values.yaml` (retirer "not available yet").

---

## Exemple de workflow Argo avec GPU

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
        image: 4763110s.eu-west-par.container-registry.ovh.net/dest-sp/g4e_jupyterhub_private:latest
        command: [python, /scripts/regrid_healpix.py]
        resources:
          limits:
            nvidia.com/gpu: "1"
            memory: "16G"
            cpu: "8"
          requests:
            nvidia.com/gpu: "1"
            memory: "16G"
            cpu: "4"
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        node-role: gpu
```

---

## Notes importantes

- Le domaine JupyterHub est `g4e-desp.duckdns.org` — pointe vers `146.59.204.113` (IP du LoadBalancer nginx).
- Le certificat TLS est géré automatiquement par cert-manager (Let's Encrypt).
- L'URL Argo dans `argo-values.yaml` est `argo-g4e.duckdns.org` — à créer sur duckdns.org
  et pointer vers l'IP du LoadBalancer nginx si Argo Workflows doit être exposé.
