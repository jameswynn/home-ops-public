# Wave 12 — inert system services. Nothing here forwards, filters or resolves
# traffic; these are the knobs that decide how the IP stack behaves and which
# side services run. All imported as found.
#
# Two things this wave set out to manage are missing, both provider limitations
# at v1.99.1 (the newest release) rather than choices — see BOOTSTRAP.md Wave 12:
#
#   /ip/service                       routeros_ip_service imports empty
#   /ip/neighbor/discovery-settings   import wants a .id the endpoint lacks
#
# So issue #1524 stays a manual change. That matters more than it looks: telnet,
# ftp and plain www are all enabled on this router, which #1524 states they are
# not.

# Global IPv4 stack settings.
#
# `rp_filter = "no"` and `tcp_syncookies = false` are both RouterOS defaults
# rather than local choices. Neither is changed here — reverse-path filtering
# interacts with the asymmetric paths BGP can produce, so it is not a free win.
resource "routeros_ip_settings" "this" {
  accept_redirects    = false
  accept_source_route = false
  allow_fast_path     = true
  arp_timeout         = "30s"
  ip_forward          = true
  rp_filter           = "no"
  secure_redirects    = true
  send_redirects      = true
  tcp_syncookies      = false
  tcp_timestamps      = "random-offset"

  icmp_errors_use_inbound_interface_address = false
  icmp_rate_limit                           = 10
  icmp_rate_mask                            = "0x1818"

  ipv4_multipath_hash_policy = "l3"
  max_neighbor_entries       = 8192
}

# SMB. `enabled = "auto"` with `status: disabled` on the device — auto means
# "run only if a share is configured", and none is, so nothing is listening.
# Imported so that stops being true silently. An SMB server on the router is
# worth switching off outright rather than leaving on auto.
resource "routeros_ip_smb" "this" {
  enabled    = "auto"
  comment    = "MikrotikSMB"
  domain     = "MSHOME"
  interfaces = ["all"]
}

# The bandwidth-test server. NOT part of /ip/service despite appearing in that
# REST view as a dynamic entry — btest is its own subsystem, which is why #1524's
# "disable it in /ip/service" step cannot work as written. Enabled, authenticated,
# 100 sessions.
resource "routeros_tool_bandwidth_server" "this" {
  enabled                 = true
  authenticate            = true
  max_sessions            = 100
  allocate_udp_ports_from = 2000
}

