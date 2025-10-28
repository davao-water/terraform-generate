resource "digitalocean_droplet" "droplet_ubuntu_bca01" {
  name   = "ubuntu-bca01"
  region = "sgp1"
  size   = "s-2vcpu-2gb"
  image  = "ubuntu-25-04-x64"
  backups = true
  monitoring = true
  vpc_uuid = "9b29c00c-8f5c-4189-8410-e1c0518961cb"
  tags = ["dokploy"]
}
