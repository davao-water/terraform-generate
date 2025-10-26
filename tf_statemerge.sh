#!/bin/bash

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}DigitalOcean Terraform Import Script${NC}"
echo "Creates Terraform folder structure and imports all your DO resources."
echo

# --- Check prerequisites ---
if ! command -v doctl &>/dev/null; then
  echo -e "${YELLOW}Error: doctl command not found.${NC}"
  echo "Install it first: https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

if [ -z "$DIGITALOCEAN_TOKEN" ]; then
  echo -e "${YELLOW}Error: DIGITALOCEAN_TOKEN is not set.${NC}"
  echo 'Run: export DIGITALOCEAN_TOKEN="your_api_token"'
  exit 1
fi

# --- Folder structure ---
mkdir -p terraform/{compute,database,network,storage,project}
cd terraform

# --- Providers for each module ---
for dir in compute database network storage project; do
  cat > $dir/providers.tf << 'EOF'
terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.50.0"
    }
  }
}
EOF
done

# --- Root providers.tf ---
cat > providers.tf << 'EOF'
terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.50.0"
    }
  }
}

provider "digitalocean" {
  # Uses DIGITALOCEAN_TOKEN env var
}
EOF

# --- Root variables.tf ---
cat > variables.tf << 'EOF'
variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}

variable "region" {
  description = "Default DigitalOcean region"
  type        = string
  default     = "sgp1"
}
EOF

# --- Root outputs.tf ---
cat > outputs.tf << 'EOF'
output "droplet_ips" {
  value = module.compute.droplet_ips
}

output "database_hosts" {
  value       = try(module.database.database_hosts, {})
  sensitive   = true
}

output "floating_ips" {
  value = try(module.network.floating_ips, {})
}
EOF

# --- Root main.tf ---
cat > main.tf << 'EOF'
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
EOF

# --- Sanitize name function ---
sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# --- Terraform init ---
echo -e "\n${GREEN}Initializing Terraform...${NC}"
terraform init

########################################
# DROPLETS
########################################
echo -e "\n${GREEN}Importing Droplets...${NC}"
droplets=$(doctl compute droplet list --format ID,Name --no-header)
if [ -z "$droplets" ]; then
  echo "No droplets found."
else
  echo -e "Found $(echo "$droplets" | wc -l) droplets."
  mkdir -p compute

  cat > compute/variables.tf << 'EOF'
variable "region" {
  description = "Droplet region"
  type        = string
  default     = "sgp1"
}
EOF

  cat > compute/outputs.tf << 'EOF'
output "droplet_ips" {
  value = {
EOF
  while IFS= read -r line; do
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/,""); print}')
    safe_name=$(sanitize_name "$name")
    echo "    \"$safe_name\" = digitalocean_droplet.droplet_${safe_name}.ipv4_address" >> compute/outputs.tf
  done <<< "$droplets"
  cat >> compute/outputs.tf << 'EOF'
  }
}
EOF

  # Generate resource files
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/,""); print}')
    safe_name=$(sanitize_name "$name")

    echo "Creating compute/droplet_${safe_name}.tf for $name"
    region=$(doctl compute droplet get "$id" --format Region --no-header)
    size=$(doctl compute droplet get "$id" --format SizeSlug --no-header)
    image=$(doctl compute droplet get "$id" --format Image --no-header)
    tags_raw=$(doctl compute droplet get "$id" --format Tags --no-header)

    if [ "$tags_raw" != "-" ] && [ -n "$tags_raw" ]; then
      tags=$(echo "$tags_raw" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed 's/^/"/;s/$/"/' | paste -sd, -)
    fi

    cat > "compute/droplet_${safe_name}.tf" << EOF
resource "digitalocean_droplet" "droplet_${safe_name}" {
  name   = "${name}"
  region = "${region}"
  size   = "${size}"
  image  = "${image}"
EOF
    [ -n "$tags" ] && echo "  tags = [${tags}]" >> "compute/droplet_${safe_name}.tf"
    echo "}" >> "compute/droplet_${safe_name}.tf"
  done <<< "$droplets"

  # Import
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/,""); print}')
    safe_name=$(sanitize_name "$name")
    tf_addr="module.compute.digitalocean_droplet.droplet_${safe_name}"

    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping droplet ${name} (already imported)"
      continue
    fi

    terraform import "$tf_addr" "$id"
  done <<< "$droplets"
fi

########################################
# DATABASES
########################################
echo -e "\n${GREEN}Importing Database Clusters...${NC}"
dbs=$(doctl databases list --format ID,Name,Engine,Version,Region,NumNodes --no-header)
if [ -z "$dbs" ]; then
  echo "No database clusters found."
else
  echo -e "Found $(echo "$dbs" | wc -l) database clusters."
  mkdir -p database

  cat > database/variables.tf << 'EOF'
variable "region" {
  description = "Database region"
  type        = string
  default     = "sgp1"
}
EOF

  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    engine=$(echo "$line" | awk '{print $3}')
    version=$(echo "$line" | awk '{print $4}')
    region=$(echo "$line" | awk '{print $5}')
    nodes=$(echo "$line" | awk '{print $6}')
    safe_name=$(sanitize_name "$name")

    cat > "database/db_${safe_name}.tf" << EOF
resource "digitalocean_database_cluster" "db_${safe_name}" {
  name       = "${name}"
  engine     = "${engine}"
  version    = "${version}"
  region     = "${region}"
  node_count = ${nodes}
  size       = "db-s-1vcpu-1gb"
}
EOF
  done <<< "$dbs"

  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    tf_addr="module.database.digitalocean_database_cluster.db_${safe_name}"

    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping DB ${name} (already imported)"
      continue
    fi
    terraform import "$tf_addr" "$id"
  done <<< "$dbs"
fi

########################################
# FIREWALLS
########################################
echo -e "\n${GREEN}Importing Firewalls...${NC}"
firewalls=$(doctl compute firewall list --format ID,Name,Status --no-header)
if [ -z "$firewalls" ]; then
  echo "No firewalls found."
else
  echo -e "Found $(echo "$firewalls" | wc -l) firewalls."
  mkdir -p network

  cat > network/variables.tf << 'EOF'
variable "region" {
  description = "Network region"
  type        = string
  default     = "sgp1"
}
EOF

  while IFS= read -r line; do
    fw_id=$(echo "$line" | awk '{print $1}')
    fw_name=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
    safe_name=$(sanitize_name "$fw_name")

    cat > "network/firewall_${safe_name}.tf" << EOF
resource "digitalocean_firewall" "firewall_${safe_name}" {
  name = "${fw_name}"
  # Run 'terraform state show module.network.digitalocean_firewall.firewall_${safe_name}'
  # then update inbound/outbound rules below.
}
EOF
  done <<< "$firewalls"

  while IFS= read -r line; do
    fw_id=$(echo "$line" | awk '{print $1}')
    fw_name=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
    safe_name=$(sanitize_name "$fw_name")
    tf_addr="module.network.digitalocean_firewall.firewall_${safe_name}"

    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping firewall ${fw_name} (already imported)"
      continue
    fi
    terraform import "$tf_addr" "$fw_id"
  done <<< "$firewalls"
fi

########################################
# FINISH
########################################
touch compute/empty_resource.tf database/empty_resource.tf network/empty_resource.tf storage/empty_resource.tf

echo -e "\n${GREEN}Import process complete!${NC}"
terraform state list

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Review all generated TF files."
echo "2. Run: terraform plan"
echo "3. Edit firewall files with actual inbound/outbound rules from 'terraform state show'."
