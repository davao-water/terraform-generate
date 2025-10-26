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

provider "digitalocean" {
  token = var.do_token
}
