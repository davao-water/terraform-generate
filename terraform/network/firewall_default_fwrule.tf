resource "digitalocean_firewall" "firewall_default_fwrule" {
  name = "Default-FWRule"
  
  # MANUAL CONFIGURATION REQUIRED:
  # After importing, use 'terraform state show module.network.digitalocean_firewall.firewall_default_fwrule'
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
