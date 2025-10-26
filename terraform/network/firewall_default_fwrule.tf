resource "digitalocean_firewall" "firewall_default_fwrule" {
  name = "Default-FWRule"

  # MANUAL CONFIGURATION REQUIRED:
  # After importing, run:
  #   terraform state show module.network.digitalocean_firewall.firewall_default_fwrule
  # Copy the full inbound_rule/outbound_rule blocks into this file.
}
