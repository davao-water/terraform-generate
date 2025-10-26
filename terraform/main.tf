module "compute" {
  source = "./compute"
}

module "database" {
  source = "./database"
}

module "network" {
  source = "./network"
}

module "storage" {
  source = "./storage"
}

module "project" {
  source = "./project"
  depends_on = [
    module.compute,
    module.database,
    module.network,
    module.storage
  ]
}
