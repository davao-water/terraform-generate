output "droplet_ips" {
  value = {
    "ubuntu_bca01" = digitalocean_droplet.droplet_ubuntu_bca01.ipv4_address
  }
}
