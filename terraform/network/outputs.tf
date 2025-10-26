output "firewall_ids" {
  description = "IDs of all firewalls"
  value = {
    "default_fwrule" = digitalocean_firewall.firewall_default_fwrule.id
  }
}

output "floating_ips" {
  description = "All floating IPs"
  value = {
    "157_230_193_94" = digitalocean_floating_ip.floating_ip_157_230_193_94.ip_address
  }
}
