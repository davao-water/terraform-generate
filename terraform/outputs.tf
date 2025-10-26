output "droplet_ips" {
  value = module.compute.droplet_ips
}

output "database_hosts" {
  value       = try(module.database.database_hosts, {})
  sensitive   = true
}

output "floating_ips" {
  value = try(module.network.floating_ips, {})
}
