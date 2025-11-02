variable "region" {
  description = "Network region"
  type        = string
  default     = "sgp1"
}

variable "droplet_ids_by_name" {
  description = "Droplet IDs keyed by droplet name (sanitized)"
  type        = map(string)
  default     = {}
}
