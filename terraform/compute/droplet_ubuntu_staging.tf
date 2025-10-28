resource "digitalocean_droplet" "droplet_ubuntu_staging" {
  name   = "ubuntu-staging"
  region = "sgp1"
  size   = "s-1vcpu-1gb"
  image  = "ubuntu-22-04-x64"
  backups = true
  monitoring = true
  vpc_uuid = "9b29c00c-8f5c-4189-8410-e1c0518961cb"
  tags = ["dokploy"]
}
