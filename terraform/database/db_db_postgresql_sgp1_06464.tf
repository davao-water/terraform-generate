resource "digitalocean_database_cluster" "db_db_postgresql_sgp1_06464" {
  name       = "db-postgresql-sgp1-06464"
  engine     = "pg"
  version    = "17"
  region     = "sgp1"
  node_count = 1
  size       = "null"
}
