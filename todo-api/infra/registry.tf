resource "digitalocean_container_registry" "main" {
  name                   = var.registry_name
  subscription_tier_slug = "basic"
  region                 = var.registry_region
}

# Read-only credentials baked into each API droplet so it can `docker pull` your image
resource "digitalocean_container_registry_docker_credentials" "read" {
  registry_name = digitalocean_container_registry.main.name
  write         = false
}