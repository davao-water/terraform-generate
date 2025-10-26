# Main outputs file

output "droplet_ips" {
  description = "IPs of all droplets"
  value       = module.compute.droplet_ips
}

output "database_hosts" {
  description = "Database hosts"
  value       = try(module.database.database_hosts, {})
  sensitive   = true
}

output "floating_ips" {
  description = "All floating IPs"
  value       = try(module.network.floating_ips, {})
}
