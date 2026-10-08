# Production-Ready Todo API on DigitalOcean: Terraform + Docker (built for 1M users from day one)

**Infrastructure → Terraform. Runtime → Docker. Deployment → a CLI script.** No clicking, no hand-typed `doctl create` commands, no phases. You write the files in the order below, run three commands, and get the whole platform: load balancer, multiple API servers, PostgreSQL primary + read replicas, and Redis. Later, once that is running, a final part moves the API tier to Kubernetes.

> **One dependency on the earlier guide:** the Flask application code is unchanged. Copy `config.py`, `db.py`, `cache.py`, `auth.py`, `todos.py`, `__init__.py`, `wsgi.py`, `requirements.txt` and the two schema files from **Part A of `todo-api-scaling-guide.md`**. Everything *new* (Dockerfile, Terraform, scripts, Kubernetes) is written out in full here.

---

## 1. What you will build

```
                         Internet
                            │
                   ┌────────▼────────┐
                   │  Load Balancer  │  (DigitalOcean, health-checks /healthz)
                   └───┬────┬────┬───┘
            ┌──────────┘    │    └──────────┐
      ┌─────▼─────┐   ┌─────▼─────┐   ┌─────▼─────┐   ...  api_count droplets
      │ api-1     │   │ api-2     │   │ api-3     │        each runs the app in Docker
      └──┬────┬───┘   └──┬────┬───┘   └──┬────┬───┘
         │    │          │    │          │    │        ═══ private VPC network ═══
         │    └──────────┴────┼──────────┘    │
         │  writes            │ cached reads  │ reads
   ┌─────▼──────┐       ┌─────▼─────┐   ┌─────▼──────────────────────┐
   │ pg-primary │──WAL─►│ pg-replica│   │ pg-replica-1, pg-replica-2 │
   │ (Docker)   │       │    ...    │   └────────────────────────────┘
   └────────────┘       └───────────┘
                         ┌───────────┐
                         │   redis   │ (Docker)
                         └───────────┘
```

| Component | Count (default) | Size | Role |
|---|---|---|---|
| Load balancer | 1 (2 units) | n/a | Single public entry, drops unhealthy servers |
| API droplets | 4 | `s-2vcpu-4gb` | Flask + gunicorn in a Docker container, stateless |
| PostgreSQL primary | 1 | `s-4vcpu-8gb` | All writes, login reads |
| PostgreSQL replicas | 2 | `s-4vcpu-8gb` | Streaming copies; serve list/read queries |
| Redis | 1 | `s-1vcpu-2gb` | Per-user todo-list cache |
| Container registry | 1 | basic | Stores your app image |

Approximate cost: **~$280/month** at list prices (verify on digitalocean.com/pricing). Everything is a variable, so you can start smaller and scale up by editing one number.

### Is this really enough for 1 million users?

"1M users" usually means 1M *registered* accounts, not 1M simultaneous. A realistic estimate: 10% daily-active = 100K users × ~20 requests/day ≈ 2M requests/day ≈ 25 requests/second on average, perhaps 250 rps at peak. A todo API served from cache plus replicas handles that comfortably on this setup, which is deliberately over-provisioned for redundancy (4 API nodes, 3 database nodes). **These are estimates, not guarantees. Load-test before launch** (Section 9). Sharding is intentionally *not* included: it adds permanent complexity, and a single primary only becomes a write bottleneck far beyond this load. The app code still supports it if you ever need it.

### Honest limits of the VPS design

- **Database failover is manual.** If the primary dies, you promote a replica yourself (Section 10). A managed PostgreSQL cluster automates this, and the Kubernetes part shows how to switch to it later.
- **Terraform state contains your passwords.** Treat `terraform.tfstate` as a secret (Section 4 covers remote state).

---

## 2. Repository layout and **the exact order to do things**

```
todo-platform/
├── app/                      # Flask code from the earlier guide + Dockerfile (written below)
│   ├── app/…  wsgi.py  requirements.txt  schema.sql  index_schema.sql
│   ├── Dockerfile
│   └── .dockerignore
├── docker-compose.yml        # local development stack
├── infra/                    # ALL Terraform
│   ├── versions.tf
│   ├── variables.tf
│   ├── terraform.tfvars      # YOUR values (the only file you edit to change size/count)
│   ├── secrets.tf
│   ├── network.tf
│   ├── registry.tf
│   ├── db.tf
│   ├── cache.tf
│   ├── lb.tf
│   ├── api.tf
│   ├── k8s.tf                # off until Part 2
│   ├── outputs.tf
│   ├── templates/cloud-init.yaml.tftpl
│   └── scripts/ pg-primary.sh  pg-init.sh  pg-replica.sh  redis.sh  api.sh
└── deploy/
    ├── deploy.sh             # build → push → rolling deploy to every API droplet
    ├── smoke-test.sh
    └── k8s/ …                # Part 2
```

### Run order (the whole guide on one screen)

| # | Action | Where | Command / file |
|---|---|---|---|
| 1 | Install tools, export your DigitalOcean token | laptop | Section 3 |
| 2 | Copy the app code, create `Dockerfile`, test locally | `app/` | Section 3 → `docker compose up` |
| 3 | **Create the Terraform files** (Terraform reads *every* `.tf` file in the folder together, so the order you create them doesn't matter, but this is the logical order) | `infra/` | `versions.tf` → `variables.tf` → `terraform.tfvars` → `secrets.tf` → `network.tf` → `registry.tf` → `scripts/*` + `templates/*` → `db.tf` → `cache.tf` → `api.tf` → `lb.tf` → `outputs.tf` |
| 4 | **Run first:** `terraform init` | `infra/` | downloads providers |
| 5 | `terraform plan` then **`terraform apply`** | `infra/` | creates everything (~5–8 min) |
| 6 | Wait for servers to finish bootstrapping, verify DB + Redis | laptop | Section 8 |
| 7 | **Run second:** `deploy/deploy.sh` | repo root | builds image, pushes, starts containers on every API droplet |
| 8 | **Run third:** `deploy/smoke-test.sh` | repo root | proves it works through the load balancer |
| 9 | Day-to-day: code change → `deploy/deploy.sh`; infra change → edit `terraform.tfvars` → `terraform apply` (and `deploy.sh` if you added API droplets) | | Section 10 |

Why apply before deploy? Terraform needs to exist first: it creates the registry the deploy script pushes to, and the servers the script deploys onto. Until the first deploy, the load balancer shows the API droplets as *unhealthy*; that's expected.

---

## 3. Prerequisites and the application container

**Install (laptop):** Terraform ≥ 1.5, Docker, `jq`, `doctl` (only used to log Docker in to the registry), and git.
```bash
brew install terraform doctl jq        # macOS; on Linux use your package manager / HashiCorp's apt repo
docker --version && terraform version
```
**DigitalOcean API token:** Console → **API → Tokens → Generate New Token** (read + write). Never put it in a file in the repo:
```bash
export DIGITALOCEAN_TOKEN="dop_v1_xxxxxxxx"      # Terraform's provider reads this variable automatically
doctl auth init -t "$DIGITALOCEAN_TOKEN"          # for `doctl registry login` later
```
**SSH key:** Terraform uploads your public key to DigitalOcean. If you don't want to reuse your GitHub key, create one: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_do -C digitalocean`, and set `ssh_public_key_path` to the `.pub` file in `terraform.tfvars`. (Tell SSH to use it by default: add `Host *` + `IdentityFile ~/.ssh/id_ed25519_do` to `~/.ssh/config`, after a `Host github.com` block with your GitHub key.)

### `app/Dockerfile`
```dockerfile
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd --system app && chown -R app /app
USER app
EXPOSE 8000
# gunicorn reads the WEB_CONCURRENCY environment variable for its worker count
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--timeout", "30", "--access-logfile", "-", "wsgi:app"]
```
### `app/.dockerignore`
```text
venv
__pycache__
.git
.env
```
### `docker-compose.yml` (local development: same containers as production)
```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: todo
      POSTGRES_PASSWORD: todo
      POSTGRES_DB: todo
    volumes:
      - ./app/schema.sql:/docker-entrypoint-initdb.d/schema.sql:ro
    ports: ["5432:5432"]
  redis:
    image: redis:7-alpine
  api:
    build: ./app
    environment:
      JWT_SECRET_KEY: dev-secret
      DATABASE_URL: postgresql://todo:todo@db:5432/todo
      REDIS_URL: redis://redis:6379/0
      WEB_CONCURRENCY: "2"
    ports: ["8000:8000"]
    depends_on: [db, redis]
```
```bash
docker compose up --build
curl -s localhost:8000/healthz        # then re-run the register / login / todo curl tests from the earlier guide against :8000
```
`docker compose down -v` when finished.

---
## 4. The Terraform files (create in this order)

Create `infra/` and put every file below in it. Terraform merges all `*.tf` files in a folder, so they can reference each other freely.

### 4.1 `infra/versions.tf`: which providers, how to authenticate
```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Reads the token from the DIGITALOCEAN_TOKEN environment variable (never hard-code it).
provider "digitalocean" {}
```
**Optional but recommended: remote state.** State holds every generated password. Create a private Spaces bucket by hand once (Terraform can't bootstrap its own state bucket), export `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` with your Spaces keys, then add inside the `terraform {}` block:
```hcl
  backend "s3" {
    bucket                      = "your-tfstate-bucket"
    key                         = "todo/terraform.tfstate"
    region                      = "us-east-1"          # placeholder; Spaces ignores it
    endpoints                   = { s3 = "https://blr1.digitaloceanspaces.com" }
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
```
(Backend options change between Terraform versions; if `init` complains, check the "S3 backend" docs. With local state, just make sure `*.tfstate*` is in `.gitignore`.)

### 4.2 `infra/variables.tf`: every knob
```hcl
variable "project"        { default = "todo" }
variable "region"         { default = "blr1" }                  # nearest to you; e.g. nyc3, sfo3, lon1, fra1, sgp1
variable "vpc_cidr"       { default = "10.20.0.0/16" }          # private network range
variable "image"          { default = "ubuntu-24-04-x64" }
variable "ssh_public_key_path" { default = "~/.ssh/id_ed25519.pub" }

# Who may SSH to the servers: YOUR public IP as /32. Find it with: curl -s https://api.ipify.org
variable "admin_cidrs" { type = list(string) }

variable "registry_name"  { type = string }                     # globally unique, e.g. todo-reg-yourname

# --- sizes / counts: the "scale" dials ---
variable "api_count"      { default = 4 }
variable "api_size"       { default = "s-2vcpu-4gb" }
variable "db_size"        { default = "s-4vcpu-8gb" }
variable "replica_count"  { default = 2 }
variable "redis_size"     { default = "s-1vcpu-2gb" }
variable "lb_size_unit"   { default = 2 }
variable "db_backups"     { default = true }                    # DO weekly whole-droplet backups (+20% price)

# --- optional features ---
variable "domain"         { default = "" }                      # e.g. "example.com" -> api.example.com with HTTPS
variable "enable_lb"      { default = true }
variable "enable_k8s"     { default = false }                   # Part 2
variable "k8s_node_size"  { default = "s-2vcpu-4gb" }
variable "k8s_min_nodes"  { default = 3 }
variable "k8s_max_nodes"  { default = 8 }
```

### 4.3 `infra/terraform.tfvars`: **your** values (the file you edit later to scale)
```hcl
admin_cidrs   = ["203.0.113.7/32"]      # <- replace with YOUR IP: curl -s https://api.ipify.org  (add /32)
registry_name = "todo-reg-yourname"     # <- must be unique across all DigitalOcean customers
# api_count   = 6                       # uncomment / change to scale
```
If your home IP changes you'll be locked out of SSH. Update `admin_cidrs` and `terraform apply`; the firewall updates in seconds (or use the web console as a fallback).

### 4.4 `infra/secrets.tf`: passwords generated by Terraform
```hcl
resource "random_password" "jwt"      { length = 64  special = false }
resource "random_password" "pg_super" { length = 32  special = false }
resource "random_password" "app_db"   { length = 32  special = false }
resource "random_password" "repl"     { length = 32  special = false }
resource "random_password" "redis"    { length = 32  special = false }
```
`special = false` keeps them URL-safe (they're embedded in connection strings). `JWT secret` is identical on every API server because it is one value shared via the deploy script, so a token issued by api-1 is valid on api-3.

### 4.5 `infra/network.tf`: VPC, SSH key, tags, firewalls
```hcl
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

resource "digitalocean_tag" "api"   { name = "${var.project}-api" }
resource "digitalocean_tag" "db"    { name = "${var.project}-db" }
resource "digitalocean_tag" "cache" { name = "${var.project}-cache" }

locals {
  # Allow ALL outbound traffic. UDP is required for DNS; without it apt/docker pulls fail.
  egress = [
    { protocol = "tcp",  port_range = "1-65535" },
    { protocol = "udp",  port_range = "1-65535" },
    { protocol = "icmp", port_range = null },
  ]
  lb_ids = digitalocean_loadbalancer.main[*].id
}

# API servers: SSH from you, port 80 ONLY from the load balancer
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
```
Firewalls attach **by tag**, so every droplet Terraform creates with a tag is protected from its very first second, and scaling `api_count` automatically covers new servers.

### 4.6 `infra/registry.tf`: private image registry and pull credentials
```hcl
resource "digitalocean_container_registry" "main" {
  name                   = var.registry_name
  subscription_tier_slug = "basic"
  region                 = var.region
}

# Read-only credentials baked into each API droplet so it can `docker pull` your image
resource "digitalocean_container_registry_docker_credentials" "read" {
  registry_name = digitalocean_container_registry.main.name
  write         = false
}
```

### 4.7 The cloud-init template and bootstrap scripts

**How servers configure themselves:** each droplet gets a `user_data` script (cloud-init) that runs once on first boot. Ours installs Docker, drops a few files onto the machine, and runs one role script (`run.sh`) that starts the right container. Terraform generates it from this template.

`infra/templates/cloud-init.yaml.tftpl`
```yaml
#cloud-config
package_update: true
packages:
  - docker.io
  - jq
write_files:
%{ for path, content in files ~}
  - path: ${path}
    permissions: "0700"
    encoding: b64
    content: ${content}
%{ endfor ~}
runcmd:
  - systemctl enable --now docker
  - [ bash, -c, "bash /opt/bootstrap/run.sh > /var/log/bootstrap.log 2>&1" ]
```
Every file is passed base64-encoded, so special characters in scripts or passwords can never break the YAML.

`infra/scripts/pg-init.sh`: runs **once**, inside the PostgreSQL container, the first time the database is initialised (the official image runs anything placed in `/docker-entrypoint-initdb.d`):
```bash
#!/bin/bash
set -e

# Application role (least privilege: owns only the "todo" database) and replication role
psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<SQL
CREATE ROLE todo LOGIN PASSWORD '$APP_DB_PASSWORD';
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASSWORD';
ALTER DATABASE "$POSTGRES_DB" OWNER TO todo;
SQL

# "replication" is a special keyword in pg_hba.conf (not a real database): allow replicas anywhere in the VPC
echo "host replication replicator $VPC_CIDR scram-sha-256" >> "$PGDATA/pg_hba.conf"

# Create the two tables (users, todos) as the app role
psql -v ON_ERROR_STOP=1 -U todo -d "$POSTGRES_DB" -f /schema.sql
```
`infra/scripts/pg-primary.sh`: the primary's role script:
```bash
#!/bin/bash
set -euo pipefail
source /opt/bootstrap/env

# This droplet's own PRIVATE IP, from DigitalOcean's metadata service (works only from inside a droplet)
MY_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

mkdir -p /opt/pg/data /opt/pg/initdb.d /var/backups/postgres
cp /opt/bootstrap/pg-init.sh /opt/pg/initdb.d/01-init.sh

# --network host: Postgres binds directly to the droplet's private IP (and localhost), never the public one
docker run -d --name pg --restart unless-stopped --network host --shm-size=1g \
  -e POSTGRES_PASSWORD="$PG_SUPERUSER_PASSWORD" \
  -e POSTGRES_DB="$APP_DB" \
  -e APP_DB_PASSWORD="$APP_DB_PASSWORD" \
  -e REPL_PASSWORD="$REPL_PASSWORD" \
  -e VPC_CIDR="$VPC_CIDR" \
  -v /opt/pg/data:/var/lib/postgresql/data \
  -v /opt/pg/initdb.d:/docker-entrypoint-initdb.d:ro \
  -v /opt/bootstrap/schema.sql:/schema.sql:ro \
  postgres:16 \
  -c listen_addresses="127.0.0.1,$MY_IP" \
  -c wal_level=replica -c max_wal_senders=10 -c wal_keep_size=2GB \
  -c max_connections=300 -c hot_standby=on \
  -c shared_buffers="$((MEM_MB / 4))MB" -c effective_cache_size="$((MEM_MB * 3 / 4))MB"

# Nightly logical backup at 02:00, keep 7 days
cat > /usr/local/bin/pg-backup.sh <<'EOF'
#!/bin/bash
set -euo pipefail
docker exec pg pg_dump -U postgres -Fc todo > /var/backups/postgres/todo-$(date +%F).dump
find /var/backups/postgres -name 'todo-*.dump' -mtime +7 -delete
EOF
chmod +x /usr/local/bin/pg-backup.sh
echo "0 2 * * * root /usr/local/bin/pg-backup.sh" > /etc/cron.d/pg-backup
```
`infra/scripts/pg-replica.sh`: each replica's role script:
```bash
#!/bin/bash
set -euo pipefail
source /opt/bootstrap/env          # provides PRIMARY_IP (the primary's private IP), REPL_PASSWORD

MY_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
mkdir -p /opt/pg/data

# The primary boots at the same time as us: wait until it accepts connections
until docker run --rm --network host postgres:16 pg_isready -h "$PRIMARY_IP" -p 5432 -q; do
  echo "waiting for primary at $PRIMARY_IP ..."; sleep 5
done

# Clone the primary's data directory (first boot only). -R writes standby.signal + connection info.
if [ -z "$(ls -A /opt/pg/data)" ]; then
  docker run --rm --network host -e PGPASSWORD="$REPL_PASSWORD" \
    -v /opt/pg/data:/var/lib/postgresql/data postgres:16 \
    bash -c "pg_basebackup -h $PRIMARY_IP -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R \
             && chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data"
fi

# Same server settings as the primary (a standby may not have LOWER values than its primary)
docker run -d --name pg --restart unless-stopped --network host --shm-size=1g \
  -v /opt/pg/data:/var/lib/postgresql/data \
  postgres:16 \
  -c listen_addresses="127.0.0.1,$MY_IP" \
  -c wal_level=replica -c max_wal_senders=10 -c wal_keep_size=2GB \
  -c max_connections=300 -c hot_standby=on \
  -c shared_buffers="$((MEM_MB / 4))MB" -c effective_cache_size="$((MEM_MB * 3 / 4))MB"
```
`infra/scripts/redis.sh`:
```bash
#!/bin/bash
set -euo pipefail
source /opt/bootstrap/env          # provides REDIS_PASSWORD
MY_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)

# Cache semantics: bounded memory, evict least-recently-used keys, no disk persistence
docker run -d --name redis --restart unless-stopped --network host redis:7-alpine \
  redis-server --bind 127.0.0.1 "$MY_IP" --requirepass "$REDIS_PASSWORD" \
  --maxmemory 1gb --maxmemory-policy allkeys-lru --save "" --appendonly no
```
`infra/scripts/api.sh`: API droplets only need Docker plus the registry login (deploy comes later):
```bash
#!/bin/bash
mkdir -p /opt/todo
echo "api droplet ready, waiting for first deploy"
```

### 4.8 `infra/db.tf`: PostgreSQL primary and replicas
```hcl
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

  # Changing a bootstrap script must NOT destroy and rebuild a database server.
  lifecycle {
    ignore_changes = [user_data, image]
    # prevent_destroy = true     # uncomment in production; remove it before a deliberate `terraform destroy`
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

  lifecycle { ignore_changes = [user_data, image] }
}
```
📍 **Where IPs come from now:** you never type one. `digitalocean_droplet.pg_primary.ipv4_address_private` is the primary's VPC address, which Terraform learns after creating it and hands to the replicas. The primary doesn't need to know the replicas' IPs because `pg_hba.conf` allows the replication role from the whole VPC range (`$VPC_CIDR`), and the firewall already keeps everyone else out.

### 4.9 `infra/cache.tf`: Redis
```hcl
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

  lifecycle { ignore_changes = [user_data, image] }
}
```

### 4.10 `infra/api.tf`: the API droplets
```hcl
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
      "/opt/bootstrap/run.sh"   = filebase64("${path.module}/scripts/api.sh")
      "/root/.docker/config.json" = base64encode(
        digitalocean_container_registry_docker_credentials.read.docker_credentials
      )
    }
  })

  lifecycle { ignore_changes = [user_data, image] }
}
```
The registry credentials land in `/root/.docker/config.json`, which is how `docker pull` on the droplet authenticates.

### 4.11 `infra/lb.tf`: load balancer (+ optional HTTPS)
```hcl
resource "digitalocean_loadbalancer" "main" {
  count     = var.enable_lb ? 1 : 0
  name      = "${var.project}-lb"
  region    = var.region
  vpc_uuid  = digitalocean_vpc.main.id
  size_unit = var.lb_size_unit

  # Every droplet carrying this tag joins automatically: scaling = raise api_count
  droplet_tag = digitalocean_tag.api.name

  forwarding_rule {
    entry_port      = 80
    entry_protocol  = "http"
    target_port     = 80
    target_protocol = "http"
  }

  dynamic "forwarding_rule" {
    for_each = var.domain == "" ? [] : [1]
    content {
      entry_port       = 443
      entry_protocol   = "https"
      target_port      = 80
      target_protocol  = "http"
      certificate_name = digitalocean_certificate.api[0].name
    }
  }
  redirect_http_to_https = var.domain != ""

  healthcheck {
    protocol                 = "http"
    port                     = 80
    path                     = "/healthz"
    check_interval_seconds   = 10
    response_timeout_seconds = 5
    healthy_threshold        = 3
    unhealthy_threshold      = 3
  }
}

# ---- Optional HTTPS: only created when you set  domain = "example.com"  ----
# Prerequisite: your registrar's nameservers must already point at ns1/ns2/ns3.digitalocean.com,
# otherwise Let's Encrypt validation cannot succeed. Create the zone first:
#   terraform apply -target=digitalocean_domain.main   (then delegate the nameservers, wait, then apply fully)
resource "digitalocean_domain" "main" {
  count = var.domain == "" ? 0 : 1
  name  = var.domain
}

resource "digitalocean_certificate" "api" {
  count   = var.domain == "" ? 0 : 1
  name    = "${var.project}-cert"
  type    = "lets_encrypt"
  domains = ["api.${var.domain}"]
  lifecycle { create_before_destroy = true }
  depends_on = [digitalocean_domain.main]
}

resource "digitalocean_record" "api" {
  count  = var.domain == "" || !var.enable_lb ? 0 : 1
  domain = digitalocean_domain.main[0].id
  type   = "A"
  name   = "api"
  value  = digitalocean_loadbalancer.main[0].ip
  ttl    = 300
}
```
`healthcheck` hits `/healthz` on port 80 every 10 s; three failures remove a server from rotation, three successes put it back. Passing `size_unit = 2` doubles the balancer's capacity; raise it if you see LB saturation in the console metrics.

### 4.12 `infra/k8s.tf`: stays dormant until Part 2
```hcl
data "digitalocean_kubernetes_versions" "current" {}

resource "digitalocean_kubernetes_cluster" "main" {
  count                = var.enable_k8s ? 1 : 0
  name                 = "${var.project}-k8s"
  region               = var.region
  version              = data.digitalocean_kubernetes_versions.current.latest_version
  vpc_uuid             = digitalocean_vpc.main.id
  surge_upgrade        = true
  registry_integration = true      # lets the cluster pull from our private registry
  depends_on           = [digitalocean_container_registry.main]

  node_pool {
    name       = "default"
    size       = var.k8s_node_size
    auto_scale = true
    min_nodes  = var.k8s_min_nodes
    max_nodes  = var.k8s_max_nodes
  }
}
```
With `enable_k8s = false` (the default), `count = 0` means Terraform creates nothing.

### 4.13 `infra/outputs.tf`: what the deploy scripts read
```hcl
output "lb_ip"                  { value = one(digitalocean_loadbalancer.main[*].ip) }
output "registry_endpoint"      { value = digitalocean_container_registry.main.endpoint }

output "api_names"              { value = digitalocean_droplet.api[*].name }
output "api_public_ips"         { value = digitalocean_droplet.api[*].ipv4_address }

output "pg_primary_public_ip"   { value = digitalocean_droplet.pg_primary.ipv4_address }
output "pg_primary_private_ip"  { value = digitalocean_droplet.pg_primary.ipv4_address_private }
output "pg_replica_public_ips"  { value = digitalocean_droplet.pg_replica[*].ipv4_address }
output "pg_replica_private_ips" { value = digitalocean_droplet.pg_replica[*].ipv4_address_private }

output "redis_public_ip"        { value = digitalocean_droplet.redis.ipv4_address }
output "redis_private_ip"       { value = digitalocean_droplet.redis.ipv4_address_private }

output "k8s_cluster_id"         { value = one(digitalocean_kubernetes_cluster.main[*].id) }

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
```
Add a `.gitignore` at the repo root:
```text
infra/.terraform/
*.tfstate
*.tfstate.*
infra/terraform.tfvars
venv/
__pycache__/
.env
```

---
## 5. Run Terraform (this is the first command you run)

**(laptop)**
```bash
cd todo-platform/infra
export DIGITALOCEAN_TOKEN="dop_v1_xxxxxxxx"      # same token as before; needed in every new terminal

terraform init          # 1) downloads the digitalocean + random providers into .terraform/
terraform fmt           # 2) (optional) tidies formatting
terraform validate      # 3) catches typos and missing references before touching the cloud
terraform plan          # 4) dry run: shows what WOULD be created; creates nothing
terraform apply         # 5) shows the plan again, asks "yes", then builds everything
```
| Command | What it does |
|---|---|
| `terraform init` | Run once per folder (and whenever providers/backends change). Safe to repeat |
| `terraform plan` | Compares your `.tf` files + `terraform.tfvars` against what exists; prints `+` create, `~` change, `-` destroy |
| `terraform apply` | Executes the plan. Terraform orders resources by their references: VPC → firewalls/tags → primary → replicas → API droplets → load balancer |
| `terraform output` | Prints the values from `outputs.tf` any time (`-raw name` for one value, `-json` for scripts) |

Expect roughly **~25 resources** (VPC, key, 3 tags, 3 firewalls, registry + credentials, 1+2 database droplets, Redis, 4 API droplets, load balancer, 5 passwords). `apply` takes 5–8 minutes. Review the plan for **destroys** every time you change something later.

When it finishes:
```bash
terraform output                         # public IPs, private IPs, LB IP (sensitive values are hidden)
terraform output -raw app_db_password    # reveals one sensitive value
```

## 6. One small app patch: multiple read replicas

The app takes one `READ_DATABASE_URL`. With two replicas we want it to use both. Make `READ_DATABASE_URL` a **comma-separated list** and pick one at random per request. Two edits in the app code:

`app/app/config.py`: replace the `READ_DATABASE_URL` line with:
```python
    READ_DATABASE_URLS = [u.strip() for u in os.getenv("READ_DATABASE_URL", "").split(",") if u.strip()]
```
`app/app/db.py`: add `import random` at the top and replace `read_url` with:
```python
def read_url(user_id=None, fresh=False):
    """Ordinary reads: a random replica. Falls back to the primary if none is configured."""
    if sharded():
        return shard_url(user_id)
    cfg = current_app.config
    if fresh:
        return cfg["DATABASE_URL"]
    urls = cfg["READ_DATABASE_URLS"]
    return random.choice(urls) if urls else cfg["DATABASE_URL"]
```
Commit it. (The same app image then also works unchanged on Kubernetes in Part 2.)

## 7. The deploy script (CLI)

Terraform builds servers; this script puts your **application** on them. It builds the Docker image, pushes it to your registry, then updates the API droplets **one at a time** so users never see downtime. It takes every address and password from `terraform output`, so there is nothing to copy by hand.

`deploy/deploy.sh`
```bash
#!/bin/bash
# Usage:  deploy/deploy.sh [image-tag]      (default tag = current git commit)
# Rollback = run it again with an older tag.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${1:-$(git rev-parse --short HEAD)}
API_WORKERS=${API_WORKERS:-5}                 # gunicorn workers per droplet (2 x vCPUs + 1)
OUT=$(terraform -chdir=infra output -json)
get() { echo "$OUT" | jq -r ".$1.value"; }

IMAGE="$(get registry_endpoint)/todo-api:$TAG"

echo "== 1/3 build and push $IMAGE"
doctl registry login --expiry-seconds 3600
docker build --platform linux/amd64 -t "$IMAGE" app
docker push "$IMAGE"

# Connection strings: every host below is a PRIVATE VPC IP produced by Terraform
DB_PASS=$(get app_db_password)
REDIS_PASS=$(get redis_password)
JWT=$(get jwt_secret)
PRIMARY=$(get pg_primary_private_ip)
REDIS=$(get redis_private_ip)
READ_URLS=$(echo "$OUT" | jq -r --arg p "$DB_PASS" \
  '[.pg_replica_private_ips.value[] | "postgresql://todo:\($p)@\(.):5432/todo"] | join(",")')
API_IPS=$(echo "$OUT" | jq -r '.api_public_ips.value[]')

echo "== 2/3 rolling deploy"
for IP in $API_IPS; do
  echo "-- $IP"
  ssh -o StrictHostKeyChecking=accept-new root@"$IP" "cloud-init status --wait >/dev/null 2>&1 || true; mkdir -p /opt/todo"

  # (Re)write this server's environment file
  ssh root@"$IP" "cat > /opt/todo/app.env && chmod 600 /opt/todo/app.env" <<EOF
JWT_SECRET_KEY=$JWT
DATABASE_URL=postgresql://todo:$DB_PASS@$PRIMARY:5432/todo
READ_DATABASE_URL=$READ_URLS
REDIS_URL=redis://:$REDIS_PASS@$REDIS:6379/0
WEB_CONCURRENCY=$API_WORKERS
EOF

  # Pull the image, replace the running container
  ssh root@"$IP" "docker pull $IMAGE \
    && (docker rm -f todo-api >/dev/null 2>&1 || true) \
    && docker run -d --name todo-api --restart unless-stopped -p 80:8000 \
         --env-file /opt/todo/app.env --log-opt max-size=50m --log-opt max-file=3 $IMAGE"

  # Wait until this server answers, then give the load balancer time to see it healthy
  for i in $(seq 1 30); do
    ssh root@"$IP" "curl -fs http://127.0.0.1/healthz" >/dev/null 2>&1 && break
    sleep 2
  done
  sleep 25
done

echo "== 3/3 done: $IMAGE is live on all API servers"
```
```bash
chmod +x deploy/deploy.sh
```
What the `docker run` flags do: `-d` background · `--name todo-api` fixed name so we can replace it · `--restart unless-stopped` survives crashes and reboots · `-p 80:8000` droplet port 80 → gunicorn's 8000 in the container (the firewall only lets the load balancer reach port 80) · `--env-file` loads the secrets without putting them on the command line · `--log-opt` caps log disk usage.

`deploy/smoke-test.sh`
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LB="http://$(terraform -chdir=infra output -raw lb_ip)"
EMAIL="smoke$(date +%s)@example.com"
J='Content-Type: application/json'

echo "health:";  curl -s $LB/healthz; echo
echo "register:"; curl -s -X POST $LB/api/auth/register -H "$J" -d "{\"email\":\"$EMAIL\",\"password\":\"password123\"}"; echo
TOKEN=$(curl -s -X POST $LB/api/auth/login -H "$J" -d "{\"email\":\"$EMAIL\",\"password\":\"password123\"}" | jq -r .access_token)
echo "create:";  curl -s -X POST $LB/api/todos -H "Authorization: Bearer $TOKEN" -H "$J" -d '{"title":"hello 1M users"}'; echo
echo "list x3 (expect MISS then HIT):"
for i in 1 2 3; do curl -s -o /dev/null -D - $LB/api/todos -H "Authorization: Bearer $TOKEN" | grep -i -E '^(x-cache|x-served-by)' | tr '\r\n' '  '; echo; done
echo "load balancing across servers:"
for i in $(seq 1 12); do curl -s -o /dev/null -D - $LB/healthz | grep -i '^x-served-by' | tr -d '\r'; done | sort | uniq -c
```
```bash
chmod +x deploy/smoke-test.sh
```

## 8. Verify the infrastructure, deploy, and test (do these in order)

**8.1: Wait for bootstrapping, then check each tier.** Droplets are "active" before cloud-init finishes installing Docker and starting containers. Wait for it:
```bash
cd todo-platform
O() { terraform -chdir=infra output -raw "$1"; }

ssh -o StrictHostKeyChecking=accept-new root@$(O pg_primary_public_ip) "cloud-init status --wait; docker ps"
```
You should see a `pg` container "Up". (SSH refused? Droplets need ~30–60 s after creation. Timeout? Your `admin_cidrs` doesn't match your current IP.)

**PostgreSQL primary: both tables exist?**
```bash
ssh root@$(O pg_primary_public_ip) "docker exec pg psql -U todo -d todo -c '\dt'"
```
Expect `users` and `todos`.

**Replication: two replicas streaming?**
```bash
ssh root@$(O pg_primary_public_ip) \
  "docker exec pg psql -U postgres -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
```
Expect **two rows, `state = streaming`**; `client_addr` values are the replicas' private IPs (compare with `terraform -chdir=infra output pg_replica_private_ips`). Then confirm a replica really is read-only:
```bash
R1=$(terraform -chdir=infra output -json pg_replica_public_ips | jq -r '.[0]')
ssh root@$R1 "cloud-init status --wait; docker exec pg psql -U postgres -c 'SELECT pg_is_in_recovery();'"      # t
ssh root@$R1 "docker exec pg psql -U postgres -d todo -c \"INSERT INTO todos(user_id,title) VALUES (1,'x')\""   # ERROR: read-only transaction
```
**Redis:**
```bash
ssh root@$(O redis_public_ip) "cloud-init status --wait; docker exec redis redis-cli -a '$(O redis_password)' ping"   # PONG
```
If anything is missing, read the bootstrap log on that droplet: `ssh root@<ip> tail -50 /var/log/bootstrap.log`.

**8.2: First deploy** (the second command you run):
```bash
deploy/deploy.sh
```
It prints one block per API droplet. Afterwards the load balancer's health checks turn green within ~30 s (Console → Networking → Load Balancers, or just run the smoke test).

**8.3: Smoke test** (the third command you run):
```bash
deploy/smoke-test.sh
```
You want: a registered user, a created todo, a list with `X-Cache: MISS` then `HIT`, and the final histogram showing requests spread across all four `todo-api-N` hostnames. **The platform is live.**

## 9. Load test before real users

```bash
brew install hey          # or: go install github.com/rakyll/hey@latest
LB="http://$(terraform -chdir=infra output -raw lb_ip)"
TOKEN=$(curl -s -X POST $LB/api/auth/login -H 'Content-Type: application/json' \
        -d '{"email":"<an email you registered>","password":"password123"}' | jq -r .access_token)

hey -z 60s -c 100 -H "Authorization: Bearer $TOKEN" $LB/api/todos     # cached reads
hey -z 60s -c 50  -m POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"title":"load"}' $LB/api/todos                                # writes (hit the primary)
```
Watch the DigitalOcean **Monitoring** graphs for each droplet while it runs. Rules of thumb: API CPU sustained above ~70% → raise `api_count`; primary CPU/disk high → raise `db_size` (or move reads to more replicas); LB 5xx → raise `lb_size_unit`. Note that login uses password hashing (deliberately CPU-heavy), so expect `register`/`login` to be your most expensive endpoints.

## 10. Operating the platform

| Task | How |
|---|---|
| **Ship new code** | commit → `deploy/deploy.sh` |
| **Roll back** | `deploy/deploy.sh <older-tag>` (tags are git commit hashes; images stay in the registry) |
| **Add API capacity** | set `api_count = 8` in `terraform.tfvars` → `terraform apply` → `deploy/deploy.sh` (new droplets join the load balancer automatically via the tag; the deploy script finds them by itself) |
| **Add a read replica** | `replica_count = 3` → `terraform apply` (it clones itself from the primary) → `deploy/deploy.sh` (refreshes `READ_DATABASE_URL`) |
| **Bigger database** | change `db_size` → `terraform apply`. The droplet is resized in place (powered off briefly), and by default its disk grows too, which cannot be undone. Expect a few minutes of downtime for that droplet: do replicas first, the primary in a maintenance window |
| **Change firewall/SSH IP** | edit `admin_cidrs` → `terraform apply` |
| **See app logs** | `ssh root@<api-ip> docker logs -f --tail 100 todo-api` |
| **Run a schema change** | the schema in `schema.sql` is applied **only on first boot**. For changes, use a migration run from an API droplet (see below) and update `schema.sql` for future rebuilds |
| **Restore a backup** | `ssh root@<primary>`, then `docker exec -i pg pg_restore -U postgres -d todo --clean < /var/backups/postgres/todo-YYYY-MM-DD.dump` |

**Schema change example** (run from any API droplet; it reaches the primary over the VPC):
```bash
ssh root@<api-ip> "docker run --rm --env-file /opt/todo/app.env postgres:16 \
  sh -c 'psql \"\$DATABASE_URL\" -c \"ALTER TABLE todos ADD COLUMN due_date date;\"'"
```
For anything beyond trivial, adopt a migration tool (Alembic / Flyway) and run it as a deploy step.

**Primary failure (manual failover):**
1. Confirm the primary is truly gone (`ssh` fails, DO console shows it down).
2. Promote a replica: `ssh root@<replica-public-ip> "docker exec -u postgres pg pg_ctl promote -D /var/lib/postgresql/data"`.
3. Point the apps at it: temporarily edit `DATABASE_URL` in `deploy.sh`'s heredoc (use the replica's private IP) and run `deploy/deploy.sh`.
4. Rebuild the old primary as a new replica and reconcile Terraform (`terraform state` surgery or recreate the stack).

This is the weakest part of the VPS design: it works, but it needs a human. **Managed PostgreSQL removes it**; see the optional section at the end of Part 2.

**Secrets:** changing a `random_password` later will *not* change a running database (we ignore `user_data` changes on purpose). To rotate a database password, `ALTER ROLE` it in Postgres by hand, then update the value consistently.

---
# Part 2: Move the API tier to Kubernetes (DOKS)

Do this **after** Part 1 is running and you have real traffic or real reasons: you want autoscaling pods, self-healing, and one-command rollouts instead of SSH loops.

**What changes and what doesn't**

| Stays exactly as is | Moves to Kubernetes |
|---|---|
| VPC, PostgreSQL primary + replicas, Redis, registry, secrets, firewalls | The **API tier** (the app containers) |

The API is stateless and all state lives in Postgres/Redis, so the old droplets and the new pods can **run side by side against the same database and cache**. That lets you migrate with zero data migration and a reversible, gradual traffic shift.

```
Internet ─► DO Load Balancer (created by the Kubernetes Service) ─► pods (autoscaled 4–12) ─┐
Internet ─► old droplet LB ─► api droplets  (until you switch them off)                     ├─► pg-primary / replicas (droplets)
                                                                                             └─► redis (droplet)
```
Pods reach the database droplets over the VPC. The DB firewall already allows the whole VPC range (`var.vpc_cidr`), and DOKS nodes live in that VPC.

## K1. Create the cluster with Terraform

You already wrote `k8s.tf` (it's dormant). Switch it on, in `infra/terraform.tfvars`:
```hcl
enable_k8s    = true
k8s_node_size = "s-2vcpu-4gb"
k8s_min_nodes = 3
k8s_max_nodes = 8
```
```bash
cd infra
terraform plan          # should show ONLY the new cluster (+1 resource); nothing existing should be destroyed
terraform apply         # ~5–10 minutes
terraform output k8s_cluster_id
```
`registry_integration = true` gives the cluster pull access to your private registry. (If your provider version rejects that argument, drop it and run `doctl kubernetes cluster registry add <cluster-name>` once instead.) `auto_scale` with `min_nodes`/`max_nodes` lets DigitalOcean add or remove **servers**; the HPA below adds or removes **pods**.

Install `kubectl` once (`brew install kubectl`).

## K2. The Kubernetes manifest

`deploy/k8s/app.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: todo-api
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }     # never drop below the desired count during a release
  selector:
    matchLabels: { app: todo-api }
  template:
    metadata:
      labels: { app: todo-api }
    spec:
      topologySpreadConstraints:                          # spread pods across nodes
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app: todo-api }
      containers:
        - name: api
          image: __IMAGE__
          ports: [{ containerPort: 8000 }]
          env:
            - { name: WEB_CONCURRENCY, value: "3" }       # workers per pod
          envFrom:
            - secretRef: { name: todo-env }               # DB / Redis / JWT secrets
          resources:
            requests: { cpu: 500m, memory: 256Mi }        # the HPA needs a CPU request to compute utilisation
            limits:   { memory: 512Mi }
          readinessProbe:                                 # only send traffic to pods that answer
            httpGet: { path: /healthz, port: 8000 }
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:                                  # restart pods that hang
            httpGet: { path: /healthz, port: 8000 }
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: todo-api
  annotations:
    service.beta.kubernetes.io/do-loadbalancer-healthcheck-path: "/healthz"
    service.beta.kubernetes.io/do-loadbalancer-size-unit: "2"
spec:
  type: LoadBalancer          # DigitalOcean provisions a real load balancer for this Service
  selector: { app: todo-api }
  ports:
    - { port: 80, targetPort: 8000 }
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: todo-api
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: todo-api }
  minReplicas: 4
  maxReplicas: 12
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
```
| Object | Role |
|---|---|
| **Deployment** | Keeps 4 identical pods alive; replaces crashed ones; performs rolling updates |
| **Service (LoadBalancer)** | Gives the pods one stable address; DigitalOcean builds the external load balancer |
| **HPA** | Scales pods from 4 to 12 to hold ~70% CPU |
| **Secret `todo-env`** | Database/Redis/JWT settings (created by the script below, never stored in git) |

## K3. The Kubernetes deploy script (CLI)

`deploy/k8s-deploy.sh`
```bash
#!/bin/bash
# Usage: deploy/k8s-deploy.sh [image-tag]     Rollback: kubectl rollout undo deployment/todo-api
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${1:-$(git rev-parse --short HEAD)}
OUT=$(terraform -chdir=infra output -json)
get() { echo "$OUT" | jq -r ".$1.value"; }

CLUSTER_ID=$(get k8s_cluster_id)
[ "$CLUSTER_ID" != "null" ] || { echo "enable_k8s is false in terraform.tfvars"; exit 1; }
doctl kubernetes cluster kubeconfig save "$CLUSTER_ID"          # points kubectl at the cluster

IMAGE="$(get registry_endpoint)/todo-api:$TAG"
doctl registry login --expiry-seconds 3600
docker build --platform linux/amd64 -t "$IMAGE" app
docker push "$IMAGE"

DB_PASS=$(get app_db_password)
READ_URLS=$(echo "$OUT" | jq -r --arg p "$DB_PASS" \
  '[.pg_replica_private_ips.value[] | "postgresql://todo:\($p)@\(.):5432/todo"] | join(",")')

# Create or update the Secret (idempotent: --dry-run renders YAML, apply upserts it)
kubectl create secret generic todo-env \
  --from-literal=JWT_SECRET_KEY="$(get jwt_secret)" \
  --from-literal=DATABASE_URL="postgresql://todo:$DB_PASS@$(get pg_primary_private_ip):5432/todo" \
  --from-literal=READ_DATABASE_URL="$READ_URLS" \
  --from-literal=REDIS_URL="redis://:$(get redis_password)@$(get redis_private_ip):6379/0" \
  --dry-run=client -o yaml | kubectl apply -f -

sed "s|__IMAGE__|$IMAGE|" deploy/k8s/app.yaml | kubectl apply -f -
kubectl rollout restart deployment/todo-api >/dev/null 2>&1 || true   # also picks up secret changes
kubectl rollout status deployment/todo-api --timeout=300s
kubectl get svc todo-api
kubectl get hpa todo-api
```
```bash
chmod +x deploy/k8s-deploy.sh
deploy/k8s-deploy.sh
kubectl get svc todo-api -w          # wait until EXTERNAL-IP shows an address (~2 min), then Ctrl-C
kubectl get hpa                      # TARGETS showing <unknown>? metrics-server isn't installed:
# kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

## K4. Test, then shift traffic gradually

1. **Test the Kubernetes endpoint directly.** Edit the first lines of `deploy/smoke-test.sh` so you can override the target:
   ```bash
   LB="${BASE_URL:-http://$(terraform -chdir=infra output -raw lb_ip)}"
   ```
   ```bash
   K8S_IP=$(kubectl get svc todo-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   BASE_URL=http://$K8S_IP deploy/smoke-test.sh
   ```
   Logins created on the droplet stack work here too, because both share the same database and the same `JWT_SECRET_KEY`.
2. **Shift traffic.** Point your DNS name at `$K8S_IP`. For a gradual cut-over, publish **both** load-balancer IPs as A records so roughly half of clients use each; later remove the old one. Lower the DNS TTL beforehand.
3. **Watch for a day.** `kubectl logs -l app=todo-api --tail=50`, `kubectl top pods`, DigitalOcean Monitoring graphs for the database and Redis droplets.
4. **Decommission the old API tier**, in `infra/terraform.tfvars`:
   ```hcl
   api_count = 0
   enable_lb = false
   ```
   `terraform plan` should show only the API droplets, their load balancer (and the DNS record, if you manage one here) being destroyed. Then `terraform apply`. (If you used the `domain` variable, recreate the `api` A record pointing at `$K8S_IP`.)

**Rollback at any point:** `kubectl rollout undo deployment/todo-api` for a bad release; for a bad migration, point DNS back at the droplet load balancer (until you destroy it in step 4).

**HTTPS on Kubernetes:** either add the annotations `service.beta.kubernetes.io/do-loadbalancer-protocol: "https"` and `…-certificate-id: "<DO certificate id>"` to the Service, or install ingress-nginx + cert-manager for automatic Let's Encrypt certificates. The Service-annotation route is the quickest; ingress-nginx is the standard when you will host several services.

## K5 (optional, recommended once on Kubernetes): managed PostgreSQL and Valkey

Your databases are still hand-run droplets. Managed clusters add automatic failover, patching and backups, and they remove the manual-failover weakness described in Part 1. Add to Terraform (new file `infra/managed.tf`):
```hcl
resource "digitalocean_database_cluster" "pg" {
  name                 = "${var.project}-pg"
  engine               = "pg"
  version              = "16"
  size                 = "db-s-2vcpu-4gb"
  region               = var.region
  node_count           = 2                                   # primary + automatic-failover standby
  private_network_uuid = digitalocean_vpc.main.id
}
resource "digitalocean_database_db"   "todo" { cluster_id = digitalocean_database_cluster.pg.id  name = "todo" }
resource "digitalocean_database_user" "app"  { cluster_id = digitalocean_database_cluster.pg.id  name = "todo_app" }

resource "digitalocean_database_replica" "read" {            # a real read-only replica for list queries
  cluster_id           = digitalocean_database_cluster.pg.id
  name                 = "${var.project}-pg-read"
  size                 = "db-s-2vcpu-4gb"
  region               = var.region
  private_network_uuid = digitalocean_vpc.main.id
}

# "Trusted sources": only the Kubernetes cluster and the API droplets may connect
resource "digitalocean_database_firewall" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id
  rule { type = "k8s"  value = digitalocean_kubernetes_cluster.main[0].id }
  rule { type = "tag"  value = digitalocean_tag.api.name }
}

output "managed_pg_private_uri" {
  value     = digitalocean_database_cluster.pg.private_uri
  sensitive = true
}
```
Migrating (maintenance window, a few minutes): scale the API to zero (`kubectl scale deployment/todo-api --replicas=0`), `pg_dump -Fc` from the primary droplet, `pg_restore --no-owner` into the managed `todo` database (host/port/credentials from `terraform output`; managed Postgres listens on port 25060 and requires `?sslmode=require`), grant the `todo_app` user DML rights on the tables and sequences, update `DATABASE_URL`/`READ_DATABASE_URL` in `k8s-deploy.sh`, re-run it, verify, and only then destroy the old database droplets. For the cache, `digitalocean_database_cluster` with `engine = "valkey"` replaces the Redis droplet the same way (the `redis` Python library connects with a `rediss://` URI, no code change). Managed PostgreSQL enforces a connection limit, so if you add many pods, put a `digitalocean_database_connection_pool` in front.

---

# Appendix

## A. Tear everything down (stop billing)
```bash
cd infra
# if you enabled prevent_destroy on the primary, comment it out first
terraform destroy          # lists everything, asks for "yes"
```
Terraform deletes in dependency order (droplets, load balancer, firewalls, registry, VPC last). **All data is deleted**, and container images in the registry go with it. Then check the DigitalOcean **Billing** page. Snapshots/backups you took outside Terraform must be removed by hand. To remove just the Kubernetes cluster: set `enable_k8s = false` and `terraform apply`. If the Service load balancer remains, delete it first with `kubectl delete svc todo-api`.

## B. Terraform command cheat sheet

| Command | Use |
|---|---|
| `terraform init` | Download providers (first run in a folder) |
| `terraform validate` / `fmt` | Check syntax / tidy |
| `terraform plan` | Preview changes. **Read it every time** |
| `terraform apply` | Make the changes |
| `terraform apply -target=RESOURCE` | Apply one resource (rarely; e.g. the DNS zone before HTTPS) |
| `terraform output [-raw NAME \| -json]` | Read outputs (used by the deploy scripts) |
| `terraform state list` | Everything Terraform manages |
| `terraform destroy` | Delete everything |
| `terraform taint` / `apply -replace=ADDR` | Force one resource to be rebuilt |

## C. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Error: Unable to authenticate you` | `DIGITALOCEAN_TOKEN` not exported in this terminal |
| `SSH Key is already in use on your account` | That key is already uploaded; use the `data "digitalocean_ssh_key"` alternative from `network.tf` |
| `registry name already exists` | Names are global; change `registry_name` |
| Can't SSH to a droplet | `admin_cidrs` ≠ your current IP (`curl -s https://api.ipify.org`); fix and `terraform apply` |
| `deploy.sh`: `Permission denied (publickey)` | SSH is offering the wrong key; set `IdentityFile` in `~/.ssh/config` or `ssh -v` to see which key is tried |
| `docker pull` fails on a droplet: `unauthorized` | Registry credentials missing/expired. Check `/root/.docker/config.json`; recreate by `terraform apply -replace=digitalocean_container_registry_docker_credentials.read` and re-run cloud-init, or `doctl registry login` on the droplet |
| Replica droplet has no `pg` container | Bootstrap waiting for the primary. `tail -f /var/log/bootstrap.log` on the replica; check the primary's firewall and that its `pg` container is up |
| `pg_stat_replication` shows 0 rows | Replica not connected: check its log (`docker logs pg`), and that `REPL_PASSWORD` matches (both come from the same Terraform password) |
| Load balancer: all droplets down | App not deployed yet (run `deploy.sh`), or `docker ps` shows `todo-api` crash-looping: `docker logs todo-api` |
| `terraform plan` wants to destroy a droplet | Something outside `user_data`/`image` changed (name, region, VPC). Read carefully; **never apply a surprise destroy on the database** |
| App `readyz` returns 503 | The droplet can't reach the primary: wrong `DATABASE_URL`, DB container down, or DB firewall; test `docker run --rm --env-file /opt/todo/app.env postgres:16 sh -c 'pg_isready -d "$DATABASE_URL"'` |

## D. Cost summary (approximate, verify current prices)

| Item | Qty | ~$/month |
|---|---|---|
| API droplets `s-2vcpu-4gb` | 4 | 96 |
| PostgreSQL primary + 2 replicas `s-4vcpu-8gb` | 3 | 144 |
| Primary weekly backups (+20%) | 1 | 10 |
| Redis `s-1vcpu-2gb` | 1 | 12 |
| Load balancer (2 units) | 1 | 24 |
| Container registry (basic) | 1 | 5 |
| **Total (Part 1)** | | **≈ $290** |
| Part 2 adds | Kubernetes nodes (3 × `s-2vcpu-4gb`) + its load balancer | ≈ $96 + $24, minus what you remove (the API droplets and old LB) |