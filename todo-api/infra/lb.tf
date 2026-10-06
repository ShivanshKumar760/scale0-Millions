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
  lifecycle {
    create_before_destroy = true
  }
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