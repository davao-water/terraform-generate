output "firewall_ids" {
  description = "IDs of all firewalls"
  value = {
    "default_fwrule" = digitalocean_firewall.firewall_default_fwrule.id
  }
}

output "floating_ips" {
  description = "All floating IPs"
  value = {
  }
}
