# Auto-generated from doctl list; these are LOOKUPS (data sources), not managed resources.
# We do NOT attach ssh_keys to existing droplets to avoid forced rebuilds.

data "digitalocean_ssh_key" "key_ryanroman_desktop_t9gj6ol_50859647" {
  name = "ryanroman@DESKTOP-T9GJ6OL"
}

data "digitalocean_ssh_key" "key_dokploy_paas01_50756583" {
  name = "Dokploy-paas01"
}

data "digitalocean_ssh_key" "key_root_ansible_dcwd_gov_ph_50756450" {
  name = "root@ansible.dcwd.gov.ph"
}

data "digitalocean_ssh_key" "key_ryanr_desktop_c2okquy_50730179" {
  name = "ryanr@DESKTOP-C2OKQUY"
}

locals {
  do_ssh_keys = {
    ryanroman_desktop_t9gj6ol_50859647 = {
      id          = "50859647"
      name        = "ryanroman@DESKTOP-T9GJ6OL"
      fingerprint = "29:d1:c4:a2:7c:d8:49:75:54:8e:05:1c:28:56:9e:f3"
      data_id     = data.digitalocean_ssh_key.key_ryanroman_desktop_t9gj6ol_50859647.id
    }
    dokploy_paas01_50756583 = {
      id          = "50756583"
      name        = "Dokploy-paas01"
      fingerprint = "9e:2e:c1:b1:22:e7:bc:c0:9c:84:a7:97:05:d6:e2:5a"
      data_id     = data.digitalocean_ssh_key.key_dokploy_paas01_50756583.id
    }
    root_ansible_dcwd_gov_ph_50756450 = {
      id          = "50756450"
      name        = "root@ansible.dcwd.gov.ph"
      fingerprint = "dd:01:d0:b2:2f:1a:4c:12:91:42:a3:c1:e4:51:2a:04"
      data_id     = data.digitalocean_ssh_key.key_root_ansible_dcwd_gov_ph_50756450.id
    }
    ryanr_desktop_c2okquy_50730179 = {
      id          = "50730179"
      name        = "ryanr@DESKTOP-C2OKQUY"
      fingerprint = "36:8c:a7:fe:07:2a:2a:d8:7a:3f:06:c6:a1:dc:d3:3d"
      data_id     = data.digitalocean_ssh_key.key_ryanr_desktop_c2okquy_50730179.id
    }
  }
}

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
