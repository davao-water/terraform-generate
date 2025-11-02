#!/bin/bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}DigitalOcean Terraform Import Script (Terraform Cloud compatible)${NC}"
echo "This will generate Terraform config, map existing DigitalOcean resources, and import them into state."
echo

need() { command -v "$1" >/dev/null 2>&1 || { echo -e "${YELLOW}Error: $1 not found.${NC}"; exit 1; }; }
need doctl
need jq
need terraform

# Create terraform structure
mkdir -p terraform/{compute,database,network,storage,project}
cd terraform

#######################################
# Root files
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

for dir in compute database network storage project; do
  cat > "$dir/providers.tf" << 'EOF'
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

# Pass-through SSH key info (sensitive)
output "ssh_keys_by_safe_name" {
  description = "Map of DO SSH keys: safe_name => {id, name, fingerprint, data_id}"
  value       = try(module.compute.ssh_keys_by_safe_name, {})
  sensitive   = true
}

output "ssh_key_fingerprints" {
  description = "List of DO SSH key fingerprints"
  value       = try(module.compute.ssh_key_fingerprints, [])
  sensitive   = true
}
EOF

cat > main.tf << 'EOF'
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
EOF

#######################################
# Helpers
#######################################
sanitize_name() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'; }

#######################################
# Init
#######################################
echo -e "\n${GREEN}Initializing Terraform...${NC}"
terraform init -input=false

#######################################
# SSH KEYS
#######################################
echo -e "\n${GREEN}Collecting SSH Keys from DigitalOcean...${NC}"
mkdir -p compute
keys_json=$(doctl compute ssh-key list --output json 2>/dev/null || echo "[]")
keys_count=$(echo "$keys_json" | jq 'length')

cat > compute/ssh_keys.tf << 'EOF'
# DO SSH keys as data sources (looked up by name).
# We attach all fingerprints on CREATE via local.ssh_key_fingerprints, but ignore later to avoid replacements.
EOF

if [ "$keys_count" -gt 0 ]; then
  echo "Found $keys_count SSH key(s)."
  for i in $(seq 0 $((keys_count - 1))); do
    kid=$(echo "$keys_json"    | jq -r ".[$i].ID // .[$i].id")
    kname_raw=$(echo "$keys_json" | jq -r ".[$i].Name // .[$i].name")
    kname_hcl=$(printf '%s' "$kname_raw" | sed 's/\\/\\\\/g; s/\"/\\\"/g')
    safe_k=$(sanitize_name "${kname_raw}_${kid}")
    cat >> compute/ssh_keys.tf << EOF

data "digitalocean_ssh_key" "key_${safe_k}" {
  name = "${kname_hcl}"
}
EOF
  done

  {
    echo
    echo "locals {"
    echo "  do_ssh_keys = {"
  } >> compute/ssh_keys.tf

  for i in $(seq 0 $((keys_count - 1))); do
    kid=$(echo "$keys_json"    | jq -r ".[$i].ID // .[$i].id")
    kname_raw=$(echo "$keys_json" | jq -r ".[$i].Name // .[$i].name")
    kname_hcl=$(printf '%s' "$kname_raw" | sed 's/\\/\\\\/g; s/\"/\\\"/g')
    kfp=$(echo "$keys_json"    | jq -r ".[$i].Fingerprint // .[$i].fingerprint")
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
  ssh_key_fingerprints = [for _, v in local.do_ssh_keys : v.fingerprint]
}
EOF

  cat >> compute/ssh_keys.tf << 'EOF'

output "ssh_keys_by_safe_name" {
  description = "Map of DO SSH keys: safe_name => {id, name, fingerprint, data_id}"
  value       = local.do_ssh_keys
  sensitive   = true
}

output "ssh_key_fingerprints" {
  description = "List of DO SSH key fingerprints"
  value       = local.ssh_key_fingerprints
  sensitive   = true
}
EOF

else
  echo "No SSH keys found in your DO account."
  cat >> compute/ssh_keys.tf << 'EOF'

locals {
  do_ssh_keys          = {}
  ssh_key_fingerprints = []
}

output "ssh_keys_by_safe_name" {
  value     = local.do_ssh_keys
  sensitive = true
}

output "ssh_key_fingerprints" {
  value     = local.ssh_key_fingerprints
  sensitive = true
}
EOF
fi

#######################################
# DROPLETS
#######################################
echo -e "\n${GREEN}Importing Droplets...${NC}"
droplet_json=$(doctl compute droplet list --output json)
droplet_count=$(echo "$droplet_json" | jq 'length')

if [ "$droplet_count" -eq 0 ]; then
  echo "No droplets found."
else
  echo -e "Found $droplet_count droplets."

  cat > compute/variables.tf << 'EOF'
variable "region" {
  description = "Droplet region"
  type        = string
  default     = "sgp1"
}
EOF

  cat > compute/outputs.tf << 'EOF'
output "droplet_ips" {
  description = "Droplet public IPv4 addresses"
  value = {
EOF

  for i in $(seq 0 $((droplet_count - 1))); do
    droplet_id=$(echo "$droplet_json"   | jq -r ".[$i].id")
    droplet_name=$(echo "$droplet_json" | jq -r ".[$i].name")
    region=$(echo "$droplet_json"       | jq -r ".[$i].region.slug")
    size_slug=$(echo "$droplet_json"    | jq -r ".[$i].size_slug")

    # Image slug/ID fallback (avoid "null")
    image_slug=$(echo "$droplet_json" | jq -r ".[$i].image.slug // empty")
    image_id=$(echo "$droplet_json"   | jq -r ".[$i].image.id   // empty")
    if [ -n "$image_slug" ] && [ "$image_slug" != "null" ]; then
      image_expr="  image  = \"${image_slug}\""
    elif [ -n "$image_id" ] && [ "$image_id" != "null" ]; then
      image_expr="  image  = ${image_id}"
    else
      image_expr="  image  = \"ubuntu-24-04-x64\""
    fi

    backups=$(echo "$droplet_json"      | jq -r ".[$i].features | index(\"backups\") | if . == null then false else true end")
    monitoring=$(echo "$droplet_json"   | jq -r ".[$i].features | index(\"monitoring\") | if . == null then false else true end")
    has_ipv6=$(echo "$droplet_json"     | jq -r ".[$i].features | index(\"ipv6\") | if . == null then false else true end")
    vpc_uuid=$(echo "$droplet_json"     | jq -r ".[$i].vpc_uuid")
    tags_json=$(echo "$droplet_json"    | jq -c ".[$i].tags")

    safe_name=$(sanitize_name "$droplet_name")

    echo "    \"${safe_name}\" = digitalocean_droplet.droplet_${safe_name}.ipv4_address" >> compute/outputs.tf

    {
      echo "resource \"digitalocean_droplet\" \"droplet_${safe_name}\" {"
      echo "  name   = \"${droplet_name}\""
      echo "  region = \"${region}\""
      echo "  size   = \"${size_slug}\""
      echo "$image_expr"
      echo "  ssh_keys = local.ssh_key_fingerprints"
    } > "compute/droplet_${safe_name}.tf"

    [ "$backups" = "true" ]     && echo "  backups     = true" >> "compute/droplet_${safe_name}.tf"
    [ "$monitoring" = "true" ]  && echo "  monitoring  = true" >> "compute/droplet_${safe_name}.tf"
    [ "$has_ipv6" = "true" ]    && echo "  ipv6        = true" >> "compute/droplet_${safe_name}.tf"
    if [ "$vpc_uuid" != "null" ] && [ -n "$vpc_uuid" ]; then
      echo "  vpc_uuid    = \"${vpc_uuid}\"" >> "compute/droplet_${safe_name}.tf"
    fi
    if [ "$tags_json" != "[]" ] && [ "$tags_json" != "null" ]; then
      echo "  tags        = ${tags_json}" >> "compute/droplet_${safe_name}.tf"
    fi

    cat >> "compute/droplet_${safe_name}.tf" <<'EOF'
  lifecycle {
    ignore_changes = [
      ssh_keys,
      backups
    ]
  }
}
EOF

    tf_addr="module.compute.digitalocean_droplet.droplet_${safe_name}"
    if terraform state list | grep -q "^${tf_addr}$"; then
      echo "  -> Skipping import for $droplet_name (already in state)"
    else
      echo "Importing droplet: $droplet_name (ID: $droplet_id) -> $tf_addr"
      if ! terraform import "$tf_addr" "$droplet_id"; then
        echo -e "${YELLOW}WARN: terraform import failed for ${droplet_name}. Run manually:\n  terraform import ${tf_addr} ${droplet_id}${NC}"
      fi
    fi
  done

  cat >> compute/outputs.tf << 'EOF'
  }
}
EOF

  cat >> compute/outputs.tf << 'EOF'
output "droplet_ids_by_name" {
  description = "Droplet IDs keyed by droplet name (sanitized)"
  value = {
EOF

  for i in $(seq 0 $((droplet_count - 1))); do
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
# DATABASES
#######################################
echo -e "\n${GREEN}Importing Database Clusters...${NC}"
db_json=$(doctl databases list --output json)
db_count=$(echo "$db_json" | jq 'length')

if [ "$db_count" -eq 0 ]; then
  echo "No database clusters found."
else
  echo -e "Found $db_count database clusters."
  mkdir -p database

  cat > database/variables.tf << 'EOF'
variable "region" {
  description = "Database region"
  type        = string
  default     = "sgp1"
}
EOF

  cat > database/outputs.tf << 'EOF'
output "database_hosts" {
  description = "Database host addresses"
  value = {
EOF

  for i in $(seq 0 $((db_count - 1))); do
    db_name=$(echo "$db_json" | jq -r ".[$i].name")
    echo "    \"$(sanitize_name "$db_name")\" = digitalocean_database_cluster.db_$(sanitize_name "$db_name").host" >> database/outputs.tf
  done

  cat >> database/outputs.tf << 'EOF'
  }
  sensitive = true
}
EOF

  echo -e "\n${GREEN}Generating database resource files...${NC}"
  for i in $(seq 0 $((db_count - 1))); do
    db_id=$(echo "$db_json"      | jq -r ".[$i].id")
    db_name=$(echo "$db_json"    | jq -r ".[$i].name")
    db_engine=$(echo "$db_json"  | jq -r ".[$i].engine")
    db_version=$(echo "$db_json" | jq -r ".[$i].version")
    db_region=$(echo "$db_json"  | jq -r ".[$i].region")
    db_nodes=$(echo "$db_json"   | jq -r ".[$i].num_nodes")
    db_size_slug=$(echo "$db_json"| jq -r ".[$i].size_slug")

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
      terraform import "$tf_addr" "$db_id" || echo -e "${YELLOW}WARN: import failed for DB ${db_name}${NC}"
    fi
  done
fi

#######################################
# NETWORK (FIPs + Firewalls)
#######################################
echo -e "\n${GREEN}Importing Network (Floating IPs, Firewalls)...${NC}"
mkdir -p network

cat > network/variables.tf << 'EOF'
variable "region" {
  description = "Network region"
  type        = string
  default     = "sgp1"
}

variable "droplet_ids_by_name" {
  description = "Droplet IDs keyed by droplet name (sanitized)"
  type        = map(string)
  default     = {}
}
EOF

cat > network/outputs.tf << 'EOF'
output "floating_ips" {
  description = "Floating IP addresses"
  value = {
EOF

# Floating IPs
fip_json=$(doctl compute floating-ip list --output json)
fip_count=$(echo "$fip_json" | jq 'length')

if [ "$fip_count" -eq 0 ]; then
  echo "No floating IPs found."
else
  echo -e "Found $fip_count floating IPs."
  for i in $(seq 0 $((fip_count - 1))); do
    ip=$(echo "$fip_json"        | jq -r ".[$i].ip")
    region=$(echo "$fip_json"    | jq -r ".[$i].region.slug")
    droplet_id=$(echo "$fip_json"| jq -r ".[$i].droplet.id // empty")

    safe_ip_name=$(echo "$ip" | tr '.' '_')
    echo "Creating network/floating_ip_${safe_ip_name}.tf for $ip"

    cat > "network/floating_ip_${safe_ip_name}.tf" << EOF
resource "digitalocean_floating_ip" "floating_ip_${safe_ip_name}" {
  region = "${region}"
}
EOF

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
      terraform import "$tf_addr" "$ip" || echo -e "${YELLOW}WARN: import failed for FIP ${ip}${NC}"
    fi
  done
fi

cat >> network/outputs.tf << 'EOF'
  }
}
EOF

# Firewalls
fw_json=$(doctl compute firewall list --output json)
fw_count=$(echo "$fw_json" | jq 'length')

if [ "$fw_count" -eq 0 ]; then
  echo "No firewalls found."
else
  echo -e "\n${GREEN}Importing Firewalls...${NC}"
  for i in $(seq 0 $((fw_count - 1))); do
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

    in_count=$(echo "$inbound_rules" | jq 'length')
    if [ "$in_count" -gt 0 ]; then
      for j in $(seq 0 $((in_count - 1))); do
        proto=$(echo "$inbound_rules" | jq -r ".[$j].protocol")
        ports_raw=$(echo "$inbound_rules" | jq -r ".[$j].ports // \"\"")
        [ -z "$ports_raw" ] || [ "$ports_raw" = "null" ] || [ "$ports_raw" = "all" ] && normalized_ports="0" || normalized_ports="$ports_raw"
        src_addrs=$(echo "$inbound_rules" | jq -c ".[$j].sources.addresses // []")
        src_tags=$(echo "$inbound_rules" | jq -c ".[$j].sources.tags // []")

        {
          echo "  inbound_rule {"
          echo "    protocol   = \"${proto}\""
          echo "    port_range = \"${normalized_ports}\""
        } >> "network/firewall_${safe_fw_name}.tf"

        if [ "$(echo "$src_addrs" | jq 'length')" -gt 0 ]; then
          echo "    source_addresses = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$src_addrs" | jq -r '.[]' | while read addr; do echo "      \"${addr}\"," >> "network/firewall_${safe_fw_name}.tf"; done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi
        if [ "$(echo "$src_tags" | jq 'length')" -gt 0 ]; then
          echo "    source_tags = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$src_tags" | jq -r '.[]' | while read stag; do echo "      \"${stag}\"," >> "network/firewall_${safe_fw_name}.tf"; done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi
        echo "  }" >> "network/firewall_${safe_fw_name}.tf"
      done
    fi

    out_count=$(echo "$outbound_rules" | jq 'length')
    if [ "$out_count" -gt 0 ]; then
      for j in $(seq 0 $((out_count - 1))); do
        proto=$(echo "$outbound_rules" | jq -r ".[$j].protocol")
        ports_raw=$(echo "$outbound_rules" | jq -r ".[$j].ports // \"\"")
        [ -z "$ports_raw" ] || [ "$ports_raw" = "null" ] || [ "$ports_raw" = "all" ] && normalized_ports="0" || normalized_ports="$ports_raw"
        dst_addrs=$(echo "$outbound_rules" | jq -c ".[$j].destinations.addresses // []")
        dst_tags=$(echo "$outbound_rules" | jq -c ".[$j].destinations.tags // []")

        {
          echo "  outbound_rule {"
          echo "    protocol   = \"${proto}\""
          echo "    port_range = \"${normalized_ports}\""
        } >> "network/firewall_${safe_fw_name}.tf"

        if [ "$(echo "$dst_addrs" | jq 'length')" -gt 0 ]; then
          echo "    destination_addresses = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$dst_addrs" | jq -r '.[]' | while read addr; do echo "      \"${addr}\"," >> "network/firewall_${safe_fw_name}.tf"; done
          echo "    ]" >> "network/firewall_${safe_fw_name}.tf"
        fi
        if [ "$(echo "$dst_tags" | jq 'length')" -gt 0 ]; then
          echo "    destination_tags = [" >> "network/firewall_${safe_fw_name}.tf"
          echo "$dst_tags" | jq -r '.[]' | while read dtag; do echo "      \"${dtag}\"," >> "network/firewall_${safe_fw_name}.tf"; done
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
      terraform import "$tf_addr" "$fw_id" || echo -e "${YELLOW}WARN: import failed for FW ${fw_name}${NC}"
    fi
  done
fi

#######################################
# STORAGE
#######################################
echo -e "\n${GREEN}Importing Volumes...${NC}"
vol_json=$(doctl compute volume list --output json)
vol_count=$(echo "$vol_json" | jq 'length')

if [ "$vol_count" -eq 0 ]; then
  echo "No volumes found."
else
  echo -e "Found $vol_count volumes."
  mkdir -p storage

  cat > storage/variables.tf << 'EOF'
variable "region" {
  description = "Volume region"
  type        = string
  default     = "sgp1"
}
EOF

  cat > storage/outputs.tf << 'EOF'
output "volume_ids" {
  description = "Block storage volume IDs"
  value = {
EOF

  snap_json=$(doctl compute snapshot list --output json | jq '[ .[] | select(.resource_type=="volume") ]')
  snap_count=$(echo "$snap_json" | jq 'length')

  for i in $(seq 0 $((vol_count - 1))); do
    vol_id=$(echo "$vol_json"        | jq -r ".[$i].id")
    vol_name=$(echo "$vol_json"      | jq -r ".[$i].name")
    vol_size_gig=$(echo "$vol_json"  | jq -r ".[$i].size_gigabytes")
    vol_region=$(echo "$vol_json"    | jq -r ".[$i].region.slug")
    vol_droplets_json=$(echo "$vol_json" | jq -c ".[$i].droplet_ids // []")

    safe_name=$(sanitize_name "$vol_name")
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
      terraform import "$tf_addr" "$vol_id" || echo -e "${YELLOW}WARN: import failed for volume ${vol_name}${NC}"
    fi

    if [ "$(echo "$vol_droplets_json" | jq 'length')" -gt 0 ]; then
      echo "$vol_droplets_json" | jq -r '.[]' | while read did; do
        attach_name="${safe_name}_${did}"
        tf_addr_attach="module.storage.digitalocean_volume_attachment.attachment_${attach_name}"
        if terraform state list | grep -q "^${tf_addr_attach}$"; then
          echo "  -> Skipping attachment import for $vol_name->$did (already in state)"
        else
          echo "Importing volume attachment for volume $vol_name to droplet $did"
          terraform import "$tf_addr_attach" "${did},${vol_id}" || echo -e "${YELLOW}WARN: import failed for attachment ${attach_name}${NC}"
        fi
      done
    fi
  done

  cat >> storage/outputs.tf << 'EOF'
  }
}

output "snapshot_ids" {
  description = "Block storage snapshot IDs"
  value = {
EOF

  if [ "$snap_count" -gt 0 ]; then
    for i in $(seq 0 $((snap_count - 1))); do
      snap_id=$(echo "$snap_json"   | jq -r ".[$i].id")
      snap_name=$(echo "$snap_json" | jq -r ".[$i].name")
      src_vol_id=$(echo "$snap_json"| jq -r ".[$i].resource_id")
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
        terraform import "$tf_addr_snap" "$snap_id" || echo -e "${YELLOW}WARN: import failed for snapshot ${snap_name}${NC}"
      fi
    done
  else
    echo "No volume snapshots found."
  fi

  cat >> storage/outputs.tf << 'EOF'
  }
}
EOF
fi

#######################################
# Finalize
#######################################
touch compute/empty_resource.tf database/empty_resource.tf network/empty_resource.tf storage/empty_resource.tf

echo -e "\n${GREEN}Import process complete!${NC}"
echo "Current Terraform state contains:"
terraform state list || true

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1) Set TFC workspace var do_token (Sensitive=true) with your DO token."
echo "2) export TF_VAR_do_token=\"<your DO API token>\" if planning locally."
echo "3) Run: terraform plan"
echo "   - Droplets: creates get your DO SSH keys; imports won't be replaced due to ignore_changes."
echo "   - FIPs: reservations + assignment follow droplet by NAME via droplet_ids_by_name."
echo "4) Commit the generated terraform/ dir (no secrets)."
