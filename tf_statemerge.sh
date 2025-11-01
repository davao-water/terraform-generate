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

# Create terraform/ structure and go there
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

# var.do_token is provided either by:
#   - Locally: export TF_VAR_do_token="dop_v1_xxx"
#   - Terraform Cloud: workspace variable do_token (sensitive=true)
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

# Minimal providers.tf per module
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

output "droplet_ids_by_name" {
  description = "Droplet IDs keyed by sanitized droplet names"
  value       = module.compute.droplet_ids_by_name
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

# Just pass through the SSH key maps from compute module
output "ssh_keys_by_safe_name" {
  description = "Map of DO SSH keys: safe_name => {id, name, fingerprint}"
  value       = try(module.compute.ssh_keys_by_safe_name, {})
  sensitive   = true
}

output "ssh_key_fingerprints" {
  description = "Map of DO SSH key fingerprints: safe_name => fingerprint"
  value       = try(module.compute.ssh_key_fingerprints, {})
  sensitive   = true
}
EOF

# Root main.tf (pass droplet_ids_by_name to network)
cat > main.tf << 'EOF'
module "compute" {
  source = "./compute"
}

module "database" {
  source = "./database"
}

module "network" {
  source = "./network"

  # critical: pass droplet IDs map so network module can assign FIPs without hardcoding numeric IDs
  droplet_ids_by_name = module.compute.droplet_ids_by_name
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
# Helper for Terraform-safe names
#######################################
sanitize_name() {
  # lowercase, replace non-alnum with underscores
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

#######################################
# 2. INIT TERRAFORM (connects to TFC backend)
#######################################
echo -e "\n${GREEN}Initializing Terraform...${NC}"
terraform init

#######################################
# 3. SSH KEYS (collect ALL from DO)
#######################################
echo -e "\n${GREEN}Collecting SSH Keys from DigitalOcean...${NC}"

mkdir -p compute
keys_json=$(doctl compute ssh-key list --output json 2>/dev/null || echo "[]")
keys_count=$(echo "$keys_json" | jq 'length')

# Start the file
cat > compute/ssh_keys.tf << 'EOF'
# Auto-generated from doctl list; these are LOOKUPS (data sources), not managed resources.
# We do NOT attach ssh_keys to existing droplets to avoid forced rebuilds.
EOF

if [ "$keys_count" -gt 0 ]; then
  echo "Found $keys_count SSH key(s)."

  # 1) Write all data sources FIRST (top-level) using NAME (provider requires 'name')
  for i in $(seq 0 $(("$keys_count" - 1))); do
    kid=$(echo "$keys_json"   | jq -r ".[$i].ID // .[$i].id")
    kname_raw=$(echo "$keys_json" | jq -r ".[$i].Name // .[$i].name")
    kname_hcl=$(printf '%s' "$kname_raw" | sed 's/\\/\\\\/g; s/"/\\"/g')
    kfp=$(echo "$keys_json"   | jq -r ".[$i].Fingerprint // .[$i].fingerprint")
    safe_k=$(sanitize_name "${kname_raw}_${kid}")

    cat >> compute/ssh_keys.tf << EOF

data "digitalocean_ssh_key" "key_${safe_k}" {
  name = "${kname_hcl}"
}
EOF
  done

  # 2) Then write locals map referencing those data sources (keep metadata for convenience)
  {
    echo
    echo "locals {"
    echo "  do_ssh_keys = {"
  } >> compute/ssh_keys.tf

  for i in $(seq 0 $(("$keys_count" - 1))); do
    kid=$(echo "$keys_json"   | jq -r ".[$i].ID // .[$i].id")
    kname_raw=$(echo "$keys_json" | jq -r ".[$i].Name // .[$i].name")
    kname_hcl=$(printf '%s' "$kname_raw" | sed 's/\\/\\\\/g; s/"/\\"/g')
    kfp=$(echo "$keys_json"   | jq -r ".[$i].Fingerprint // .[$i].fingerprint")
    safe_k=$(sanitize_name "${kname_raw}_${kid}")

    cat >> compute/ssh_keys.tf << EOF
    ${safe_k} = {
      id          = "${kid}"
      name        = "${kname_hcl}"
      fingerprint = "${kfp}"
      data_id     = data.digitalocean_ssh_key.key_${safe_k}.id
    }
EOF
  done

  cat >> compute/ssh_keys.tf << 'EOF'
  }
}
EOF

  # 3) Outputs
  cat >> compute/ssh_keys.tf << 'EOF'

output "ssh_keys_by_safe_name" {
  description = "Map of DO SSH keys: safe_name => {id, name, fingerprint, data_id}"
  value       = local.do_ssh_keys
  sensitive   = true
}

output "ssh_key_fingerprints" {
  description = "Map: safe_name => fingerprint"
  value       = { for k, v in local.do_ssh_keys : k => v.fingerprint }
  sensitive   = true
}
EOF

else
  echo "No SSH keys found in your DO account."
  cat >> compute/ssh_keys.tf << 'EOF'

# No SSH keys found at generation time.
locals {
  do_ssh_keys = {}
}

output "ssh_keys_by_safe_name" {
  value     = local.do_ssh_keys
  sensitive = true
}

output "ssh_key_fingerprints" {
  value     = {}
  sensitive = true
}
EOF
fi

#######################################
# 4. DROPLETS (no ssh_keys injection; ignore_changes guard)
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

  # compute/outputs.tf (start two maps: IPs and IDs)
  cat > compute/outputs.tf << 'EOF'
output "droplet_ips" {
  description = "Droplet public IPv4 addresses"
  value = {
EOF

  echo -e "\n${GREEN}Generating droplet resource files...${NC}"

  for i in $(seq 0 $(("$droplet_count" - 1))); do
    droplet_id=$(echo "$droplet_json" | jq -r ".[$i].id")
    droplet_name=$(echo "$droplet_json" | jq -r ".[$i].name")
    region=$(echo "$droplet_json" | jq -r ".[$i].region.slug")
    size_slug=$(echo "$droplet_json" | jq -r ".[$i].size_slug")
    image_slug=$(echo "$droplet_json" | jq -r ".[$i].image.slug")

    # Features (use .features array; not .backup_ids)
    backups=$(echo "$droplet_json" | jq -r ".[$i].features | index(\"backups\") | if . == null then false else true end")
    monitoring=$(echo "$droplet_json" | jq -r ".[$i].features | index(\"monitoring\") | if . == null then false else true end")
    has_ipv6=$(echo "$droplet_json" | jq -r ".[$i].features | index(\"ipv6\") | if . == null then false else true end")
    vpc_uuid=$(echo "$droplet_json" | jq -r ".[$i].vpc_uuid")
    tags_json=$(echo "$droplet_json" | jq -c ".[$i].tags")

    safe_name=$(sanitize_name "$droplet_name")

    echo "    \"${safe_name}\" = digitalocean_droplet.droplet_${safe_name}.ipv4_address" >> compute/outputs.tf

    echo "Creating compute/droplet_${safe_name}.tf for $droplet_name"

    {
      echo "resource \"digitalocean_droplet\" \"droplet_${safe_name}\" {"
      echo "  name   = \"${droplet_name}\""
      echo "  region = \"${region}\""
      echo "  size   = \"${size_slug}\""
      echo "  image  = \"${image_slug}\""
    } > "compute/droplet_${safe_name}.tf"

    # Do NOT inject ssh_keys for existing droplets (prevents replacement).
    # If you ever want to attach on create-only, you can add conditional logic.

    # Booleans and optional fields
    if [ "$backups" = "true" ]; then
      echo "  backups = true" >> "compute/droplet_${safe_name}.tf"
    fi
    if [ "$monitoring" = "true" ]; then
      echo "  monitoring = true" >> "compute/droplet_${safe_name}.tf"
    fi
    if [ "$has_ipv6" = "true" ]; then
      echo "  ipv6 = true" >> "compute/droplet_${safe_name}.tf"
    fi
    if [ "$vpc_uuid" != "null" ] && [ -n "$vpc_uuid" ]; then
      echo "  vpc_uuid = \"${vpc_uuid}\"" >> "compute/droplet_${safe_name}.tf"
    fi
    if [ "$tags_json" != "[]" ] && [ "$tags_json" != "null" ]; then
      echo "  tags = ${tags_json}" >> "compute/droplet_${safe_name}.tf"
    fi

    # Always ignore changes for ssh_keys/backups to avoid flip-flop/rebuild
    cat >> "compute/droplet_${safe_name}.tf" <<'EOF'
  lifecycle {
    ignore_changes = [
      ssh_keys,
      backups
    ]
  }
EOF

    echo "}" >> "compute/droplet_${safe_name}.tf"

    tf_addr="module.compute.digitalocean_droplet.droplet_${safe_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for $droplet_name (already in state)"
    else
      echo "Importing droplet: $droplet_name (ID: $droplet_id)"
      terraform import "$tf_addr" "$droplet_id"
    fi
  done

  # Close droplet_ips map
  cat >> compute/outputs.tf << 'EOF'
  }
}
EOF

  # Now open droplet_ids_by_name map and fill per droplet
  cat >> compute/outputs.tf << 'EOF'
output "droplet_ids_by_name" {
  description = "Droplet IDs keyed by droplet name (sanitized)"
  value = {
EOF

  for i in $(seq 0 $(("$droplet_count" - 1))); do
    droplet_name=$(echo "$droplet_json" | jq -r ".[$i].name")
    safe_name=$(sanitize_name "$droplet_name")
    echo "    \"${safe_name}\" = digitalocean_droplet.droplet_${safe_name}.id" >> compute/outputs.tf
  done

  cat >> compute/outputs.tf << 'EOF'
  }
}
EOF

fi

#######################################
# 5. MANAGED DATABASES
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
# 6. NETWORK (FLOATING IPs + FIREWALLS)
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

# Map of droplet name (sanitized) -> droplet ID (passed from compute module)
variable "droplet_ids_by_name" {
  description = "Droplet IDs keyed by droplet name (sanitized)"
  type        = map(string)
  default     = {}
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

    # Always: reservation only (no droplet_id) so we can move it freely
    cat > "network/floating_ip_${safe_ip_name}.tf" << EOF
resource "digitalocean_floating_ip" "floating_ip_${safe_ip_name}" {
  region = "${region}"
}
EOF

    # If currently attached, create an assignment resource that points to droplet by NAME (stable across recreate)
    if [ -n "$droplet_id" ]; then
      droplet_name=$(doctl compute droplet get "$droplet_id" --output json | jq -r '.[0].name')
      safe_droplet_name=$(sanitize_name "$droplet_name")

      cat >> "network/floating_ip_${safe_ip_name}.tf" << EOF

resource "digitalocean_floating_ip_assignment" "assign_${safe_ip_name}" {
  ip_address = digitalocean_floating_ip.floating_ip_${safe_ip_name}.ip_address
  droplet_id = var.droplet_ids_by_name["${safe_droplet_name}"]
}
EOF
    fi

    echo "    \"${safe_ip_name}\" = digitalocean_floating_ip.floating_ip_${safe_ip_name}.ip_address" >> network/outputs.tf

    tf_addr="module.network.digitalocean_floating_ip.floating_ip_${safe_ip_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for Floating IP ${ip} (already in state)"
    else
      echo "Importing Floating IP: ${ip}"
      terraform import "$tf_addr" "$ip"
    fi
  done
fi

# Close floating_ips block in outputs.tf
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

    # Attach to droplets if any
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
        ports_raw=$(echo "$inbound_rules" | jq -r ".[$j].ports // \"\"")
        if [ "$ports_raw" = "" ] || [ "$ports_raw" = "null" ] || [ "$ports_raw" = "all" ]; then
          normalized_ports="0"
        else
          normalized_ports="$ports_raw"
        fi
        src_addrs=$(echo "$inbound_rules" | jq -c ".[$j].sources.addresses // []")
        src_tags=$(echo "$inbound_rules" | jq -c ".[$j].sources.tags // []")

        echo "  inbound_rule {" >> "network/firewall_${safe_fw_name}.tf"
        echo "    protocol   = \"${proto}\"" >> "network/firewall_${safe_fw_name}.tf"
        echo "    port_range = \"${normalized_ports}\"" >> "network/firewall_${safe_fw_name}.tf"
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
        ports_raw=$(echo "$outbound_rules" | jq -r ".[$j].ports // \"\"")
        if [ "$ports_raw" = "" ] || [ "$ports_raw" = "null" ] || [ "$ports_raw" = "all" ]; then
          normalized_ports="0"
        else
          normalized_ports="$ports_raw"
        fi
        dst_addrs=$(echo "$outbound_rules" | jq -c ".[$j].destinations.addresses // []")
        dst_tags=$(echo "$outbound_rules" | jq -c ".[$j].destinations.tags // []")

        echo "  outbound_rule {" >> "network/firewall_${safe_fw_name}.tf"
        echo "    protocol   = \"${proto}\"" >> "network/firewall_${safe_fw_name}.tf"
        echo "    port_range = \"${normalized_ports}\"" >> "network/firewall_${safe_fw_name}.tf"
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
# 7. STORAGE (volumes, attachments, snapshots)
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

    # skip DigitalOcean k8s PVC volumes
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

    echo "    \"${safe_name}\" = digitalocean_volume.volume_${safe_name}.id" >> storage/outputs.tf

    tf_addr="module.storage.digitalocean_volume.volume_${safe_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for volume $vol_name (already in state)"
    else
      echo "Importing volume: $vol_name ($vol_id)"
      terraform import "$tf_addr" "$vol_id"
    fi

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

  # close snapshot_ids map
  cat >> storage/outputs.tf << 'EOF'
  }
}
EOF
fi

#######################################
# 8. DUMMY EMPTY RESOURCES
#######################################
touch compute/empty_resource.tf database/empty_resource.tf network/empty_resource.tf storage/empty_resource.tf

#######################################
# 9. SUMMARY
#######################################
echo -e "\n${GREEN}Import process complete!${NC}"
echo "Current Terraform state contains:"
terraform state list

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. In Terraform Cloud workspace 'do-infra-main':"
echo "   - Ensure workspace var do_token (Sensitive=true) is set with your DigitalOcean API token."
echo "2. Locally, before running this script:"
echo "   export TF_VAR_do_token=\"<your DO API token>\""
echo "3. After generation, run: terraform plan"
echo "   Expected now:"
echo "   - SSH keys are discovered via data sources; no new keys are created"
echo "   - Floating IP reservations are stable resources"
echo "   - Floating IP assignment follows droplet by NAME via droplet_ids_by_name map"
echo "   - Droplet files do NOT force replace due to ssh_keys/backups drift"
echo "   - Droplet/Firewall/DB imports should not recreate resources"
echo "4. Commit the generated terraform/ dir (no secrets). That becomes your IaC baseline."
