output "lb_ip" {
  value = one(digitalocean_loadbalancer.main[*].ip)
}

output "registry_endpoint" {
  value = digitalocean_container_registry.main.endpoint
}

output "api_names" {
  value = digitalocean_droplet.api[*].name
}

output "api_public_ips" {
  value = digitalocean_droplet.api[*].ipv4_address
}

output "pg_primary_public_ip" {
  value = digitalocean_droplet.pg_primary.ipv4_address
}

output "pg_primary_private_ip" {
  value = digitalocean_droplet.pg_primary.ipv4_address_private
}

output "pg_replica_public_ips" {
  value = digitalocean_droplet.pg_replica[*].ipv4_address
}

output "pg_replica_private_ips" {
  value = digitalocean_droplet.pg_replica[*].ipv4_address_private
}

output "redis_public_ip" {
  value = digitalocean_droplet.redis.ipv4_address
}

output "redis_private_ip" {
  value = digitalocean_droplet.redis.ipv4_address_private
}

output "k8s_cluster_id" {
  value = one(digitalocean_kubernetes_cluster.main[*].id)
}

output "app_db_password" {
  value     = random_password.app_db.result
  sensitive = true
}

output "redis_password" {
  value     = random_password.redis.result
  sensitive = true
}

output "jwt_secret" {
  value     = random_password.jwt.result
  sensitive = true
}