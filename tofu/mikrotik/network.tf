# Wave 5 — interfaces, VLANs and addressing. Import-only: every attribute here
# mirrors what the router already had, including RouterOS's own defaults.
#
# THIS IS THE FILE THAT CAN PARTITION THE NETWORK. Unlike the DHCP and firewall
# waves there is no safe read-only rehearsal: a wrong `pvid`, a dropped `tagged`
# member or `vlan_filtering = false` cuts the router off from the segment you
# are editing it over. Two specific tripwires:
#
#   * ether5 is the ONLY trunk. It carries VLANs 10/100/200/300/400 tagged, so
#     removing it from any bridge_vlan `tagged` set takes that whole VLAN down.
#   * The `LAN` interface list is what grants access to the firewall's `input`
#     chain (`drop all not coming from LAN`, in-interface-list=!LAN). Dropping a
#     member here locks that segment out of the router itself — including the
#     one this module talks to it over.
#
# Everything is modelled explicitly, defaults included, precisely because
# omitting an attribute deletes it rather than leaving it alone. The verbosity
# is the point; the data is generated from the router, not hand-written.
#
# Deliberately NOT managed:
#   * ethernet interfaces (/interface/ethernet) — stock settings on all six, and
#     the resource carries a large computed surface for no gain here.
#   * wireguard1 and its 5 peers — managing them would put private keys in local
#     state. See BOOTSTRAP.md Wave 6.
#   * the DHCP-assigned WAN address on ether1 and the dynamic vlan-1 bridge VLAN
#     entry — both are dynamic; tofu must not own them.
#   * the built-in `all`/`none`/`dynamic`/`static` interface lists, which cannot
#     be deleted and which nothing here changes.

resource "routeros_interface_bridge" "this" {
  for_each = var.network.bridges

  name                = each.value.name
  admin_mac           = each.value.admin_mac
  ageing_time         = each.value.ageing_time
  arp                 = each.value.arp
  arp_timeout         = each.value.arp_timeout
  auto_mac            = each.value.auto_mac
  comment             = each.value.comment
  dhcp_snooping       = each.value.dhcp_snooping
  disabled            = each.value.disabled
  ether_type          = each.value.ether_type
  fast_forward        = each.value.fast_forward
  forward_delay       = each.value.forward_delay
  frame_types         = each.value.frame_types
  igmp_snooping       = each.value.igmp_snooping
  ingress_filtering   = each.value.ingress_filtering
  max_learned_entries = each.value.max_learned_entries
  max_message_age     = each.value.max_message_age
  mtu                 = each.value.mtu
  mvrp                = each.value.mvrp
  port_cost_mode      = each.value.port_cost_mode
  priority            = each.value.priority
  protocol_mode       = each.value.protocol_mode
  pvid                = each.value.pvid
  transmit_hold_count = each.value.transmit_hold_count
  vlan_filtering      = each.value.vlan_filtering
}

resource "routeros_interface_bridge_port" "this" {
  for_each = var.network.bridge_ports

  bridge                  = each.value.bridge
  interface               = each.value.interface
  auto_isolate            = each.value.auto_isolate
  bpdu_guard              = each.value.bpdu_guard
  broadcast_flood         = each.value.broadcast_flood
  comment                 = each.value.comment
  disabled                = each.value.disabled
  edge                    = each.value.edge
  fast_leave              = each.value.fast_leave
  frame_types             = each.value.frame_types
  horizon                 = each.value.horizon
  hw                      = each.value.hw
  ingress_filtering       = each.value.ingress_filtering
  internal_path_cost      = each.value.internal_path_cost
  learn                   = each.value.learn
  multicast_router        = each.value.multicast_router
  mvrp_applicant_state    = each.value.mvrp_applicant_state
  mvrp_registrar_state    = each.value.mvrp_registrar_state
  path_cost               = each.value.path_cost
  point_to_point          = each.value.point_to_point
  priority                = each.value.priority
  pvid                    = each.value.pvid
  restricted_role         = each.value.restricted_role
  restricted_tcn          = each.value.restricted_tcn
  tag_stacking            = each.value.tag_stacking
  trusted                 = each.value.trusted
  unknown_multicast_flood = each.value.unknown_multicast_flood
  unknown_unicast_flood   = each.value.unknown_unicast_flood

  # A port must have its bridge before it can join it.
  depends_on = [routeros_interface_bridge.this]
}

resource "routeros_interface_bridge_vlan" "this" {
  for_each = var.network.bridge_vlans

  bridge   = each.value.bridge
  vlan_ids = each.value.vlan_ids
  comment  = each.value.comment
  disabled = each.value.disabled
  tagged   = each.value.tagged
  untagged = each.value.untagged

  # `tagged`/`untagged` name ports, so the ports must exist first.
  depends_on = [routeros_interface_bridge.this, routeros_interface_bridge_port.this]
}

resource "routeros_interface_vlan" "this" {
  for_each = var.network.vlans

  interface                  = each.value.interface
  name                       = each.value.name
  arp                        = each.value.arp
  arp_timeout                = each.value.arp_timeout
  disabled                   = each.value.disabled
  loop_protect               = each.value.loop_protect
  loop_protect_disable_time  = each.value.loop_protect_disable_time
  loop_protect_send_interval = each.value.loop_protect_send_interval
  mtu                        = each.value.mtu
  mvrp                       = each.value.mvrp
  use_service_tag            = each.value.use_service_tag
  vlan_id                    = each.value.vlan_id

  # The L3 VLAN interface rides on a VLAN the bridge already passes.
  depends_on = [routeros_interface_bridge_vlan.this]
}

resource "routeros_ip_address" "this" {
  for_each = var.network.addresses

  address   = each.value.address
  interface = each.value.interface
  comment   = each.value.comment
  disabled  = each.value.disabled

  # Addresses are assigned to the VLAN interfaces above (plus the bridge).
  depends_on = [routeros_interface_vlan.this]
}

resource "routeros_interface_list" "this" {
  for_each = var.network.interface_lists

  name    = each.value.name
  comment = each.value.comment
}

resource "routeros_interface_list_member" "this" {
  for_each = var.network.interface_list_members

  interface = each.value.interface
  list      = each.value.list
  comment   = each.value.comment
  disabled  = each.value.disabled

  # Members reference both the list and the interface by name.
  depends_on = [routeros_interface_list.this, routeros_interface_vlan.this]
}

# Wave 13 — the physical ports and the WAN uplink.
#
# Inert to import and unforgiving to get wrong: ether1 carries the internet and
# ether5 carries the entire LAN, so a bad attribute here is a cut-off router
# rather than a failed reconcile. Everything below mirrors the device.
#
# `mac_address` is deliberately unmanaged. It is writable, and on every port it
# equals the burned-in `orig-mac-address`, so managing it buys nothing and costs
# something real: changing ether1's MAC would make the BGW hand out a new DHCP
# lease, which would break the port-forward that WireGuard depends on. Verified
# that omitting it produces no drift.
resource "routeros_interface_ethernet" "this" {
  for_each = local.ethernet_ports

  factory_name = each.key
  name         = each.key

  # Identical across all six ports.
  advertise                  = "10M-baseT-half,10M-baseT-full,100M-baseT-half,100M-baseT-full,1G-baseT-half,1G-baseT-full"
  arp                        = "enabled"
  arp_timeout                = "auto"
  auto_negotiation           = true
  bandwidth                  = "unlimited/unlimited"
  disabled                   = false
  l2mtu                      = 1596
  mtu                        = 1500
  loop_protect               = "default"
  loop_protect_disable_time  = "5m"
  loop_protect_send_interval = "5s"

  poe_out                  = try(each.value.poe_out, null)
  poe_priority             = try(each.value.poe_priority, null)
  power_cycle_interval     = try(each.value.power_cycle_interval, null)
  power_cycle_ping_enabled = try(each.value.power_cycle_ping_enabled, null)
  sfp_shutdown_temperature = try(each.value.sfp_shutdown_temperature, null)

  lifecycle {
    # The API calls this field `default-name` and the provider calls it
    # `factory_name`, so import leaves it unset in state while config requires
    # it. Without this, every plan proposes adding it forever. An import
    # artefact, not drift -- the same treatment block_access gets in dhcp.tf.
    ignore_changes = [factory_name]
  }
}

# The WAN uplink. Addresses are all computed -- none of 192.168.100.66/24, its
# gateway or the peer DNS appears in config, because the BGW assigns them.
#
# `use_peer_dns = false` is the load-bearing one: the router resolves through
# 1.1.1.1 rather than the BGW, which is what keeps `time.cloudflare.com` and the
# rest resolvable independently of the ISP.
#
# `add-default-route: yes` on the device has no field in the provider schema, so
# tofu neither sets nor clears it. `default_route_distance` is the part it can
# see.
resource "routeros_ip_dhcp_client" "wan" {
  interface = "ether1"
  comment   = "defconf"

  use_peer_dns = false

  # Inert in practice: the NTP client is explicitly set to time.cloudflare.com
  # and carries no dynamic servers, so nothing is being injected from DHCP.
  use_peer_ntp = true

  default_route_distance = 1
  default_route_tables   = ["default"]
  dhcp_options           = "hostname,clientid"
  use_broadcast          = "both"
  check_gateway          = "none"
  allow_reconfigure      = false
  disabled               = false

  depends_on = [routeros_interface_ethernet.this]
}
