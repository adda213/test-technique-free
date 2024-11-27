terraform {
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
    }
  }
  required_version = ">= 0.13"
}


resource "scaleway_vpc_private_network" "adda_vpc" {
  region       = "fr-par"
 
}

resource "scaleway_k8s_cluster" "adda-cluster" {
  name    = "adda-cluster"
  version = "1.29.1"
  cni     = "cilium"
  delete_additional_resources = false
  private_network_id = scaleway_vpc_private_network.adda_vpc.id
}

resource "scaleway_k8s_pool" "pool" {
  cluster_id = scaleway_k8s_cluster.adda-cluster.id
  name       = "tf-pool"
  node_type  = "DEV1-M"
  size       = 1
}

resource "null_resource" "kubeconfig" {
  depends_on = [scaleway_k8s_pool.pool] # at least one pool here
  triggers = {
    host                   = scaleway_k8s_cluster.adda-cluster.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.adda-cluster.kubeconfig[0].token
    cluster_ca_certificate = scaleway_k8s_cluster.adda-cluster.kubeconfig[0].cluster_ca_certificate
  }
}

provider "helm" {
  kubernetes {
    host = null_resource.kubeconfig.triggers.host
    token = null_resource.kubeconfig.triggers.token
    cluster_ca_certificate = base64decode(
    null_resource.kubeconfig.triggers.cluster_ca_certificate
    )
  }
}

resource "scaleway_lb_ip" "adda-nginx_ip" {
  zone       = "fr-par-1"
  project_id = scaleway_k8s_cluster.adda-cluster.project_id
}

resource "helm_release" "adda-nginx_ingress" {
  name      = "adda-nginx-ingress"
  namespace = "kube-system"

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart = "ingress-nginx"

  set {
    name = "controller.service.loadBalancerIP"
    value = scaleway_lb_ip.adda-nginx_ip.ip_address
  }

  // enable proxy protocol to get client ip addr instead of loadbalancer one
  set {
    name = "controller.config.use-proxy-protocol"
    value = "true"
  }

  set {
    name = "controller.backend.service.name"
    value = "hello-world-service"
  }
  set {
    name = "controller.backend.service.port.number"
    value = "80"
  }
  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/scw-loadbalancer-proxy-protocol-v2"
    value = "true"
  }

  set {
    name = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/scw-loadbalancer-zone"
    value = scaleway_lb_ip.adda-nginx_ip.zone
  }


  set {
    name = "controller.service.externalTrafficPolicy"
    value = "Local"
  }
}
 output "ip_lb" {
 value = scaleway_lb_ip.adda-nginx_ip.ip_address
 }

 provider "kubernetes" {

    host = null_resource.kubeconfig.triggers.host
    token = null_resource.kubeconfig.triggers.token
    cluster_ca_certificate = base64decode(
    null_resource.kubeconfig.triggers.cluster_ca_certificate
    )
  }

resource "kubernetes_deployment" "app_deployment" {
  metadata {
    name      = "hello-world"

  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "hello-world"
      }
    }
    template {
      metadata {
        labels = {
          app = "hello-world"
        }
      }
      spec {
        container {
          name  = "hello-world"
          image = "rancher/hello-world:latest"
          port {
            container_port = 80
          }
        }
      }
    }
  }
  }

resource "kubernetes_service" "app_service" {
  metadata {
    name      = "hello-world-service"
  }
  spec {
    selector = {
      app = "hello-world"
    }
    port {
      protocol    = "TCP"
      port        = 80
      target_port = 80
    }
    type = "NodePort"
  }
}

