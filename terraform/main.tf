module "compute" {
  source = "./compute"
}

module "database" {
  source = "./database"
}

module "network" {
  source = "./network"
  droplet_ids_by_name = module.compute.droplet_ids_by_name
}

module "storage" {
  source = "./storage"
}

module "project" {
  source = "./project"
  depends_on = [module.compute, module.database, module.network, module.storage]
}
