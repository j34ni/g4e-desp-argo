terraform {
  required_version = "~> 1.6"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.10.0"
    }
  }
  backend "s3" {
    bucket                      = "g4e-desp-state"
    key                         = "jupyterhub.tfstate"
    region                      = "gra"
    endpoint                    = "https://s3.gra.io.cloud.ovh.net"
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
  }
}

variable "harbor_robot_username" {
  type      = string
  sensitive = true
}

variable "harbor_robot_token" {
  type      = string
  sensitive = true
}

variable "s3_access_key" {
  type      = string
  sensitive = true
}

variable "s3_secret_key" {
  type      = string
  sensitive = true
}

provider "ovh" {
  endpoint = "ovh-eu"
}

locals {
  service_name = "24b43ff90f3044c8923063b0fbb53f26"
  domain       = "g4e-desp.duckdns.org"
  namespace    = "jupyterhub"
  region       = "GRA9"
}

resource "ovh_cloud_project_kube" "cluster" {
  service_name = local.service_name
  name         = "g4e-desp-cluster"
  region       = local.region
}

resource "ovh_cloud_project_kube_nodepool" "cpu_pool" {
  service_name  = local.service_name
  kube_id       = ovh_cloud_project_kube.cluster.id
  name          = "cpu-workers"
  flavor_name   = "b3-32"
  desired_nodes = 2
  min_nodes     = 1
  max_nodes     = 5
  autoscale     = true

  template {
    metadata {
      annotations = {}
      finalizers  = []
      labels = {
        "hub.jupyter.org/node-purpose" = "user"
        "node-role"                    = "cpu"
      }
    }
    spec {
      unschedulable = false
      taints        = []
    }
  }
}

resource "ovh_cloud_project_kube_nodepool" "dask_worker_pool" {
  service_name  = local.service_name
  kube_id       = ovh_cloud_project_kube.cluster.id
  name          = "dask-workers"
  flavor_name   = "b3-64"
  desired_nodes = 1
  min_nodes     = 1
  max_nodes     = 5
  autoscale     = true

  template {
    metadata {
      annotations = {}
      finalizers  = []
      labels = {
        "hub.jupyter.org/node-purpose" = "user"
        "node-role"                    = "dask-worker"
      }
    }
    spec {
      unschedulable = false
      taints        = []
    }
  }
}

provider "kubernetes" {
  host                   = ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].host
  client_certificate     = base64decode(ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].client_certificate)
  client_key             = base64decode(ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].client_key)
  cluster_ca_certificate = base64decode(ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].host
    client_certificate     = base64decode(ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].client_certificate)
    client_key             = base64decode(ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].client_key)
    cluster_ca_certificate = base64decode(ovh_cloud_project_kube.cluster.kubeconfig_attributes[0].cluster_ca_certificate)
  }
}

resource "kubernetes_namespace" "jupyterhub" {
  metadata {
    name = local.namespace
  }
  lifecycle {
    ignore_changes = [metadata]
  }
  depends_on = [ovh_cloud_project_kube_nodepool.cpu_pool]
}

resource "kubernetes_namespace" "argo" {
  metadata {
    name = "argo"
  }
  lifecycle {
    ignore_changes = [metadata]
  }
  depends_on = [ovh_cloud_project_kube_nodepool.cpu_pool]
}

resource "kubernetes_secret" "argo_s3_credentials" {
  metadata {
    name      = "argo-s3-credentials"
    namespace = "argo"
  }
  data = {
    accessKey = var.s3_access_key
    secretKey = var.s3_secret_key
  }
  depends_on = [kubernetes_namespace.argo]
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  namespace  = local.namespace
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"

  set {
    name  = "controller.ingressClassResource.name"
    value = "nginx-jupyterhub"
  }
  set {
    name  = "controller.ingressClass"
    value = "nginx-jupyterhub"
  }
  set {
    name  = "controller.ingressClassResource.controllerValue"
    value = "k8s.io/ingress-nginx-jupyterhub"
  }

  depends_on = [kubernetes_namespace.jupyterhub]
}

resource "helm_release" "jupyterhub" {
  name       = "jupyterhub"
  namespace  = local.namespace
  repository = "https://hub.jupyter.org/helm-chart/"
  chart      = "jupyterhub"
  version    = "4.3.2"
  timeout    = 600

  set {
    name  = "imagePullSecrets[0]"
    value = "harbor-pull-secret"
  }

  values = [
    file("${path.module}/secrets/values.yaml"),
    file("${path.module}/values.yaml"),
  ]

  set {
    name  = "singleuser.startTimeout"
    value = "600"
  }

  set {
    name  = "hub.config.JupyterHub.authenticator_class"
    value = "github"
  }
  set {
    name  = "hub.config.GitHubOAuthenticator.oauth_callback_url"
    value = "https://${local.domain}/hub/oauth_callback"
  }
  set {
    name  = "hub.config.GitHubOAuthenticator.allowed_users"
    value = "{allixender,annefou,benbovy,capetienne,cgueguen,j34ni,fpaulifr,keewis,kmch,luikiris,jmdelouis,pablo-richard,tik65536,tinaok,vinbv}"
  }
  set {
    name  = "ingress.enabled"
    value = "true"
  }
  set {
    name  = "ingress.ingressClassName"
    value = "nginx-jupyterhub"
  }
  set {
    name  = "ingress.annotations.cert-manager\\.io/cluster-issuer"
    value = "letsencrypt-jupyterhub"
  }
set {
    name  = "ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/proxy-body-size"
    value = "0"
    type  = "string"
  }
  set {
    name  = "ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/proxy-read-timeout"
    value = "3600"
    type  = "string"
  }
  set {
    name  = "ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/proxy-send-timeout"
    value = "3600"
    type  = "string"
  }
  set {
    name  = "ingress.hosts[0]"
    value = local.domain
  }
  set {
    name  = "ingress.tls[0].hosts[0]"
    value = local.domain
  }
  set {
    name  = "ingress.tls[0].secretName"
    value = "jupyterhub-tls"
  }
  set {
    name  = "singleuser.image.name"
    value = "y74y55mn.gra7.container-registry.ovh.net/healpix-private/g4e-jupyterhub-private"
  }
  set {
    name  = "singleuser.image.tag"
    value = "latest"
  }
  set {
    name  = "singleuser.image.pullSecrets[0]"
    value = "harbor-pull-secret"
  }
  set {
    name  = "singleuser.storage.type"
    value = "dynamic"
  }
  set {
    name  = "singleuser.storage.capacity"
    value = "20Gi"
  }
  set {
    name  = "singleuser.storage.dynamic.storageClass"
    value = "csi-cinder-high-speed"
  }

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_secret.harbor_pull_secret,
  ]
}

resource "helm_release" "dask_gateway" {
  name       = "dask-gateway"
  namespace  = local.namespace
  repository = "https://helm.dask.org"
  chart      = "dask-gateway"
  version    = "2025.4.0"
  timeout    = 300

  values = [
    file("${path.module}/dask-gateway-values.yaml"),
  ]

  depends_on = [helm_release.jupyterhub]
}

resource "helm_release" "argo_workflows" {
  name       = "argo-workflows"
  namespace  = "argo"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-workflows"
  version    = "0.46.2"
  timeout    = 600

  values = [
    file("${path.module}/argo-values.yaml"),
  ]

  depends_on = [
    kubernetes_namespace.argo,
    kubernetes_secret.argo_s3_credentials,
    kubernetes_secret.harbor_pull_secret_argo,
  ]
}

resource "kubernetes_network_policy" "singleuser_dask" {
  metadata {
    name      = "singleuser-dask-gateway"
    namespace = local.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app"       = "jupyterhub"
        "component" = "singleuser-server"
        "release"   = "jupyterhub"
      }
    }

    egress {
      ports {
        port     = "8000"
        protocol = "TCP"
      }
      to {
        pod_selector {
          match_labels = {
            "app.kubernetes.io/component" = "traefik"
            "app.kubernetes.io/instance"  = "dask-gateway"
            "app.kubernetes.io/name"      = "dask-gateway"
          }
        }
      }
    }

    policy_types = ["Egress"]
  }
}

resource "kubernetes_network_policy" "singleuser_to_argo" {
  metadata {
    name      = "singleuser-to-argo"
    namespace = local.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app"       = "jupyterhub"
        "component" = "singleuser-server"
        "release"   = "jupyterhub"
      }
    }

    egress {
      ports {
        port     = "2746"
        protocol = "TCP"
      }
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "argo"
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "argo-workflows-server"
          }
        }
      }
    }

    policy_types = ["Egress"]
  }

  depends_on = [
    helm_release.argo_workflows,
    helm_release.jupyterhub,
  ]
}

resource "kubernetes_secret" "harbor_pull_secret" {
  metadata {
    name      = "harbor-pull-secret"
    namespace = local.namespace
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "y74y55mn.gra7.container-registry.ovh.net" = {
          username = var.harbor_robot_username
          password = var.harbor_robot_token
          auth     = base64encode("${var.harbor_robot_username}:${var.harbor_robot_token}")
        }
      }
    })
  }
  depends_on = [kubernetes_namespace.jupyterhub]
}

resource "kubernetes_secret" "harbor_pull_secret_argo" {
  metadata {
    name      = "harbor-pull-secret"
    namespace = "argo"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "y74y55mn.gra7.container-registry.ovh.net" = {
          username = var.harbor_robot_username
          password = var.harbor_robot_token
          auth     = base64encode("${var.harbor_robot_username}:${var.harbor_robot_token}")
        }
      }
    })
  }

  depends_on = [kubernetes_namespace.argo]
}

resource "kubernetes_secret" "s3_credentials_jupyterhub" {
  metadata {
    name      = "s3-credentials"
    namespace = local.namespace
  }
  data = {
    accessKey = var.s3_access_key
    secretKey = var.s3_secret_key
  }
  depends_on = [kubernetes_namespace.jupyterhub]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.14.4"

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [ovh_cloud_project_kube_nodepool.cpu_pool]
}

resource "kubernetes_manifest" "cluster_issuer" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-jupyterhub"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = "jiaquinta@vitenhub.no"
        privateKeySecretRef = {
          name = "letsencrypt-jupyterhub"
        }
        solvers = [{
          http01 = {
            ingress = {
              ingressClassName = "nginx-jupyterhub"
            }
          }
        }]
      }
    }
  }

  depends_on = [helm_release.cert_manager]
}

output "cluster_id" {
  value = ovh_cloud_project_kube.cluster.id
}

output "kubeconfig" {
  value     = ovh_cloud_project_kube.cluster.kubeconfig
  sensitive = true
}
