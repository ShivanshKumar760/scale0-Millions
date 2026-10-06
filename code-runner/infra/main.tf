# # ---------- Network ----------
# resource "digitalocean_vpc" "lab" {
#   name     = "lab-vpc"
#   region   = var.region
#   ip_range = "10.10.0.0/24"
# }
# resource "digitalocean_ssh_key" "laptop" {
#   name       = "laptop"
#   public_key = file(pathexpand(var.ssh_public_key_path))
# }
# resource "digitalocean_tag" "api" { name = "api" }
# resource "digitalocean_tag" "bastion" { name = "bastion" }

# # ---------- Registry + read-only pull credentials ----------
# resource "digitalocean_container_registry" "lab" {
#   name                   = var.registry_name
#   subscription_tier_slug = "starter"
#   region                 = var.region
# }
# resource "digitalocean_container_registry_docker_credentials" "pull" {
#   registry_name  = digitalocean_container_registry.lab.name
#   write          = false
#   expiry_seconds = 2592000
# }
# locals {
#   image = "registry.digitalocean.com/${digitalocean_container_registry.lab.name}/code-runner:${var.image_tag}"
# }

# # ---------- Bastion ----------
# resource "digitalocean_droplet" "bastion" {
#   name     = "bastion"
#   region   = var.region
#   size     = "s-1vcpu-512mb-10gb"
#   image    = "ubuntu-24-04-x64"
#   vpc_uuid = digitalocean_vpc.lab.id
#   ssh_keys = [digitalocean_ssh_key.laptop.fingerprint]
#   tags     = [digitalocean_tag.bastion.id]
# }

# # ---------- Autoscaled API pool ----------
# resource "digitalocean_droplet_autoscale" "api" {
#   name = "api-pool"
#   config {
#     min_instances          = 2
#     max_instances          = 4
#     target_cpu_utilization = 0.6
#     cooldown_minutes       = 5
#   }
#   droplet_template {
#     size              = "s-1vcpu-512mb-10gb"
#     region            = var.region
#     image             = "ubuntu-24-04-x64"
#     vpc_uuid          = digitalocean_vpc.lab.id
#     ssh_keys          = [digitalocean_ssh_key.laptop.id]
#     tags              = [digitalocean_tag.api.id]
#     public_networking = !var.private_droplets
#     user_data         = <<-EOT
#       #cloud-config
#       package_update: true
#       packages: [docker.io]
#       write_files:
#         - path: /root/.docker/config.json
#           permissions: "0600"
#           encoding: b64
#           content: ${base64encode(digitalocean_container_registry_docker_credentials.pull.docker_credentials)}
#       runcmd:
#         - systemctl enable --now docker
#         - iptables -I DOCKER-USER -d 169.254.169.254 -j DROP
#         - docker run -d --restart=always --name api -p 80:5000 --memory=350m --pids-limit=128 ${local.image}
#     EOT
#   }
# }

# # ---------- Load balancer ----------
# resource "digitalocean_loadbalancer" "api" {
#   name     = "api-lb"
#   region   = var.region
#   vpc_uuid = digitalocean_vpc.lab.id
#   forwarding_rule {
#     entry_port      = 80
#     entry_protocol  = "http"
#     target_port     = 80
#     target_protocol = "http"
#   }
#   healthcheck {
#     port                   = 80
#     protocol               = "http"
#     path                   = "/"
#     check_interval_seconds = 10
#     unhealthy_threshold    = 3
#   }
#   droplet_tag = digitalocean_tag.api.name
# }

# # ---------- Firewalls ----------
# resource "digitalocean_firewall" "bastion" {
#   name = "bastion-fw"
#   tags = [digitalocean_tag.bastion.name]
#   inbound_rule {
#     protocol         = "tcp"
#     port_range       = "22"
#     source_addresses = [var.my_ip_cidr]
#   }
#   outbound_rule {
#     protocol              = "tcp"
#     port_range            = "1-65535"
#     destination_addresses = ["0.0.0.0/0", "::/0"]
#   }
#   outbound_rule {
#     protocol              = "udp"
#     port_range            = "1-65535"
#     destination_addresses = ["0.0.0.0/0", "::/0"]
#   }
# }
# resource "digitalocean_firewall" "api" {
#   name = "api-fw"
#   tags = [digitalocean_tag.api.name]
#   inbound_rule {
#     protocol    = "tcp"
#     port_range  = "22"
#     source_tags = [digitalocean_tag.bastion.name]
#   }
#   inbound_rule {
#     protocol                  = "tcp"
#     port_range                = "80"
#     source_load_balancer_uids = [digitalocean_loadbalancer.api.id]
#   }
#   outbound_rule {
#     protocol              = "tcp"
#     port_range            = "1-65535"
#     destination_addresses = ["0.0.0.0/0", "::/0"]
#   }
#   outbound_rule {
#     protocol              = "udp"
#     port_range            = "1-65535"
#     destination_addresses = ["0.0.0.0/0", "::/0"]
#   }
# }

# # ---------- Project (otherwise everything lands in your DEFAULT project) ----------
# resource "digitalocean_project" "lab" {
#   name        = "devops-lab"
#   description = "Code-runner DevOps lab"
#   purpose     = "Web Application"
#   environment = "Development"
#   resources = [
#     digitalocean_droplet.bastion.urn,
#     digitalocean_loadbalancer.api.urn,
#   ]
# }



# ---------- Network ----------
resource "digitalocean_vpc" "lab" {
  name     = "lab-vpc"
  region   = var.region
  ip_range = "10.10.0.0/24"
}

# Existing key (uploaded by hand earlier). Terraform only READS it.
data "digitalocean_ssh_key" "laptop" {
  name = var.ssh_key_name
}

resource "digitalocean_tag" "api" {
  name = "api"
}

resource "digitalocean_tag" "bastion" {
  name = "bastion"
}

# ---------- Registry + read-only pull credentials ----------
resource "digitalocean_container_registry" "lab" {
  name                   = var.registry_name
  subscription_tier_slug = "starter"
  region                 = var.region
}

resource "digitalocean_container_registry_docker_credentials" "pull" {
  registry_name  = digitalocean_container_registry.lab.name
  write          = false
  expiry_seconds = 2592000
}

locals {
  image = "registry.digitalocean.com/${digitalocean_container_registry.lab.name}/code-runner:${var.image_tag}"
}

# ---------- Bastion ----------
resource "digitalocean_droplet" "bastion" {
  name     = "bastion"
  region   = var.region
  size     = "s-1vcpu-512mb-10gb"
  image    = "ubuntu-24-04-x64"
  vpc_uuid = digitalocean_vpc.lab.id
  ssh_keys = [data.digitalocean_ssh_key.laptop.fingerprint]
  tags     = [digitalocean_tag.bastion.id]
}

# ---------- Autoscaled API pool ----------
resource "digitalocean_droplet_autoscale" "api" {
  name = "api-pool"

  config {
    min_instances          = 2
    max_instances          = 4
    target_cpu_utilization = 0.6
    cooldown_minutes       = 5
  }

  droplet_template {
    size              = "s-1vcpu-512mb-10gb"
    region            = var.region
    image             = "ubuntu-24-04-x64"
    vpc_uuid          = digitalocean_vpc.lab.id
    ssh_keys          = [data.digitalocean_ssh_key.laptop.id]
    tags              = [digitalocean_tag.api.id]
    public_networking = !var.private_droplets
    user_data         = <<-EOT
      #cloud-config
      package_update: true
      packages: [docker.io]
      write_files:
        - path: /root/.docker/config.json
          permissions: "0600"
          encoding: b64
          content: ${base64encode(digitalocean_container_registry_docker_credentials.pull.docker_credentials)}
      runcmd:
        - systemctl enable --now docker
        - iptables -I DOCKER-USER -d 169.254.169.254 -j DROP
        - docker run -d --restart=always --name api -p 80:5000 --memory=350m --pids-limit=128 ${local.image}
    EOT
  }
}

# ---------- Load balancer ----------
resource "digitalocean_loadbalancer" "api" {
  name     = "api-lb"
  region   = var.region
  vpc_uuid = digitalocean_vpc.lab.id

  forwarding_rule {
    entry_port      = 80
    entry_protocol  = "http"
    target_port     = 80
    target_protocol = "http"
  }

  healthcheck {
    port                   = 80
    protocol               = "http"
    path                   = "/"
    check_interval_seconds = 10
    unhealthy_threshold    = 3
  }

  droplet_tag = digitalocean_tag.api.name
}

# ---------- Firewalls ----------
resource "digitalocean_firewall" "bastion" {
  name = "bastion-fw"
  tags = [digitalocean_tag.bastion.name]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = [var.my_ip_cidr]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_firewall" "api" {
  name = "api-fw"
  tags = [digitalocean_tag.api.name]

  inbound_rule {
    protocol    = "tcp"
    port_range  = "22"
    source_tags = [digitalocean_tag.bastion.name]
  }

  inbound_rule {
    protocol                  = "tcp"
    port_range                = "80"
    source_load_balancer_uids = [digitalocean_loadbalancer.api.id]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# ---------- Project ----------
# resource "digitalocean_project" "lab" {
#   name        = "devops-lab"
#   description = "Code-runner DevOps lab"
#   purpose     = "Web Application"
#   environment = "Development"

#   resources = [
#     digitalocean_droplet.bastion.urn,
#     digitalocean_loadbalancer.api.urn,
#   ]
# }
#  ---------- Project (existing, created by hand) ----------
data "digitalocean_project" "lab" {
  name = "devops-lab"
}

resource "digitalocean_project_resources" "lab" {
  project = data.digitalocean_project.lab.id

  resources = [
    digitalocean_droplet.bastion.urn,
    digitalocean_loadbalancer.api.urn,
  ]
}