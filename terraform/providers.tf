terraform {
  cloud {
    organization = "davao-water"

    workspaces {
      name = "do-infra-main"
    }
  }

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.50.0"
    }
  }
}

# We define do_token here so Terraform always has this var.
# Locally:
#   export TF_VAR_do_token="dop_v1_xxx"
# Terraform Cloud:
#   set workspace variable do_token (sensitive=true)
variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
  default     = ""
}

provider "digitalocean" {
  token = var.do_token
}
