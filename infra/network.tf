resource "digitalocean_vpc" "main" {
  name     = "${var.project}-network"
  region   = var.region
  ip_range = var.vpc_cidr
}

resource "digitalocean_ssh_key" "deploy" {
  name       = "${var.project}-deploy-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}
# If you get "SSH Key is already in use on your account", that key is already uploaded: replace the
# resource above with:   data "digitalocean_ssh_key" "deploy" { name = "<name in the console>" }
# and change every  digitalocean_ssh_key.deploy.id  below to  data.digitalocean_ssh_key.deploy.id


resource "digitalocean_tag" "api" {
  name = "${var.project}-api"
}

resource "digitalocean_tag" "db" {
  name = "${var.project}-db"
}

resource "digitalocean_tag" "cache" {
  name = "${var.project}-cache"
}

locals {
  # Allow ALL outbound traffic. UDP is required for DNS; without it apt/docker pulls fail.
  egress = [
    { protocol = "tcp", port_range = "1-65535" },
    { protocol = "udp", port_range = "1-65535" },
    { protocol = "icmp", port_range = null },
  ]
  lb_ids = digitalocean_loadbalancer.main[*].id

}

resource "digitalocean_firewall" "api" {
  name = "${var.project}-api-fw"
  tags = [digitalocean_tag.api.name]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.admin_cidrs
  }
  dynamic "inbound_rule" {
    for_each = length(local.lb_ids) > 0 ? [1] : []
    content {
      protocol                  = "tcp"
      port_range                = "80"
      source_load_balancer_uids = local.lb_ids
    }
  }

  dynamic "outbound_rule" {
    for_each = local.egress
    content {
      protocol              = outbound_rule.value.protocol
      port_range            = outbound_rule.value.port_range
      destination_addresses = ["0.0.0.0/0", "::/0"]
    }
  }
}

# Databases: SSH from you, PostgreSQL ONLY from inside the VPC
resource "digitalocean_firewall" "db" {
  name = "${var.project}-db-fw"
  tags = [digitalocean_tag.db.name]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.admin_cidrs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "5432"
    source_addresses = [var.vpc_cidr]
  }
  dynamic "outbound_rule" {
    for_each = local.egress
    content {
      protocol              = outbound_rule.value.protocol
      port_range            = outbound_rule.value.port_range
      destination_addresses = ["0.0.0.0/0", "::/0"]
    }
  }
}

# Redis: SSH from you, 6379 ONLY from inside the VPC
resource "digitalocean_firewall" "cache" {
  name = "${var.project}-cache-fw"
  tags = [digitalocean_tag.cache.name]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.admin_cidrs
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "6379"
    source_addresses = [var.vpc_cidr]
  }
  dynamic "outbound_rule" {
    for_each = local.egress
    content {
      protocol              = outbound_rule.value.protocol
      port_range            = outbound_rule.value.port_range
      destination_addresses = ["0.0.0.0/0", "::/0"]
    }
  }
}