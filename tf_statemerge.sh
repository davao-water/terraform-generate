#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}DigitalOcean Terraform Import Script (Terraform Cloud compatible)${NC}"
echo "This will generate Terraform config, map existing DigitalOcean resources, and import them into state."
echo

#######################################
# 0. SAFETY / REQUIREMENTS
#######################################

# Check doctl
if ! command -v doctl &>/dev/null; then
  echo -e "${YELLOW}Error: doctl command not found.${NC}"
  echo "Install DigitalOcean CLI first:"
  echo "https://docs.digitalocean.com/reference/doctl/how-to/install/"
  exit 1
fi

# Check jq
if ! command -v jq &>/dev/null; then
  echo -e "${YELLOW}Error: jq command not found.${NC}"
  echo "Please install jq (apt install jq / yum install jq)."
  exit 1
fi

# Check Terraform
if ! command -v terraform &>/dev/null; then
  echo -e "${YELLOW}Error: terraform command not found.${NC}"
  echo "Please install Terraform."
  exit 1
fi

# Create terraform/ structure and enter it
mkdir -p terraform/{compute,database,network,storage,project}
cd terraform

#######################################
# 1. WRITE SHARED PROVIDER / ROOT FILES
#######################################

cat > providers.tf << 'EOF'
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
EOF

# Minimal providers.tf for each module (no backend stanza here)
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

# Root variables.tf
cat > variables.tf << 'EOF'
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
EOF

# Root outputs.tf
cat > outputs.tf << 'EOF'
output "droplet_ips" {
  description = "Public IPv4 of all droplets"
  value       = module.compute.droplet_ips
}

output "database_hosts" {
  description = "Managed database connection hosts"
  value       = try(module.database.database_hosts, {})
  sensitive   = true
}

output "floating_ips" {
  description = "Floating IP addresses"
  value       = try(module.network.floating_ips, {})
}
EOF

# Root main.tf - wire modules
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

#######################################
# Helper for Terraform-style safe names
#######################################
sanitize_name() {
  # lowercase, replace non-alnum with underscores
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

#######################################
# 2. INIT TERRAFORM (hooks up to Terraform Cloud backend)
#######################################
echo -e "\n${GREEN}Initializing Terraform...${NC}"
terraform init

#######################################
# 3. DROPLETS
#######################################
echo -e "\n${GREEN}Importing Droplets...${NC}"

droplet_json=$(doctl compute droplet list --output json)
droplet_count=$(echo "$droplet_json" | jq 'length')

if [ "$droplet_count" -eq 0 ]; then
  echo "No droplets found."
else
  echo -e "Found $droplet_count droplets."
  mkdir -p compute

  # compute/variables.tf
  cat > compute/variables.tf << 'EOF'
variable "region" {
  description = "Droplet region"
  type        = string
  default     = "sgp1"
}
EOF

  # compute/outputs.tf
  cat > compute/outputs.tf << 'EOF'
output "droplet_ips" {
  description = "Droplet public IPv4 addresses"
  value = {
EOF

  # Each droplet becomes an output entry
  for i in $(seq 0 $(("$droplet_count" - 1))); do
    droplet_name=$(echo "$droplet_json" | jq -r ".[$i].name")
    safe_name=$(sanitize_name "$droplet_name")
    echo "    \"${safe_name}\" = digitalocean_droplet.droplet_${safe_name}.ipv4_address" >> compute/outputs.tf
  done

  cat >> compute/outputs.tf << 'EOF'
  }
}
EOF

  echo -e "\n${GREEN}Generating droplet resource files...${NC}"

  # Generate per-droplet tf + import into state
  for i in $(seq 0 $(("$droplet_count" - 1))); do
    droplet_id=$(echo "$droplet_json" | jq -r ".[$i].id")
    droplet_name=$(echo "$droplet_json" | jq -r ".[$i].name")
    region=$(echo "$droplet_json" | jq -r ".[$i].region.slug")
    size_slug=$(echo "$droplet_json" | jq -r ".[$i].size_slug")
    image_slug=$(echo "$droplet_json" | jq -r ".[$i].image.slug")

    # backups = true if there are any backup IDs
    backups=$(echo "$droplet_json" \
      | jq -r ".[$i].backup_ids | length > 0")

    # monitoring is true if "monitoring" is in features[]
    monitoring=$(echo "$droplet_json" \
      | jq -r ".[$i].features | index(\"monitoring\") | if . == null then false else true end")

    # ipv6 is true if "ipv6" is in features[]
    has_ipv6=$(echo "$droplet_json" \
      | jq -r ".[$i].features | index(\"ipv6\") | if . == null then false else true end")

    # Keep the droplet bound to the same VPC
    vpc_uuid=$(echo "$droplet_json" | jq -r ".[$i].vpc_uuid")

    # tags array -> valid HCL/JSON list like ["dokploy","whatever"]
    tags_json=$(echo "$droplet_json" | jq -c ".[$i].tags")

    safe_name=$(sanitize_name "$droplet_name")

    echo "Creating compute/droplet_${safe_name}.tf for $droplet_name"

    cat > "compute/droplet_${safe_name}.tf" << EOF
resource "digitalocean_droplet" "droplet_${safe_name}" {
  name   = "${droplet_name}"
  region = "${region}"
  size   = "${size_slug}"
  image  = "${image_slug}"
EOF

    # Only emit backups if DO actually has backups enabled
    if [ "$backups" = "true" ]; then
      echo "  backups = true" >> "compute/droplet_${safe_name}.tf"
    fi

    # Only emit monitoring if it's enabled in DO
    if [ "$monitoring" = "true" ]; then
      echo "  monitoring = true" >> "compute/droplet_${safe_name}.tf"
    fi

    # Only emit ipv6 if enabled
    if [ "$has_ipv6" = "true" ]; then
      echo "  ipv6 = true" >> "compute/droplet_${safe_name}.tf"
    fi

    # Only emit vpc_uuid if present
    if [ "$vpc_uuid" != "null" ] && [ -n "$vpc_uuid" ]; then
      echo "  vpc_uuid = \"${vpc_uuid}\"" >> "compute/droplet_${safe_name}.tf"
    fi

    # Only emit tags if we actually have tags
    if [ "$tags_json" != "[]" ] && [ "$tags_json" != "null" ]; then
      echo "  tags = ${tags_json}" >> "compute/droplet_${safe_name}.tf"
    fi

    echo "}" >> "compute/droplet_${safe_name}.tf"

    # Import into state unless it's already present
    tf_addr="module.compute.digitalocean_droplet.droplet_${safe_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for $droplet_name (already in state)"
    else
      echo "Importing droplet: $droplet_name (ID: $droplet_id)"
      terraform import "$tf_addr" "$droplet_id"
    fi
  done
fi

#######################################
# 4. MANAGED DATABASES
#######################################
echo -e "\n${GREEN}Importing Database Clusters...${NC}"

db_json=$(doctl databases list --output json)
db_count=$(echo "$db_json" | jq 'length')

if [ "$db_count" -eq 0 ]; then
  echo "No database clusters found."
else
  echo -e "Found $db_count database clusters."
  mkdir -p database

  # database/variables.tf
  cat > database/variables.tf << 'EOF'
variable "region" {
  description = "Database region"
  type        = string
  default     = "sgp1"
}
EOF

  # database/outputs.tf
  cat > database/outputs.tf << 'EOF'
output "database_hosts" {
  description = "Database host addresses"
  value = {
EOF

  for i in $(seq 0 $(("$db_count" - 1))); do
    db_name=$(echo "$db_json" | jq -r ".[$i].name")
    safe_name=$(sanitize_name "$db_name")
    echo "    \"${safe_name}\" = digitalocean_database_cluster.db_${safe_name}.host" >> database/outputs.tf
  done

  cat >> database/outputs.tf << 'EOF'
  }
  sensitive = true
}
EOF

  echo -e "\n${GREEN}Generating database resource files...${NC}"

  for i in $(seq 0 $(("$db_count" - 1))); do
    db_id=$(echo "$db_json" | jq -r ".[$i].id")
    db_name=$(echo "$db_json" | jq -r ".[$i].name")
    db_engine=$(echo "$db_json" | jq -r ".[$i].engine")
    db_version=$(echo "$db_json" | jq -r ".[$i].version")
    db_region=$(echo "$db_json" | jq -r ".[$i].region")
    db_nodes=$(echo "$db_json" | jq -r ".[$i].num_nodes")
    db_size_slug=$(echo "$db_json" | jq -r ".[$i].size_slug")

    safe_name=$(sanitize_name "$db_name")

    cat > "database/db_${safe_name}.tf" << EOF
resource "digitalocean_database_cluster" "db_${safe_name}" {
  name       = "${db_name}"
  engine     = "${db_engine}"
  version    = "${db_version}"
  region     = "${db_region}"
  node_count = ${db_nodes}
  size       = "${db_size_slug}"
}
EOF

    tf_addr="module.database.digitalocean_database_cluster.db_${safe_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for DB ${db_name} (already in state)"
    else
      echo "Importing database cluster: ${db_name} (ID: ${db_id})"
      terraform import "$tf_addr" "$db_id"
    fi
  done
fi

#######################################
# 5. NETWORK (FLOATING IPs + FIREWALLS)
#######################################
echo -e "\n${GREEN}Importing Network (Floating IPs, Firewalls)...${NC}"

mkdir -p network

# network/variables.tf
cat > network/variables.tf << 'EOF'
variable "region" {
  description = "Network region"
  type        = string
  default     = "sgp1"
}
EOF

# Start network/outputs.tf
cat > network/outputs.tf << 'EOF'
output "floating_ips" {
  description = "Floating IP addresses"
  value = {
EOF

#######################################
# Floating IPs
#######################################
fip_json=$(doctl compute floating-ip list --output json)
fip_count=$(echo "$fip_json" | jq 'length')

if [ "$fip_count" -eq 0 ]; then
  echo "No floating IPs found."
else
  echo -e "Found $fip_count floating IPs."

  for i in $(seq 0 $(("$fip_count" - 1))); do
    ip=$(echo "$fip_json"        | jq -r ".[$i].ip")
    region=$(echo "$fip_json"    | jq -r ".[$i].region.slug")
    droplet_id=$(echo "$fip_json"| jq -r ".[$i].droplet.id // empty")

    safe_ip_name=$(echo "$ip" | tr '.' '_')

    echo "Creating network/floating_ip_${safe_ip_name}.tf for $ip"

    cat > "network/floating_ip_${safe_ip_name}.tf" << EOF
resource "digitalocean_floating_ip" "floating_ip_${safe_ip_name}" {
  region = "${region}"
EOF

    if [ -n "$droplet_id" ]; then
      echo "  droplet_id = ${droplet_id}" >> "network/floating_ip_${safe_ip_name}.tf"
    fi

    echo "}" >> "network/floating_ip_${safe_ip_name}.tf"

    # add to outputs
    echo "    \"${safe_ip_name}\" = digitalocean_floating_ip.floating_ip_${safe_ip_name}.ip_address" >> network/outputs.tf

    # import into state
    tf_addr="module.network.digitalocean_floating_ip.floating_ip_${safe_ip_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for Floating IP ${ip} (already in state)"
    else
      echo "Importing Floating IP: ${ip}"
      terraform import "$tf_addr" "$ip"
    fi
  done
fi

# Close floating_ips map
cat >> network/outputs.tf << 'EOF'
  }
}
EOF

#######################################
# Firewalls
#######################################
fw_json=$(doctl compute firewall list --output json)
fw_count=$(echo "$fw_json" | jq 'length')

if [ "$fw_count" -eq 0 ]; then
  echo "No firewalls found."
else
  echo -e "\n${GREEN}Importing Firewalls...${NC}"

  for i in $(seq 0 $(("$fw_count" - 1))); do
    fw_id=$(echo "$fw_json"   | jq -r ".[$i].id")
    fw_name=$(echo "$fw_json" | jq -r ".[$i].name")
    safe_fw_name=$(sanitize_name "$fw_name")

    echo "Creating network/firewall_${safe_fw_name}.tf for firewall ${fw_name}"

    fw_detail=$(doctl compute firewall get "$fw_id" --output json | jq '.[0]')

    fw_droplets_json=$(echo "$fw_detail" | jq -c '.droplet_ids // []')
    inbound_rules=$(echo "$fw_detail" | jq -c '.inbound_rules // []')
    outbound_rules=$(echo "$fw_detail" | jq -c '.outbound_rules // []')

    cat > "network/firewall_${safe_fw_name}.tf" << EOF
resource "digitalocean_firewall" "firewall_${safe_fw_name}" {
  name = "${fw_name}"
EOF

    if [ "$(echo "$fw_droplets_json" | jq 'length')" -gt 0 ]; then
      echo "  droplet_ids = [" >> "network/firewall_${safe_fw_name}.tf"
      echo "$fw_droplets_json" | jq -r '.[]' | while read did; do
        echo "    ${did}," >> "network/firewall_${safe_fw_name}.tf"
      done
      echo "  ]" >> "network/firewall_${safe_fw_name}.tf"
    fi

    # inbound_rule blocks
    in_count=$(echo "$inbound_rules" | jq 'length')
    if [ "$in_count" -gt 0 ]; then
      for j in $(seq 0 $(("$in_count" - 1))); do
        proto=$(echo "$inbound_rules" | jq -r ".[$j].protocol")
        ports=$(echo "$inbound_rules" | jq -r ".[$j].ports // empty")

        src_addrs=$(echo "$inbound_rules" | jq -c ".[$j].sources.addresses // []")
        src_tags=$(echo "$inbound_rules" | jq -c ".[$j].sources.tags // []")

        echo "  inbound_rule {" >> "network/firewall_${safe_fw_name}.tf"
        echo "    protocol   = \"${proto}\"" >> "network/firewall_${safe_fw_name}.tf"
        if [ -n "$ports" ] && [ "$ports" != "null" ]; then
          echo "    port_range = \"${ports}\"" >> "network/firewall_${safe_fw_name}.tf"
        fi

        if [ "$(echo "$src_addrs" | jq 'length')" -gt 0 ]; then
          echo "    source_addresses = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$src_addrs" | jq -r '.[]' | while read addr; do
            echo "      \"${addr}\"," >> "network/firewall_${safe_fw_name}.tf"
          done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi

        if [ "$(echo "$src_tags" | jq 'length')" -gt 0 ]; then
          echo "    source_tags = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$src_tags" | jq -r '.[]' | while read stag; do
            echo "      \"${stag}\"," >> "network/firewall_${safe_fw_name}.tf"
          done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi

        echo "  }" >> "network/firewall_${safe_fw_name}.tf"
      done
    fi

    # outbound_rule blocks
    out_count=$(echo "$outbound_rules" | jq 'length')
    if [ "$out_count" -gt 0 ]; then
      for j in $(seq 0 $(("$out_count" - 1))); do
        proto=$(echo "$outbound_rules" | jq -r ".[$j].protocol")
        ports=$(echo "$outbound_rules" | jq -r ".[$j].ports // empty")

        dst_addrs=$(echo "$outbound_rules" | jq -c ".[$j].destinations.addresses // []")
        dst_tags=$(echo "$outbound_rules" | jq -c ".[$j].destinations.tags // []")

        echo "  outbound_rule {" >> "network/firewall_${safe_fw_name}.tf"
        echo "    protocol   = \"${proto}\"" >> "network/firewall_${safe_fw_name}.tf"
        if [ -n "$ports" ] && [ "$ports" != "null" ]; then
          echo "    port_range = \"${ports}\"" >> "network/firewall_${safe_fw_name}.tf"
        fi

        if [ "$(echo "$dst_addrs" | jq 'length')" -gt 0 ]; then
          echo "    destination_addresses = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$dst_addrs" | jq -r '.[]' | while read addr; do
            echo "      \"${addr}\"," >> "network/firewall_${safe_fw_name}.tf"
          done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi

        if [ "$(echo "$dst_tags" | jq 'length')" -gt 0 ]; then
          echo "    destination_tags = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$dst_tags" | jq -r '.[]' | while read dtag; do
            echo "      \"${dtag}\"," >> "network/firewall_${safe_fw_name}.tf"
          done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi

        echo "  }" >> "network/firewall_${safe_fw_name}.tf"
      done
    fi

    echo "}" >> "network/firewall_${safe_fw_name}.tf"

    # Import firewall into state
    tf_addr="module.network.digitalocean_firewall.firewall_${safe_fw_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for firewall ${fw_name} (already in state)"
    else
      echo "Importing firewall: ${fw_name} (ID: ${fw_id})"
      terraform import "$tf_addr" "$fw_id"
    fi
  done
fi

#######################################
# 6. STORAGE (Volumes, Attachments, Snapshots)
#######################################
echo -e "\n${GREEN}Importing Volumes...${NC}"

vol_json=$(doctl compute volume list --output json)
vol_count=$(echo "$vol_json" | jq 'length')

if [ "$vol_count" -eq 0 ]; then
  echo "No volumes found."
else
  echo -e "Found $vol_count volumes."
  mkdir -p storage

  # storage/variables.tf
  cat > storage/variables.tf << 'EOF'
variable "region" {
  description = "Volume region"
  type        = string
  default     = "sgp1"
}
EOF

  # storage/outputs.tf start
  cat > storage/outputs.tf << 'EOF'
output "volume_ids" {
  description = "Block storage volume IDs"
  value = {
EOF

  # Snapshot list (volume snapshots only)
  snap_json=$(doctl compute snapshot list --output json | jq '[ .[] | select(.resource_type=="volume") ]')
  snap_count=$(echo "$snap_json" | jq 'length')

  echo -e "\n${GREEN}Generating volume resource files...${NC}"

  for i in $(seq 0 $(("$vol_count" - 1))); do
    vol_id=$(echo "$vol_json" | jq -r ".[$i].id")
    vol_name=$(echo "$vol_json" | jq -r ".[$i].name")
    vol_size_gig=$(echo "$vol_json" | jq -r ".[$i].size_gigabytes")
    vol_region=$(echo "$vol_json" | jq -r ".[$i].region.slug")
    vol_droplets_json=$(echo "$vol_json" | jq -c ".[$i].droplet_ids // []")

    safe_name=$(sanitize_name "$vol_name")

    # skip k8s PVC volumes
    if echo "$vol_name" | grep -q "^pvc-"; then
      echo "Skipping Kubernetes-managed volume: $vol_name ($vol_id)"
      continue
    fi

    cat > "storage/volume_${safe_name}.tf" << EOF
resource "digitalocean_volume" "volume_${safe_name}" {
  name   = "${vol_name}"
  region = "${vol_region}"
  size   = ${vol_size_gig}
}
EOF

    # Attach volume if droplets are attached
    if [ "$(echo "$vol_droplets_json" | jq 'length')" -gt 0 ]; then
      echo "$vol_droplets_json" | jq -r '.[]' | while read did; do
        attach_name="${safe_name}_${did}"
        cat > "storage/attachment_${attach_name}.tf" << EOF
resource "digitalocean_volume_attachment" "attachment_${attach_name}" {
  droplet_id = ${did}
  volume_id  = digitalocean_volume.volume_${safe_name}.id
}
EOF
      done
    fi

    # add to outputs
    echo "    \"${safe_name}\" = digitalocean_volume.volume_${safe_name}.id" >> storage/outputs.tf

    # import volume
    tf_addr="module.storage.digitalocean_volume.volume_${safe_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for volume $vol_name (already in state)"
    else
      echo "Importing volume: $vol_name ($vol_id)"
      terraform import "$tf_addr" "$vol_id"
    fi

    # import each volume attachment
    if [ "$(echo "$vol_droplets_json" | jq 'length')" -gt 0 ]; then
      echo "$vol_droplets_json" | jq -r '.[]' | while read did; do
        attach_name="${safe_name}_${did}"
        tf_addr_attach="module.storage.digitalocean_volume_attachment.attachment_${attach_name}"
        if terraform state list | grep -q "^${tf_addr_attach}$"; then
          echo "  -> Skipping attachment import for $vol_name->$did (already in state)"
        else
          echo "Importing volume attachment for volume $vol_name to droplet $did"
          terraform import "$tf_addr_attach" "${did},${vol_id}"
        fi
      done
    fi
  done

  # Close volume_ids map, open snapshot_ids
  cat >> storage/outputs.tf << 'EOF'
  }
}

output "snapshot_ids" {
  description = "Block storage snapshot IDs"
  value = {
EOF

  # snapshots
  if [ "$snap_count" -gt 0 ]; then
    echo -e "\n${GREEN}Generating volume snapshot resource files...${NC}"
    for i in $(seq 0 $(("$snap_count" - 1))); do
      snap_id=$(echo "$snap_json" | jq -r ".[$i].id")
      snap_name=$(echo "$snap_json" | jq -r ".[$i].name")
      src_vol_id=$(echo "$snap_json" | jq -r ".[$i].resource_id")
      safe_snap=$(sanitize_name "$snap_name")

      cat > "storage/snapshot_${safe_snap}.tf" << EOF
resource "digitalocean_volume_snapshot" "snapshot_${safe_snap}" {
  name      = "${snap_name}"
  volume_id = "${src_vol_id}"
}
EOF

      echo "    \"${safe_snap}\" = digitalocean_volume_snapshot.snapshot_${safe_snap}.id" >> storage/outputs.tf

      tf_addr_snap="module.storage.digitalocean_volume_snapshot.snapshot_${safe_snap}"
      if terraform state list | grep -q "^${tf_addr_snap}$"; then
        echo "  -> Skipping import for snapshot ${snap_name} (already in state)"
      else
        echo "Importing snapshot: ${snap_name} (${snap_id})"
        terraform import "$tf_addr_snap" "$snap_id"
      fi
    done
  else
    echo "No volume snapshots found."
  fi

  # close snapshot_ids block
  cat >> storage/outputs.tf << 'EOF'
  }
}
EOF
fi

#######################################
# 7. DUMMY EMPTY RESOURCES
#######################################
# keep module dirs from being "empty"
touch compute/empty_resource.tf database/empty_resource.tf network/empty_resource.tf storage/empty_resource.tf

#######################################
# 8. SUMMARY
#######################################
echo -e "\n${GREEN}Import process complete!${NC}"
echo "Current Terraform state contains:"
terraform state list

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. In Terraform Cloud workspace 'do-infra-main':"
echo "   - Ensure workspace var do_token (Sensitive=true) is set with your DigitalOcean API token."
echo "2. Locally, before running this script:"
echo "   export TF_VAR_do_token=\"<your DO API token>\""
echo "3. Run: terraform plan"
echo "   After this script's fixes:"
echo "   - Droplet should NOT show 'must be replaced' because monitoring/backups/ipv6/vpc_uuid/tags now match DO."
echo "   - Floating IP should NOT show 'will be destroyed'."
echo "   - Firewall should only show harmless in-place diffs."
echo "4. Review generated *.tf and then commit/push (no secrets in repo)."
