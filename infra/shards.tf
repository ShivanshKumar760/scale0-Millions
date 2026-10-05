locals {
  shard_env = [
    for i in range(var.shard_count) : merge(local.pg_common_env, {
      APP_DB                = "todo_shard${i}"
      PG_SUPERUSER_PASSWORD = random_password.pg_super.result
    })
  ]
  index_env = merge(local.pg_common_env, {
    APP_DB                = "todo_index"
    PG_SUPERUSER_PASSWORD = random_password.pg_super.result
  })
}

# ---- the shards: todo-shard-0 ... todo-shard-(N-1). The count.index IS the shard number. ----
resource "digitalocean_droplet" "shard" {
  count      = var.shard_count
  name       = "${var.project}-shard-${count.index}"
  region     = var.region
  size       = var.shard_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.db.name] # same tag = the existing DB firewall covers them automatically
  monitoring = true
  backups    = var.db_backups

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/env"        = base64encode(join("\n", [for k, v in local.shard_env[count.index] : "${k}=${v}"]))
      "/opt/bootstrap/run.sh"     = filebase64("${path.module}/scripts/pg-primary.sh")
      "/opt/bootstrap/pg-init.sh" = filebase64("${path.module}/scripts/pg-init.sh")
      "/opt/bootstrap/schema.sql" = filebase64("${path.module}/../app/schema.sql")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }
}

# ---- the shard index: email -> user_id (small, but every register and login needs it) ----
resource "digitalocean_droplet" "shard_index" {
  count      = var.shard_count > 0 ? 1 : 0
  name       = "${var.project}-shard-index"
  region     = var.region
  size       = var.shard_index_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.db.name]
  monitoring = true
  backups    = var.db_backups

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/env"        = base64encode(join("\n", [for k, v in local.index_env : "${k}=${v}"]))
      "/opt/bootstrap/run.sh"     = filebase64("${path.module}/scripts/pg-primary.sh")
      "/opt/bootstrap/pg-init.sh" = filebase64("${path.module}/scripts/pg-init.sh")
      # the index database gets the index schema instead of the users/todos schema
      "/opt/bootstrap/schema.sql" = filebase64("${path.module}/../app/index_schema.sql")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }
}

# ---- optional hot standbys: one streaming replica per shard, and one for the index ----
resource "digitalocean_droplet" "shard_standby" {
  count      = var.shard_standbys ? var.shard_count : 0
  name       = "${var.project}-shard-${count.index}-standby"
  region     = var.region
  size       = var.shard_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.db.name]
  monitoring = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      # PRIMARY_IP = the private IP of THIS shard's primary (same count.index)
      "/opt/bootstrap/env" = base64encode(join("\n", [
        for k, v in merge(local.pg_common_env, {
          PRIMARY_IP = digitalocean_droplet.shard[count.index].ipv4_address_private
        }) : "${k}=${v}"
      ]))
      "/opt/bootstrap/run.sh" = filebase64("${path.module}/scripts/pg-replica.sh")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }
}

resource "digitalocean_droplet" "index_standby" {
  count      = var.shard_standbys && var.shard_count > 0 ? 1 : 0
  name       = "${var.project}-shard-index-standby"
  region     = var.region
  size       = var.shard_index_size
  image      = var.image
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.id]
  tags       = [digitalocean_tag.db.name]
  monitoring = true

  user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files = {
      "/opt/bootstrap/env" = base64encode(join("\n", [
        for k, v in merge(local.pg_common_env, {
          PRIMARY_IP = one(digitalocean_droplet.shard_index[*].ipv4_address_private)
        }) : "${k}=${v}"
      ]))
      "/opt/bootstrap/run.sh" = filebase64("${path.module}/scripts/pg-replica.sh")
    }
  })

  lifecycle {
    ignore_changes = [user_data, image]
  }
}