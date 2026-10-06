variable "region" {
  default = "blr1"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form, e.g. 203.0.113.9/32"
  type        = string
}

variable "ssh_key_name" {
  description = "Name of the SSH key ALREADY uploaded to DigitalOcean (doctl compute ssh-key list)"
  default     = "testing_ssh"
}

variable "registry_name" {
  description = "Globally unique, lowercase"
  default     = "devops-lab-reg-test"
}

variable "image_tag" {
  default = "1.0"
}

variable "private_droplets" {
  type    = bool
  default = false
}