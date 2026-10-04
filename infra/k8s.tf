data "digitalocean_kubernetes_versions" "current" {}

resource "digitalocean_kubernetes_cluster" "main" {
  count                = var.enable_k8s ? 1 : 0
  name                 = "${var.project}-k8s"
  region               = var.region
  version              = data.digitalocean_kubernetes_versions.current.latest_version
  vpc_uuid             = digitalocean_vpc.main.id
  surge_upgrade        = true
  registry_integration = true # lets the cluster pull from our private registry
  depends_on           = [digitalocean_container_registry.main]

  node_pool {
    name       = "default"
    size       = var.k8s_node_size
    auto_scale = true
    min_nodes  = var.k8s_min_nodes
    max_nodes  = var.k8s_max_nodes
  }
}