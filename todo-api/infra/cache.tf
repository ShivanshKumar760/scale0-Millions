resource "digitalocean_droplet" "redis" {
  name       = "${var.project}-redis"
  region     = var.region
  size       = var.redis_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.cache.name]
  monitoring = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/env"    = base64encode("REDIS_PASSWORD=${random_password.redis.result}")
      "/opt/bootstrap/run.sh" = filebase64("${path.module}/scripts/redis.sh")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }
}