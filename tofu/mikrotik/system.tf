# Wave 1 — inert system config. Values mirror what was already on the router at
# import time; changes to them are deliberate and called out below.

resource "routeros_system_identity" "this" {
  name = "MikroTik"
}

resource "routeros_system_clock" "this" {
  # Matches CLUSTER_TZ in components/cluster-vars/cluster-configs.yaml.
  time_zone_name       = "America/Chicago"
  time_zone_autodetect = true
}

resource "routeros_system_ntp_client" "this" {
  # Was imported disabled with no servers — the router was not disciplining its
  # clock at all. Enabling it is the first deliberate change in this module.
  # time.cloudflare.com is anycast, so one entry is already geographically
  # redundant; the router resolves it via its own DNS (1.1.1.1).
  enabled = true
  mode    = "unicast"
  servers = ["time.cloudflare.com"]
  vrf     = "main"
}

# Wave 10 — MikroTik cloud DDNS, for a stable WireGuard endpoint (issue #1523).
#
# The client configs pointed at the bare WAN address. That address is
# DHCP-assigned: ether1 holds 192.168.100.66/24 from the upstream BGW320-500, so
# there is NAT above us and the public address is the BGW's. If it changes,
# every client config breaks at once — and WireGuard is the remote-access path,
# so there is no way to fix them remotely.
#
# The endpoint deliberately stays on MikroTik's own <serial>.sn.mynetname.net
# and is NOT fronted by a wynning.tech CNAME. Every public hostname resolves to
# heimdall (15.204.118.232); the home WAN address appears nowhere in the zone,
# and keeping it that way is the point of the towonel edge. A wg.wynning.tech
# record could not be Cloudflare-proxied (UDP), so it would publish the
# residential IP under the domain. Here the linkage only ever runs IP -> name,
# never domain -> IP, so enumerating the domain still finds nothing.
#
# This is not a new phone-home: public_address was already populated before
# DDNS was switched on, so the router was talking to cloud2.mikrotik.com
# regardless. What changes is that a name gets published.
resource "routeros_ip_cloud" "this" {
  # Was "auto", which had assigned no dns_name and left ddns_update_interval at
  # "none" — nothing was actually being published. "yes" is unconditional.
  ddns_enabled = "yes"

  # No periodic push. The router updates the record when it observes the
  # address change, which is the RouterOS default and enough here.
  ddns_update_interval = "none"

  # Left as found. The NTP client above is the real time source; this is the
  # cloud fallback for a router without one.
  update_time = "true"

  # back_to_home_vpn is deliberately unset — that is MikroTik's own hosted VPN
  # service, unrelated to DDNS, and not wanted.
}
