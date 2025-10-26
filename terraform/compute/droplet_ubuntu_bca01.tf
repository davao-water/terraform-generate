resource "digitalocean_droplet" "droplet_ubuntu_bca01" {
  name   = "ubuntu-bca01"
  region = "Ubuntu"
  size   = "s-60vcpu-0gb"
  image  = "2504x649b29c00c-8f5c-4189-8410-e1c0518961cbactive"
  tags   = ["dokploy"]
}
