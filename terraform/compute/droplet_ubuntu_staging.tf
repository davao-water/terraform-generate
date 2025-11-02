resource "digitalocean_droplet" "droplet_ubuntu_staging" {
  name   = "ubuntu-staging"
  region = "sgp1"
  size   = "s-1vcpu-1gb"
  image  = 205106898
  ssh_keys = local.ssh_key_fingerprints
  vpc_uuid    = "9b29c00c-8f5c-4189-8410-e1c0518961cb"
  tags        = ["dokploy"]
  lifecycle {
    ignore_changes = [
      ssh_keys,
      backups
    ]
  }
}
