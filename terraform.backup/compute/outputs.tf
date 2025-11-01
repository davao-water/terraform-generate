output "droplet_ips" {
  description = "Droplet public IPv4 addresses"
  value = {
    "ubuntu_staging" = digitalocean_droplet.droplet_ubuntu_staging.ipv4_address
  }
}
