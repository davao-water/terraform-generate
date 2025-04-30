#!/bin/bash

# Set colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Digital Ocean Infrastructure Import Script (Revised)${NC}"
echo "This script will create a proper folder structure and import all your Digital Ocean resources."
echo

# Check if doctl is installed
if ! command -v doctl &> /dev/null; then
  echo -e "${YELLOW}Error: doctl command not found.${NC}"
  echo "Please install Digital Ocean CLI tool (doctl) first:"
  echo "https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

# Create directory structure
mkdir -p terraform/{compute,database,network,storage,project}
cd terraform

# Create providers.tf in each module directory
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


# Create main.tf
cat > main.tf << 'EOF'
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
EOF

# Copy providers.tf
cat > providers.tf << 'EOF'
terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "2.50.0" 
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.94.1"
    }
  }

  backend "s3" {
    bucket         = "inawo-terraform-state"  
    key            = "digitalocean/terraform.tfstate"         
    region         = "us-east-1"                 
  }
}

provider "digitalocean" {
  # Token set via DIGITALOCEAN_TOKEN environment variable
}

provider "aws" {
  region = "us-east-1"
  # AWS credentials should be set via environment variables
}
EOF

# Create outputs.tf
cat > outputs.tf << 'EOF'
# Main outputs file

output "droplet_ips" {
  description = "IPs of all droplets"
  value       = module.compute.droplet_ips
}

output "database_hosts" {
  description = "Database hosts"
  value       = try(module.database.database_hosts, {})
  sensitive   = true
}

output "floating_ips" {
  description = "All floating IPs"
  value       = try(module.network.floating_ips, {})
}
EOF

# Create variables.tf
cat > variables.tf << 'EOF'
variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "production"
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}
EOF

# Function to sanitize resource names for Terraform
sanitize_name() {
  # Replace spaces and special chars with underscores, convert to lowercase
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# Initialize Terraform
echo -e "\n${GREEN}Initializing Terraform...${NC}"
terraform init


# Import all droplets
echo -e "\n${GREEN}Importing Droplets...${NC}"
droplets=$(doctl compute droplet list --format ID,Name --no-header)

if [ -n "$droplets" ]; then
  echo -e "Found $(echo "$droplets" | wc -l) droplets."
  mkdir -p compute
  
  # Create variables file
  cat > compute/variables.tf << 'EOF'
variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}
EOF

  # Create outputs file
  cat > compute/outputs.tf << 'EOF'
output "droplet_ips" {
  description = "IPs of all droplets"
  value = {
EOF

  while IFS= read -r line; do
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
    safe_name=$(sanitize_name "$name")
    echo "DEBUG: Raw name: '$name', Sanitized name: '$safe_name'" >&2
    echo "    \"${safe_name}\" = digitalocean_droplet.droplet_${safe_name}.ipv4_address" >> compute/outputs.tf
  done <<< "$droplets"

  cat >> compute/outputs.tf << 'EOF'
  }
}

output "droplet_ids" {
  description = "IDs of all droplets"
  value = {
EOF

  while IFS= read -r line; do
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
    safe_name=$(sanitize_name "$name")
    echo "    \"${safe_name}\" = digitalocean_droplet.droplet_${safe_name}.id" >> compute/outputs.tf
  done <<< "$droplets"

  cat >> compute/outputs.tf << 'EOF'
  }
}
EOF

  # Step 1: Create all droplet resource files
  echo -e "\n${GREEN}Generating droplet resource files...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
    safe_name=$(sanitize_name "$name")
    
    echo "Generating resource file for droplet: $name (ID: $id)"
    
    # Get droplet details from default output
    droplet_details=$(doctl compute droplet get "$id" --no-header)
    region=$(echo "$droplet_details" | awk '{print $9}')  # fra1
    memory=$(echo "$droplet_details" | awk '{print $6}')  # e.g., 512, 2048, 4096, 8192
    vcpus=$(echo "$droplet_details" | awk '{print $7}')   # e.g., 1, 2
    
    # Debug output
    echo "DEBUG: Droplet $name - memory=$memory, vcpus=$vcpus, region=$region" >&2
    
    # Map memory and vCPUs to size slug
    case "$memory-$vcpus" in
      "512-1") size="s-1vcpu-512mb" ;;
      "1024-1") size="s-1vcpu-1gb" ;;
      "2048-1") size="s-1vcpu-2gb" ;;
      "4096-2") size="s-2vcpu-4gb" ;;
      "8192-2") size="s-2vcpu-8gb" ;;
      *) size="s-${vcpus}vcpu-$((memory / 1024))gb" ;;  # Fallback
    esac
    
    # Extract image string (fields 10-13: Ubuntu 24.04 (LTS) x64 or Ubuntu 24.10 x64)
    image_full=$(echo "$droplet_details" | awk '{print $10 " " $11 " " $12 " " $13}')
    # Normalize to slug (e.g., ubuntu-24-04-x64)
    image_slug=$(echo "$image_full" | tr '[:upper:]' '[:lower:]' | sed 's/(lts)//g' | sed 's/ //g' | sed 's/\.//g' | sed 's/ubuntu/ubuntu-/')
    
    # Debug image
    echo "DEBUG: Droplet $name - image_full='$image_full', image_slug='$image_slug'" >&2
    
    # Get tags
    tags=$(doctl compute droplet get "$id" --format Tags --no-header)
    if [ "$tags" == "-" ] || [ -z "$tags" ]; then
      formatted_tags=""
    else
      formatted_tags=$(echo "$tags" | sed 's/, */, /g' | sed 's/\([^ ]*\)/"\1"/g' | tr ' ' ', ')
    fi
    
    # Create resource file
    cat > "compute/droplet_${safe_name}.tf" << EOF
resource "digitalocean_droplet" "droplet_${safe_name}" {
  name   = "${name}"
  region = "${region}"
  size   = "${size}"
  image  = "${image_slug}"
EOF

    # Add tags if present
    if [ -n "$formatted_tags" ]; then
      echo "  tags   = [$formatted_tags]" >> "compute/droplet_${safe_name}.tf"
    fi
    
    echo "}" >> "compute/droplet_${safe_name}.tf"
  done <<< "$droplets"

  # Step 2: Import all droplets after resource files are created
  echo -e "\n${GREEN}Importing all droplets...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')
    safe_name=$(sanitize_name "$name")
    
    echo "Importing droplet: $name (ID: $id)"
    if ! terraform import "module.compute.digitalocean_droplet.droplet_${safe_name}" "$id"; then
      echo -e "${YELLOW}Error: Failed to import droplet $name (ID: $id)${NC}" >&2
      exit 1
    fi
  done <<< "$droplets"
else
  echo "No droplets found."
fi



# Import all database clusters
echo -e "\n${GREEN}Importing Database Clusters...${NC}"
dbs=$(doctl databases list --format ID,Name,Engine,Version,Region,NumNodes --no-header)

if [ -n "$dbs" ]; then
  echo -e "Found $(echo "$dbs" | wc -l) database clusters."
  mkdir -p database
  
  # Create variables file
  cat > database/variables.tf << 'EOF'
variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}
EOF

  # Step 1: Create all database resource files
  echo -e "\n${GREEN}Generating database resource files...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    engine=$(echo "$line" | awk '{print $3}')
    version=$(echo "$line" | awk '{print $4}')
    region=$(echo "$line" | awk '{print $5}')
    nodes=$(echo "$line" | awk '{print $6}')
    safe_name=$(sanitize_name "$name")
    
    echo "Generating resource file for database cluster: $name (ID: $id)"
    
    # Create resource file
    cat > "database/db_${safe_name}.tf" << EOF
resource "digitalocean_database_cluster" "db_${safe_name}" {
  name       = "${name}"
  engine     = "${engine}"
  version    = "${version}"
  region     = "${region}"
  node_count = ${nodes}
  size       = "db-s-1vcpu-1gb"  # Update as needed after import
}
EOF
  done <<< "$dbs"

  # Create outputs file after resources are defined
  cat > database/outputs.tf << 'EOF'
output "database_hosts" {
  description = "Database host addresses"
  value = {
EOF

  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    echo "    \"${safe_name}\" = digitalocean_database_cluster.db_${safe_name}.host" >> database/outputs.tf
  done <<< "$dbs"

  cat >> database/outputs.tf << 'EOF'
  }
  sensitive = true
}
EOF

  # Step 2: Import all database clusters
  echo -e "\n${GREEN}Importing all database clusters...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    
    echo "Importing database cluster: $name (ID: $id)"
    if ! terraform import "module.database.digitalocean_database_cluster.db_${safe_name}" "$id"; then
      echo -e "${YELLOW}Error: Failed to import database cluster $name (ID: $id)${NC}" >&2
      exit 1
    fi
  done <<< "$dbs"
else
  echo "No database clusters found."
fi

# Import all firewalls
echo -e "\n${GREEN}Importing Firewalls...${NC}"
firewalls=$(doctl compute firewall list --format ID,Name,Status --no-header)

if [ -n "$firewalls" ]; then
  echo -e "Found $(echo "$firewalls" | wc -l) firewalls."
  mkdir -p network
  
  # Create variables file
  cat > network/variables.tf << 'EOF'
variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}
EOF

  # Step 1: Create all firewall resource files
  echo -e "\n${GREEN}Generating firewall resource files...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    
    echo "Generating resource file for firewall: $name (ID: $id)"
    
    # Create resource file with placeholder
    cat > "network/firewall_${safe_name}.tf" << EOF
resource "digitalocean_firewall" "firewall_${safe_name}" {
  name = "${name}"
  
  # MANUAL CONFIGURATION REQUIRED:
  # After importing, use 'terraform state show module.network.digitalocean_firewall.firewall_${safe_name}'
  # to get the current configuration, then update this file.
  
  # Example inbound rule
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0"]
  }
  
  # Example outbound rule
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0"]
  }
}
EOF
  done <<< "$firewalls"

  # Create outputs file after resources are defined
  cat > network/outputs.tf << 'EOF'
output "firewall_ids" {
  description = "IDs of all firewalls"
  value = {
EOF

  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    echo "    \"${safe_name}\" = digitalocean_firewall.firewall_${safe_name}.id" >> network/outputs.tf
  done <<< "$firewalls"

  cat >> network/outputs.tf << 'EOF'
  }
}

output "floating_ips" {
  description = "All floating IPs"
  value = {
EOF

  if [ -n "$floating_ips" ]; then
    while IFS= read -r line; do
      ip=$(echo "$line" | awk '{print $1}')
      safe_name=$(echo "$ip" | tr '.' '_')
      echo "    \"${safe_name}\" = digitalocean_floating_ip.floating_ip_${safe_name}.ip_address" >> network/outputs.tf
    done <<< "$floating_ips"
  fi

  cat >> network/outputs.tf << 'EOF'
  }
}
EOF

  # Step 2: Import all firewalls
  echo -e "\n${GREEN}Importing all firewalls...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    
    echo "Importing firewall: $name (ID: $id)"
    if ! terraform import "module.network.digitalocean_firewall.firewall_${safe_name}" "$id"; then
      echo -e "${YELLOW}Error: Failed to import firewall $name (ID: $id)${NC}" >&2
      exit 1
    fi
  done <<< "$firewalls"
  
  # Import all floating IPs (unchanged, as it’s working)
  echo -e "\n${GREEN}Importing Floating IPs...${NC}"
  floating_ips=$(doctl compute floating-ip list --format IP,Region,DropletID --no-header)
  
  if [ -n "$floating_ips" ]; then
    echo -e "Found $(echo "$floating_ips" | wc -l) floating IPs."
    
    while IFS= read -r line; do
      ip=$(echo "$line" | awk '{print $1}')
      region=$(echo "$line" | awk '{print $2}')
      droplet_id=$(echo "$line" | awk '{print $3}')
      safe_name=$(echo "$ip" | tr '.' '_')
      
      echo "Processing floating IP: $ip (Region: $region)"
      
      cat > "network/floating_ip_${safe_name}.tf" << EOF
resource "digitalocean_floating_ip" "floating_ip_${safe_name}" {
  region = "${region}"
EOF
      
      if [ "$droplet_id" != "-" ] && [ -n "$droplet_id" ]; then
        echo "  droplet_id = $droplet_id" >> "network/floating_ip_${safe_name}.tf"
      fi
      
      echo "}" >> "network/floating_ip_${safe_name}.tf"
      
      echo "Importing floating IP: $ip"
      if ! terraform import "module.network.digitalocean_floating_ip.floating_ip_${safe_name}" "$ip"; then
        echo -e "${YELLOW}Error: Failed to import floating IP $ip${NC}" >&2
        exit 1
      fi
    done <<< "$floating_ips"
  else
    echo "No floating IPs found."
  fi
else
  echo "No firewalls found."
fi



# Import all volumes
echo -e "\n${GREEN}Importing Volumes...${NC}"
volumes=$(doctl compute volume list --format ID,Name,Size,Region,DropletIDs --no-header)

if [ -n "$volumes" ]; then
  echo -e "Found $(echo "$volumes" | wc -l) volumes."
  mkdir -p storage
  
  # Create variables file
  cat > storage/variables.tf << 'EOF'
variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "fra1"
}
EOF

  # Step 1: Create volume resource files (excluding PVCs)
  echo -e "\n${GREEN}Generating volume resource files...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    size=$(echo "$line" | awk '{print $3}')  # e.g., 10
    region=$(echo "$line" | awk '{print $5}')  # e.g., fra1
    droplet_ids=$(echo "$line" | awk '{print $6}')  # e.g., [487709967]
    safe_name=$(sanitize_name "$name")
    
    # Skip volumes that look like PVCs (starting with "pvc-")
    if echo "$name" | grep -q "^pvc-"; then
      echo "Skipping Kubernetes-managed volume: $name (ID: $id)"
      continue
    fi
    
    echo "Generating resource file for volume: $name (ID: $id)"
    
    # Create volume resource file (without droplet_ids)
    cat > "storage/volume_${safe_name}.tf" << EOF
resource "digitalocean_volume" "volume_${safe_name}" {
  name   = "${name}"
  region = "${region}"
  size   = ${size}
}
EOF
    
    # Create volume attachment resource if droplet_ids exist
    if [ "$droplet_ids" != "-" ] && [ -n "$droplet_ids" ]; then
      clean_droplet_ids=$(echo "$droplet_ids" | tr -d '[]')
      IFS=',' read -r -a droplet_array <<< "$clean_droplet_ids"
      for droplet_id in "${droplet_array[@]}"; do
        attachment_name="${safe_name}_${droplet_id}"
        echo "Generating attachment resource for volume: $name to droplet: $droplet_id"
        
        cat > "storage/attachment_${attachment_name}.tf" << EOF
resource "digitalocean_volume_attachment" "attachment_${attachment_name}" {
  droplet_id = ${droplet_id}
  volume_id  = digitalocean_volume.volume_${safe_name}.id
}
EOF
      done
    fi
  done <<< "$volumes"

  # Step 2: Create snapshot resource files
  echo -e "\n${GREEN}Generating volume snapshot resource files...${NC}"
  snapshots=$(doctl compute snapshot list --format ID,Name,ResourceType,ResourceID --no-header | grep volume)
  if [ -n "$snapshots" ]; then
    echo -e "Found $(echo "$snapshots" | wc -l) volume snapshots."
    while IFS= read -r line; do
      id=$(echo "$line" | awk '{print $1}')
      name=$(echo "$line" | awk '{print $2}')
      volume_id=$(echo "$line" | awk '{print $4}')
      safe_name=$(sanitize_name "$name")
      
      echo "Generating resource file for snapshot: $name (ID: $id)"
      
      cat > "storage/snapshot_${safe_name}.tf" << EOF
resource "digitalocean_volume_snapshot" "snapshot_${safe_name}" {
  name      = "${name}"
  volume_id = "${volume_id}"
}
EOF
    done <<< "$snapshots"
  else
    echo "No volume snapshots found."
  fi

  # Step 3: Create outputs file
  cat > storage/outputs.tf << 'EOF'
output "volume_ids" {
  description = "IDs of all volumes"
  value = {
EOF

  while IFS= read -r line; do
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    # Skip PVCs in outputs
    if echo "$name" | grep -q "^pvc-"; then
      continue
    fi
    echo "    \"${safe_name}\" = digitalocean_volume.volume_${safe_name}.id" >> storage/outputs.tf
  done <<< "$volumes"

  cat >> storage/outputs.tf << 'EOF'
  }
}

output "snapshot_ids" {
  description = "IDs of all volume snapshots"
  value = {
EOF

  if [ -n "$snapshots" ]; then
    while IFS= read -r line; do
      name=$(echo "$line" | awk '{print $2}')
      safe_name=$(sanitize_name "$name")
      echo "    \"${safe_name}\" = digitalocean_volume_snapshot.snapshot_${safe_name}.id" >> storage/outputs.tf
    done <<< "$snapshots"
  fi

  cat >> storage/outputs.tf << 'EOF'
  }
}
EOF

  # Step 4: Import all non-PVC volumes
  echo -e "\n${GREEN}Importing all volumes...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    safe_name=$(sanitize_name "$name")
    
    if echo "$name" | grep -q "^pvc-"; then
      echo "Skipping import of Kubernetes-managed volume: $name (ID: $id)"
      continue
    fi
    
    echo "Importing volume: $name (ID: $id)"
    if ! terraform import "module.storage.digitalocean_volume.volume_${safe_name}" "$id"; then
      echo -e "${YELLOW}Error: Failed to import volume $name (ID: $id)${NC}" >&2
      exit 1
    fi
  done <<< "$volumes"

  # Step 5: Import volume attachments for non-PVC volumes
  echo -e "\n${GREEN}Importing Volume Attachments...${NC}"
  while IFS= read -r line; do
    id=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    droplet_ids=$(echo "$line" | awk '{print $6}')
    safe_name=$(sanitize_name "$name")
    
    if echo "$name" | grep -q "^pvc-"; then
      continue
    fi
    
    if [ "$droplet_ids" != "-" ] && [ -n "$droplet_ids" ]; then
      clean_droplet_ids=$(echo "$droplet_ids" | tr -d '[]')
      IFS=',' read -r -a droplet_array <<< "$clean_droplet_ids"
      for droplet_id in "${droplet_array[@]}"; do
        attachment_name="${safe_name}_${droplet_id}"
        echo "Importing volume attachment for volume: $name to droplet: $droplet_id"
        if ! terraform import "module.storage.digitalocean_volume_attachment.attachment_${attachment_name}" "${droplet_id},${id}"; then
          echo -e "${YELLOW}Error: Failed to import volume attachment for $name to droplet $droplet_id${NC}" >&2
        fi
      done
    fi
  done <<< "$volumes"

  # Step 6: Import all volume snapshots
  echo -e "\n${GREEN}Importing Volume Snapshots...${NC}"
  if [ -n "$snapshots" ]; then
    while IFS= read -r line; do
      id=$(echo "$line" | awk '{print $1}')
      name=$(echo "$line" | awk '{print $2}')
      safe_name=$(sanitize_name "$name")
      
      echo "Importing snapshot: $name (ID: $id)"
      if ! terraform import "module.storage.digitalocean_volume_snapshot.snapshot_${safe_name}" "$id"; then
        echo -e "${YELLOW}Error: Failed to import snapshot $name (ID: $id)${NC}" >&2
      fi
    done <<< "$snapshots"
  else
    echo "No volume snapshots found."
  fi
else
  echo "No volumes found."
fi



# Create empty resources until imports are complete
# This addresses circular dependency during first import
touch compute/empty_resource.tf database/empty_resource.tf network/empty_resource.tf storage/empty_resource.tf

echo -e "\n${GREEN}Import process completed!${NC}"
echo "Terraform structure has been created with all your resources imported."
echo "The following resources were imported:"
terraform state list

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Review the generated configuration files in each directory"
echo "2. Run 'terraform plan' to check if there are any differences"
echo "3. Make any necessary adjustments to the configuration files"
echo "4. Run 'terraform apply' to apply any changes"

echo -e "\n${YELLOW}Note about firewalls:${NC}"
echo "Firewall configurations have placeholder rules. You should:"
echo "1. Run 'terraform state show MODULE.RESOURCE' for each firewall"
echo "2. Copy the actual rules from the state into your configuration file"
