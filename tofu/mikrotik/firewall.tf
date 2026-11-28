# Wave 4 — firewall. Import-only: every attribute below mirrors what the router
# already had. See BOOTSTRAP.md for the findings this import surfaced.
#
# ORDERING IS NOT MODELLED HERE, and that is deliberate. `place_before` is a
# create-time hint only, and `for_each` gives no ordering guarantee — so an
# ordered ruleset is safe under tofu exactly as long as tofu never *creates* a
# rule. Every rule here is imported, so tofu only ever updates in place and the
# router's order is untouched. Adding a rule is the one operation that needs
# care: add it on the router by hand, in the right position, then import it.
# `routeros_move_items` can assert an explicit sequence if that ever stops being
# good enough — see BOOTSTRAP.md Wave 4b.
#
# Chain order is the whole security model. Read the map keys (f01…f21) as the
# router's rule order; they are otherwise meaningless handles.
#
# Forward-chain trust model (issue 2073), evaluated top to bottom after the
# defconf state rules:
#   Management (192.168.99.0/24)      -> anything
#   Servers (192.168.1/24, 10.1/16,
#            10.11.0/24 LB pool)      -> anything
#   Trusted                           -> Servers, Management
#   Users (Workstations 10.10.2/24,
#          WireGuard 10.10.5/24)      -> LB pool 10.11.0.0/24, IoT 10.3.0/24 (casting,
#                                        device control) + Universal Accessible
#   Guest (10.4.0/24)                 -> AdGuard :53, then dropped to every local net
#   defconf (192.168.88/24, UniFi AP) -> UniFi controller + Universal Accessible
#   IoT                               -> unchanged allow-list (f16-f19)
#   Local Network                     -> WAN
#   everything else                   -> f21: logged passthrough today, becomes
#                                        drop once the FWD-AUDIT log is clean.
#
# `Trusted` is fed by DHCP leases (leases.sops.yaml `address_lists: [Trusted]`):
# the router adds the leased IP for the lease lifetime and removes it on expiry,
# so a hand-set IP without the lease is not trusted. WireGuard peers that count
# as trusted are static entries (a43, a44) because their IPs are fixed by the
# peer config. Add a device by tagging its lease, not by adding an IP here.

resource "routeros_ip_firewall_filter" "this" {
  for_each = var.firewall.filters

  chain  = each.value.chain
  action = each.value.action

  comment     = each.value.comment
  disabled    = each.value.disabled
  log         = each.value.log
  log_prefix  = each.value.log_prefix
  jump_target = each.value.jump_target

  connection_state     = each.value.connection_state
  connection_nat_state = each.value.connection_nat_state
  ipsec_policy         = each.value.ipsec_policy
  hw_offload           = each.value.hw_offload

  protocol = each.value.protocol
  dst_port = each.value.dst_port

  src_address        = each.value.src_address
  src_address_list   = each.value.src_address_list
  dst_address        = each.value.dst_address
  dst_address_list   = each.value.dst_address_list
  in_interface_list  = each.value.in_interface_list
  out_interface_list = each.value.out_interface_list

  depends_on = [routeros_ip_firewall_addr_list.this]
}

resource "routeros_ip_firewall_nat" "this" {
  for_each = var.firewall.nat

  chain  = each.value.chain
  action = each.value.action

  comment    = each.value.comment
  disabled   = each.value.disabled
  log        = each.value.log
  log_prefix = each.value.log_prefix

  ipsec_policy = each.value.ipsec_policy
  protocol     = each.value.protocol
  dst_port     = each.value.dst_port

  in_interface_list  = each.value.in_interface_list
  out_interface_list = each.value.out_interface_list
  dst_address_list   = each.value.dst_address_list

  to_addresses = each.value.to_addresses
  to_ports     = each.value.to_ports
}

# The filter rules reference these lists by name, hence the depends_on above:
# an entry must exist before a rule that matches on its list.
resource "routeros_ip_firewall_addr_list" "this" {
  for_each = var.firewall.addr_lists

  list    = each.value.list
  address = each.value.address
  comment = each.value.comment

  # Five entries are disabled on the router — kept, not deleted, because they are
  # devices that come and go. Modelled explicitly so an omission cannot silently
  # re-enable them.
  disabled = each.value.disabled
}
