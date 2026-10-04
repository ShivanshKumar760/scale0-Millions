resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_password" "pg_super" {
  length  = 32
  special = false
}

resource "random_password" "app_db" {
  length  = 32
  special = false
}

resource "random_password" "repl" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}