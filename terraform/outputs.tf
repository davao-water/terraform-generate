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

# Just pass through the SSH key maps from compute module
output "ssh_keys_by_safe_name" {
  description = "Map of DO SSH keys: safe_name => {id, name, fingerprint}"
  value       = try(module.compute.ssh_keys_by_safe_name, {})
  sensitive   = true
}

output "ssh_key_fingerprints" {
  description = "Map of DO SSH key fingerprints: safe_name => fingerprint"
  value       = try(module.compute.ssh_key_fingerprints, {})
  sensitive   = true
}
