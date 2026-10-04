locals {
  pg_common_env = {
    APP_DB          = "todo"
    APP_DB_PASSWORD = random_password.app_db.result
    REPL_PASSWORD   = random_password.repl.result
    VPC_CIDR        = var.vpc_cidr
  }

  pg_primary_env = merge(local.pg_common_env, {
    PG_SUPERUSER_PASSWORD = random_password.pg_super.result
  })
  # Replicas learn the primary's PRIVATE IP from Terraform (the primary is created first).
  pg_replica_env = merge(local.pg_common_env, {
    PRIMARY_IP = digitalocean_droplet.pg_primary.ipv4_address_private
  })
}

resource "digitalocean_droplet" "pg_primary" {
  name       = "${var.project}-pg-primary"
  region     = var.region
  size       = var.db_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.db.name]
  monitoring = true
  backups    = var.db_backups

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/env"        = base64encode(join("\n", [for k, v in local.pg_primary_env : "${k}=${v}"]))
      "/opt/bootstrap/run.sh"     = filebase64("${path.module}/scripts/pg-primary.sh")
      "/opt/bootstrap/pg-init.sh" = filebase64("${path.module}/scripts/pg-init.sh")
      "/opt/bootstrap/schema.sql" = filebase64("${path.module}/../app/schema.sql")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }

}


resource "digitalocean_droplet" "pg_replica" {
  count      = var.replica_count
  name       = "${var.project}-pg-replica-${count.index + 1}"
  region     = var.region
  size       = var.db_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.db.name]
  monitoring = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/env"    = base64encode(join("\n", [for k, v in local.pg_replica_env : "${k}=${v}"]))
      "/opt/bootstrap/run.sh" = filebase64("${path.module}/scripts/pg-replica.sh")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }

}