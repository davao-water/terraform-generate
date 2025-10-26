# Digital Ocean Main Configuration

# Import compute resources from compute directory
module "compute" {
  source = "./compute"
  providers = {
    digitalocean = digitalocean
  }
}

# Import database resources from database directory
module "database" {
  source = "./database"
  providers = {
    digitalocean = digitalocean
  }
}

# Import network resources from network directory
module "network" {
  source = "./network"
  providers = {
    digitalocean = digitalocean
  }
}

# Import storage resources from storage directory
module "storage" {
  source = "./storage"
  providers = {
    digitalocean = digitalocean
  }
}

# Import project resources from project directory
module "project" {
  source = "./project"
  providers = {
    digitalocean = digitalocean
  }
  depends_on = [
    module.compute,
    module.database,
    module.network,
    module.storage
  ]
}
