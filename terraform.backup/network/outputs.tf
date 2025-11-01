output "floating_ips" {
  description = "Floating IP addresses"
  value = {
    "157_230_193_94" = digitalocean_floating_ip.floating_ip_157_230_193_94.ip_address
  }
}
