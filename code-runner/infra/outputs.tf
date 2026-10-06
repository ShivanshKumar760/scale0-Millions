output "lb_ip" {
  value = digitalocean_loadbalancer.api.ip
}

output "bastion_ip" {
  value = digitalocean_droplet.bastion.ipv4_address
}

output "image_to_push" {
  value = local.image
}