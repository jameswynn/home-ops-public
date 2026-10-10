# Wave 6a — WireGuard. The interface and its peers, with a hard rule:
#
#   NO PRIVATE KEY IS EVER MODELLED IN THIS REPO.
#
# The server's key lives in Bitwarden and arrives as TF_VAR_wireguard_private_key.
# Peer private keys belong to the clients and nowhere else — see the note on
# `private_key` below, and `just mikrotik wg-add` for how new ones are made.
#
# Encryption of wireguard.sops.yaml is not what protects the keys (there are
# none in it); it protects the peer inventory — who has remote access, their
# tunnel addresses, and the public endpoint.

resource "routeros_interface_wireguard" "this" {
  name        = var.wireguard.interface.name
  listen_port = var.wireguard.interface.listen_port
  mtu         = var.wireguard.interface.mtu
  comment     = var.wireguard.interface.comment
  disabled    = var.wireguard.interface.disabled

  # Asserted from Bitwarden rather than read-and-forgotten. A clean plan here is
  # therefore also a check that the Bitwarden copy still matches the router — if
  # someone regenerates the key on the device, the next plan says so.
  private_key = var.wireguard_private_key

  lifecycle {
    precondition {
      condition     = var.wireguard_private_key != null && var.wireguard_private_key != ""
      error_message = "TF_VAR_wireguard_private_key is unset. Add it to the Bitwarden project — see BOOTSTRAP.md Wave 6a. Without it tofu cannot assert the interface key, and applying would clear it."
    }
  }
}

resource "routeros_interface_wireguard_peer" "this" {
  for_each = var.wireguard.peers

  interface  = routeros_interface_wireguard.this.name
  public_key = each.value.public_key
  name       = each.value.name
  comment    = each.value.comment
  disabled   = each.value.disabled

  # Which tunnel addresses this peer may use as a source. This is the actual
  # access control on the tunnel — a /32 per client.
  allowed_address = each.value.allowed_address

  # Set only where the router should initiate to a peer. Every peer here is a
  # roaming client that dials in, so these are empty in practice.
  endpoint_address = each.value.endpoint_address
  endpoint_port    = each.value.endpoint_port

  # RouterOS's client-config generator inputs. Kept because they document how to
  # rebuild a client config; `just mikrotik wg-add` reads them for the same
  # reason. They are not part of the tunnel's operation.
  client_address   = each.value.client_address
  client_dns       = each.value.client_dns
  client_endpoint  = each.value.client_endpoint
  client_keepalive = each.value.client_keepalive

  # `private_key` is deliberately absent, and its absence is load-bearing.
  #
  # RouterOS stores a *client's* private key when a peer is created through the
  # config-generator, so the router can re-render that client's config later.
  # That means the router — and anyone holding the `sensitive` policy — can
  # impersonate the client. Omitting the attribute here makes tofu remove any
  # such key it finds, which is the desired end state.
  #
  # Strip them on the router BEFORE importing, not after: the provider reads
  # private_key into state on import even when it is not in config, so an
  # import-then-remove leaves the key sitting in terraform.tfstate and its
  # .backup. See BOOTSTRAP.md Wave 6a.
}
