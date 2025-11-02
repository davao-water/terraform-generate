output "droplet_ips" {
  description = "Public IPv4 of all droplets"
  value       = module.compute.droplet_ips
}

output "droplet_ids_by_name" {
  description = "Droplet IDs keyed by sanitized droplet names"
  value       = module.compute.droplet_ids_by_name
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

# Pass-through SSH key info (sensitive)
output "ssh_keys_by_safe_name" {
  description = "Map of DO SSH keys: safe_name => {id, name, fingerprint, data_id}"
  value       = try(module.compute.ssh_keys_by_safe_name, {})
  sensitive   = true
}

output "ssh_key_fingerprints" {
  description = "List of DO SSH key fingerprints"
  value       = try(module.compute.ssh_key_fingerprints, [])
  sensitive   = true
}
