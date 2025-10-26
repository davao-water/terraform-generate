variable "environment" {
  description = "Deployment environment (ex: production, staging)"
  type        = string
  default     = "production"
}

variable "region" {
  description = "Default DigitalOcean region"
  type        = string
  default     = "sgp1"
}
