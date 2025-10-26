output "droplet_ips" {
  description = "IPs of all droplets"
  value = {
    "ubuntu_bca01" = digitalocean_droplet.droplet_ubuntu_bca01.ipv4_address
  }
}

output "droplet_ids" {
  description = "IDs of all droplets"
  value = {
    "ubuntu_bca01" = digitalocean_droplet.droplet_ubuntu_bca01.id
  }
}
