# Wave 14 -- IPv6.
#
# Inert today and that is exactly why it is worth managing. The ISP hands out no
# prefix, so every address on the box is link-local and nothing routes over v6.
# But `disable-ipv6` is false and `forward` is true, so the day a prefix appears
# this ruleset is the only thing standing in the way -- and nobody would think to
# review it at that moment. Importing it now means a plan shows any change.
#
# All 22 filter rules and all 9 address-list entries are untouched RouterOS
# defconf. Addresses (9) and routes (9) are ALL dynamic, so there is nothing
# there to manage; `ipv6/nd/prefix`, `ipv6/dhcp-client`, `ipv6/pool` and
# `ipv6/firewall/nat` are empty.
#
# Worth noting against issue #1521: the v6 forward chain DOES end in a drop
# (v6f22), where the v4 one does not. It is the same shape though -- the drop is
# `in-interface-list: !LAN`, so LAN-to-LAN forwarding still falls through
# accepted. v6 is not more segmented than v4, just less hand-edited.

resource "routeros_ipv6_firewall_addr_list" "this" {
  for_each = local.ipv6_addr_lists

  list    = each.value.list
  address = each.value.address
  comment = each.value.comment
}

resource "routeros_ipv6_firewall_filter" "this" {
  for_each = local.ipv6_filters

  chain   = each.value.chain
  action  = each.value.action
  comment = each.value.comment

  connection_state  = try(each.value.connection_state, null)
  protocol          = try(each.value.protocol, null)
  port              = try(each.value.port, null)
  dst_port          = try(each.value.dst_port, null)
  src_address       = try(each.value.src_address, null)
  src_address_list  = try(each.value.src_address_list, null)
  dst_address_list  = try(each.value.dst_address_list, null)
  in_interface_list = try(each.value.in_interface_list, null)
  ipsec_policy      = try(each.value.ipsec_policy, null)
  hop_limit         = try(each.value.hop_limit, null)

  depends_on = [routeros_ipv6_firewall_addr_list.this]
}

# `forward = true` with `disable-ipv6 = false` is the pair that matters here.
# Neither is changed -- this wave is an import -- but they are the reason the
# ruleset above is not academic.
resource "routeros_ipv6_settings" "this" {
  disable_ipv6               = false
  disable_link_local_address = false
  forward                    = true
  allow_fast_path            = true

  accept_redirects             = "yes-if-forwarding-disabled"
  accept_router_advertisements = "yes-if-forwarding-disabled"

  max_neighbor_entries           = 4096
  min_neighbor_entries           = 1024
  soft_max_neighbor_entries      = 2048
  stale_neighbor_detect_interval = 30
  stale_neighbor_timeout         = 60
  multipath_hash_policy          = "l3"
}

# Router advertisements. `interface = "all"` and RouterOS flags this entry
# `default`, so it is the stock ND config rather than anything hand-made. It
# advertises nothing useful today because there is no prefix to advertise.
resource "routeros_ipv6_neighbor_discovery" "this" {
  interface = "all"
  disabled  = false

  advertise_dns                 = true
  advertise_mac_address         = true
  managed_address_configuration = false
  other_configuration           = false

  ra_delay      = "3s"
  ra_interval   = "3m20s-10m"
  ra_lifetime   = "30m"
  ra_preference = "medium"

  # hop_limit, mtu, reachable_time and retransmit_interval all read
  # "unspecified" on the device and are typed as numbers here, so they are
  # omitted rather than guessed at.
}
