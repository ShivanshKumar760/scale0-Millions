resource "digitalocean_droplet" "api" {
  count      = var.api_count
  name       = "${var.project}-api-${count.index + 1}"
  region     = var.region
  size       = var.api_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.api.name]
  monitoring = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/run.sh" = filebase64("${path.module}/scripts/api.sh")
      "/root/.docker/config.json" = base64encode(
        digitalocean_container_registry_docker_credentials.read.docker_credentials
      )
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }
}