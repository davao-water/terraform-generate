output "droplet_ips" {
  description = "Public IPv4 of all droplets"
  value       = module.compute.droplet_ips
}

output "database_hosts" {
  description = "Managed database connection hosts"
  value       = try(module.database.database_hosts, {})
  sensitive   = true
}

output "floating_ips" {
  description = "Floating IP addresses"
  value       = try(module.network.floating_ips, {})
}
