resource "digitalocean_droplet" "droplet_ubuntu_bca01" {
  name   = "ubuntu-bca01"
  region = "sgp1"
  size   = "s-2vcpu-2gb"
  image  = "Ubuntu 25.04 x64"
  tags = ["dokploy"]
}
