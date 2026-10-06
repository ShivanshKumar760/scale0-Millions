variable "project" {
  default = "todo"
}

variable "region" {
  default = "blr1" # nearest to you; e.g. nyc3, sfo3, lon1, fra1, sgp1
}

variable "vpc_cidr" {
  default = "10.20.0.0/16" # private network range
}

variable "image" {
  default = "ubuntu-24-04-x64"
}

variable "ssh_public_key_path" {
  default = "~/.ssh/id_ed25519.pub"
}

# Who may SSH to the servers: YOUR public IP as /32. Find it with: curl -s https://api.ipify.org
variable "admin_cidrs" {
  type = list(string)
}

variable "registry_name" {
  type = string # globally unique, e.g. todo-reg-yourname
}

# The container registry is only offered in some regions (e.g. nyc3, sfo3, ams3, fra1, sgp1, syd1).
# If your main region has no registry (blr1 may not), the registry simply lives in a nearby one.
variable "registry_region" {
  default = "sgp1"
}

# --- sizes / counts: the "scale" dials ---
variable "api_count" {
  default = 3
}

variable "api_size" {
  default = "s-2vcpu-4gb"
}

variable "db_size" {
  default = "s-4vcpu-8gb"
}

variable "replica_count" {
  default = 2
}

variable "redis_size" {
  default = "s-1vcpu-2gb"
}

variable "lb_size_unit" {
  default = 2
}

variable "db_backups" {
  default = true # DO weekly whole-droplet backups (+20% price)
}

# --- optional features ---
variable "domain" {
  default = "" # e.g. "example.com" -> api.example.com with HTTPS
}

variable "enable_lb" {
  default = true
}

variable "enable_k8s" {
  default = false # Part 2
}

variable "k8s_node_size" {
  default = "s-2vcpu-4gb"
}

variable "k8s_min_nodes" {
  default = 3
}

variable "k8s_max_nodes" {
  default = 8
}

variable "enable_single_db" {
  default = false # the primary + replicas from Section 4.8. Set false once you run on shards only
}

variable "shard_count" {
  default = 2 # 0 = sharding off. Otherwise 2 or more. PERMANENT once users exist
}

variable "shard_size" {
  default = "s-2vcpu-4gb"
}

variable "shard_index_size" {
  default = "s-1vcpu-2gb"
}

variable "shard_standbys" {
  default = false # true = one hot standby per shard and for the index (doubles the database droplets)
}