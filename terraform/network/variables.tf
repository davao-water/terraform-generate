variable "region" {
  description = "Network region"
  type        = string
  default     = "sgp1"
}

# Map of droplet name (sanitized) -> droplet ID (passed from compute module)
variable "droplet_ids_by_name" {
  description = "Droplet IDs keyed by droplet name (sanitized)"
  type        = map(string)
  default     = {}
}
