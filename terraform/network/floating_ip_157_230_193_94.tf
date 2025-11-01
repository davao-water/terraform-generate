resource "digitalocean_floating_ip" "floating_ip_157_230_193_94" {
  region = "sgp1"
}

resource "digitalocean_floating_ip_assignment" "assign_157_230_193_94" {
  ip_address = digitalocean_floating_ip.floating_ip_157_230_193_94.ip_address
  droplet_id = var.droplet_ids_by_name["ubuntu_staging"]
}
