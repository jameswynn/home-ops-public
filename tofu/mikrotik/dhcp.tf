# DHCP reservations only. The servers, pools and networks they belong to are not
# managed yet — see BOOTSTRAP.md Wave 3. Note the router already runs six DHCP
# servers across segmented interfaces.
resource "routeros_ip_dhcp_server_lease" "static" {
  for_each = var.static_leases

  address     = each.value.address
  mac_address = each.value.mac_address
  server      = each.value.server
  comment     = each.value.comment
  lease_time  = each.value.lease_time

  # 39 of these carry a DHCP client identifier. Omitting it does not leave it
  # alone — tofu would delete it, changing how the router matches those clients.
  client_id = each.value.client_id

  # Two leases are disabled on the router. Modelled explicitly so they cannot be
  # silently re-enabled by an omission later.
  disabled = each.value.disabled

  lifecycle {
    # The router reports `blocked: false` on every lease, but the provider does
    # not populate block_access on import, leaving it null against a schema
    # default of false. That is an import artefact, not drift — and lease
    # blocking is not something this module manages.
    ignore_changes = [block_access]
  }
}

resource "routeros_ip_pool" "this" {
  for_each = var.dhcp.pools

  name   = each.value.name
  ranges = each.value.ranges
}

resource "routeros_ip_dhcp_server" "this" {
  for_each = var.dhcp.servers

  name            = each.value.name
  interface       = each.value.interface
  address_pool    = each.value.address_pool
  lease_time      = each.value.lease_time
  disabled        = each.value.disabled
  use_radius      = each.value.use_radius
  use_reconfigure = each.value.use_reconfigure
  address_lists   = each.value.address_lists

  # The lease script is rendered from one plaintext template rather than
  # stored as five encrypted blobs -- see BOOTSTRAP.md Wave 9.
  #
  # It was five near-copies that had drifted apart: Workstations had a guard
  # against inserting a DNS record with an empty name that the other four
  # lacked, and IoT was running with the script's debug logging left on. The
  # template is Workstations' version, and it renders byte-identical to what
  # was on that server, which is what proves the extraction faithful.
  #
  # `defconf` has no dns_domain and so gets no script, the same as before.
  lease_script = each.value.dns_domain == null ? null : templatefile(
    "${path.module}/scripts/dhcp-lease-dns.rsc.tftpl",
    {
      dns_domain             = each.value.dns_domain
      hostname_source        = each.value.hostname_source
      dns_ttl                = each.value.dns_ttl
      dns_remove_all_by_ip   = each.value.dns_remove_all_by_ip
      dns_remove_all_by_name = each.value.dns_remove_all_by_name
      dns_always_nonfqdn     = each.value.dns_always_nonfqdn

      # The template puts this in front of each :log info line, so "#"
      # comments it out and "" enables it.
      log = each.value.dns_debug ? "" : "#"
    }
  )

  depends_on = [routeros_ip_pool.this]
}

resource "routeros_ip_dhcp_server_network" "this" {
  for_each = var.dhcp.networks

  address      = each.value.address
  gateway      = each.value.gateway
  comment      = each.value.comment
  domain       = each.value.domain
  dns_server   = each.value.dns_server
  ntp_server   = each.value.ntp_server
  caps_manager = each.value.caps_manager
  wins_server  = each.value.wins_server
  dhcp_option  = each.value.dhcp_option
}
