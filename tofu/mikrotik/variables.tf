# Every variable here is supplied as TF_VAR_* by `bws run`; see mod.just.
# There is deliberately no tfvars file — nothing gets decrypted to disk.

variable "routeros_url" {
  description = "RouterOS REST API base URL, e.g. https://192.168.1.1"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.routeros_url))
    error_message = "routeros_url must start with http:// or https://."
  }
}

variable "routeros_username" {
  description = "RouterOS user with the policies the managed resources need"
  type        = string
  sensitive   = true
}

variable "routeros_password" {
  type      = string
  sensitive = true
}

variable "routeros_ca_path" {
  description = "Path to a CA cert for the router's API certificate. Empty means none."
  type        = string
  default     = ""
}

variable "routeros_insecure" {
  description = "Skip TLS verification. True until the API cert is managed here."
  type        = bool
  default     = false
}

# DHCP reservations. Held encrypted in leases.sops.yaml and injected as JSON by
# mod.just, so the MAC/IP/hostname inventory never appears in the public mirror.
# Map keys are opaque handles on purpose: SOPS encrypts values, not keys, so a
# map keyed by address or MAC would publish exactly what this is hiding.
variable "static_leases" {
  type = map(object({
    address     = string
    mac_address = string
    server      = optional(string)
    comment     = optional(string)
    lease_time  = optional(string)
    client_id   = optional(string)
    disabled    = optional(bool)
  }))
  default = {}

  # Deliberately NOT sensitive. for_each rejects sensitive values, and marking
  # it would redact plan output to "(sensitive value)", making a lease change
  # impossible to review — the one moment you most need to read it. Privacy
  # here comes from encryption at rest, not from hiding it locally.

  # Guard against the empty-fallback footgun, not against bad input.
  validation {
    condition     = length(var.static_leases) > 0
    error_message = "mod.just falls back to an empty map when `sops -d` fails, and an empty map means every lease is absent from config -- which tofu reads as DESTROY. This is almost certainly a decryption failure, not an intentional empty config. Check SOPS_AGE_KEY_FILE and that ~/.config/sops/age/keys.txt exists."
  }
}

# DHCP topology: pools, servers and their networks. Encrypted for the same
# reason as the leases — the subnets map the segmentation, and the network
# comments carry internal domain names this repo treats as secret elsewhere.
# Keys are opaque handles; the router's own names live in the values.
variable "dhcp" {
  type = object({
    pools = map(object({
      name   = string
      ranges = list(string)
    }))
    servers = map(object({
      name            = string
      interface       = string
      address_pool    = string
      lease_time      = optional(string)
      disabled        = optional(bool)
      use_radius      = optional(string)
      use_reconfigure = optional(bool)
      address_lists   = optional(set(string))

      # Inputs to scripts/dhcp-lease-dns.rsc.tftpl. A server with no
      # dns_domain gets no lease script at all -- see dhcp.tf.
      #
      # Only dns_domain is here for secrecy; the rest are here because they
      # legitimately differ per server, or did before Wave 9 unified them.
      # The script body itself is plaintext in the repo and reviewable.
      dns_domain      = optional(string)
      hostname_source = optional(string, "lease-hostname")
      dns_ttl         = optional(string, "00:15:00")

      # Uncomments the six :log info lines. IoT ran with these on, which is
      # why it was the noisiest server in the log; off everywhere now.
      dns_debug = optional(bool, false)

      # Upstream script knobs. Identical on all five servers today; exposed
      # rather than hardcoded so a future divergence is a data change.
      dns_remove_all_by_ip   = optional(string, "1")
      dns_remove_all_by_name = optional(string, "1")
      dns_always_nonfqdn     = optional(string, "0")
    }))
    networks = map(object({
      address      = string
      gateway      = optional(string)
      comment      = optional(string)
      domain       = optional(string)
      dns_server   = optional(list(string))
      ntp_server   = optional(list(string))
      caps_manager = optional(list(string))
      wins_server  = optional(list(string))
      dhcp_option  = optional(list(string))
    }))
  })
  default = { pools = {}, servers = {}, networks = {} }

  # Guard against the empty-fallback footgun, not against bad input.
  validation {
    condition     = length(var.dhcp.pools) > 0 && length(var.dhcp.servers) > 0
    error_message = "mod.just falls back to an empty map when `sops -d` fails, and an empty map means every pool and server is absent from config -- which tofu reads as DESTROY. This is almost certainly a decryption failure, not an intentional empty config. Check SOPS_AGE_KEY_FILE and that ~/.config/sops/age/keys.txt exists."
  }
}

# Firewall: filter rules, NAT rules and address lists. Encrypted for the same
# reason as the DHCP data, and more so — the ruleset is a map of the network's
# segmentation, and the address lists name individual devices. Map keys are
# opaque handles; for the filters they also carry the router's rule order
# (f01…f19), which is the only place ordering is recorded (see firewall.tf).
#
# Only static entries are modelled. /ip/firewall/mangle and /ip/firewall/raw
# hold nothing but RouterOS's dynamic fasttrack counter rules, so they have no
# resources at all; the same dynamic rule in the filter chain is excluded here.
variable "firewall" {
  type = object({
    filters = map(object({
      chain  = string
      action = string

      comment     = optional(string)
      disabled    = optional(bool)
      log         = optional(bool)
      log_prefix  = optional(string)
      jump_target = optional(string)

      connection_state     = optional(string)
      connection_nat_state = optional(string)
      ipsec_policy         = optional(string)
      hw_offload           = optional(bool)

      protocol = optional(string)
      dst_port = optional(string)

      src_address        = optional(string)
      src_address_list   = optional(string)
      dst_address        = optional(string)
      dst_address_list   = optional(string)
      in_interface_list  = optional(string)
      out_interface_list = optional(string)
    }))
    nat = map(object({
      chain  = string
      action = string

      comment    = optional(string)
      disabled   = optional(bool)
      log        = optional(bool)
      log_prefix = optional(string)

      ipsec_policy = optional(string)
      protocol     = optional(string)
      dst_port     = optional(string)

      in_interface_list  = optional(string)
      out_interface_list = optional(string)

      to_addresses = optional(string)
      to_ports     = optional(string)
    }))
    addr_lists = map(object({
      list     = string
      address  = string
      comment  = optional(string)
      disabled = optional(bool)
    }))
  })
  default = { filters = {}, nat = {}, addr_lists = {} }

  # Guard against the empty-fallback footgun, not against bad input.
  validation {
    condition     = length(var.firewall.filters) > 0
    error_message = "mod.just falls back to an empty map when `sops -d` fails, and an empty map means every firewall rule is absent from config -- which tofu reads as DESTROY. This is almost certainly a decryption failure, not an intentional empty config. Check SOPS_AGE_KEY_FILE and that ~/.config/sops/age/keys.txt exists."
  }
}

# Interfaces, VLANs and addressing. Encrypted like the rest: this is the most
# complete map of the network in the repo — VLAN IDs, per-port trunk membership,
# every gateway subnet, and the bridge's admin MAC.
variable "network" {
  type = object({
    bridges = map(object({
      name                = string
      admin_mac           = optional(string)
      ageing_time         = optional(string)
      arp                 = optional(string)
      arp_timeout         = optional(string)
      auto_mac            = optional(bool)
      comment             = optional(string)
      dhcp_snooping       = optional(bool)
      disabled            = optional(bool)
      ether_type          = optional(string)
      fast_forward        = optional(bool)
      forward_delay       = optional(string)
      frame_types         = optional(string)
      igmp_snooping       = optional(bool)
      ingress_filtering   = optional(bool)
      max_learned_entries = optional(string)
      max_message_age     = optional(string)
      mtu                 = optional(string)
      mvrp                = optional(bool)
      port_cost_mode      = optional(string)
      priority            = optional(string)
      protocol_mode       = optional(string)
      pvid                = optional(number)
      transmit_hold_count = optional(number)
      vlan_filtering      = optional(bool)
    }))
    bridge_ports = map(object({
      bridge                  = string
      interface               = string
      auto_isolate            = optional(bool)
      bpdu_guard              = optional(bool)
      broadcast_flood         = optional(bool)
      comment                 = optional(string)
      disabled                = optional(bool)
      edge                    = optional(string)
      fast_leave              = optional(bool)
      frame_types             = optional(string)
      horizon                 = optional(string)
      hw                      = optional(bool)
      ingress_filtering       = optional(bool)
      internal_path_cost      = optional(number)
      learn                   = optional(string)
      multicast_router        = optional(string)
      mvrp_applicant_state    = optional(string)
      mvrp_registrar_state    = optional(string)
      path_cost               = optional(string)
      point_to_point          = optional(string)
      priority                = optional(string)
      pvid                    = optional(number)
      restricted_role         = optional(bool)
      restricted_tcn          = optional(bool)
      tag_stacking            = optional(bool)
      trusted                 = optional(bool)
      unknown_multicast_flood = optional(bool)
      unknown_unicast_flood   = optional(bool)
    }))
    bridge_vlans = map(object({
      bridge   = string
      vlan_ids = set(string)
      comment  = optional(string)
      disabled = optional(bool)
      tagged   = optional(set(string))
      untagged = optional(set(string))
    }))
    vlans = map(object({
      interface                  = string
      name                       = string
      arp                        = optional(string)
      arp_timeout                = optional(string)
      disabled                   = optional(bool)
      loop_protect               = optional(string)
      loop_protect_disable_time  = optional(string)
      loop_protect_send_interval = optional(string)
      mtu                        = optional(string)
      mvrp                       = optional(bool)
      use_service_tag            = optional(bool)
      vlan_id                    = optional(number)
    }))
    addresses = map(object({
      address   = string
      interface = string
      comment   = optional(string)
      disabled  = optional(bool)
    }))
    interface_lists = map(object({
      name    = string
      comment = optional(string)
    }))
    interface_list_members = map(object({
      interface = string
      list      = string
      comment   = optional(string)
      disabled  = optional(bool)
    }))
  })
  default = { bridges = {}, bridge_ports = {}, bridge_vlans = {}, vlans = {}, addresses = {}, interface_lists = {}, interface_list_members = {} }

  # Guard against the empty-fallback footgun, not against bad input.
  validation {
    condition     = length(var.network.bridges) > 0 && length(var.network.vlans) > 0
    error_message = "mod.just falls back to an empty map when `sops -d` fails, and an empty map means every bridge and VLAN is absent from config -- which tofu reads as DESTROY. This is almost certainly a decryption failure, not an intentional empty config. Check SOPS_AGE_KEY_FILE and that ~/.config/sops/age/keys.txt exists."
  }
}

# The WireGuard server's own private key, from Bitwarden via `bws run`. Null by
# default so the rest of the module still plans on a machine without it; the
# resource's precondition turns that into a readable error rather than a silent
# no-op. Never write this to a file — that is the whole point of it living in
# Bitwarden.
variable "wireguard_private_key" {
  type      = string
  sensitive = true
  default   = null
}

# WireGuard interface and peers. No key material: the server key comes from
# Bitwarden (above) and peer private keys belong to the clients. What is
# encrypted here is the peer inventory — who has remote access, their tunnel
# addresses, and the public endpoint.
variable "wireguard" {
  type = object({
    # Where clients should dial in. Not a router field — it is what
    # `just mikrotik wg-add` writes into generated client configs.
    client_endpoint = string

    interface = object({
      name        = string
      listen_port = number
      mtu         = optional(string)
      comment     = optional(string)
      disabled    = optional(bool)
    })

    peers = map(object({
      public_key      = string
      allowed_address = list(string)

      name     = optional(string)
      comment  = optional(string)
      disabled = optional(bool)

      endpoint_address = optional(string)
      endpoint_port    = optional(string)

      client_address   = optional(string)
      client_dns       = optional(string)
      client_endpoint  = optional(string)
      client_keepalive = optional(string)
    }))
  })

  # Guard against the empty-fallback footgun, not against bad input.
  validation {
    condition     = var.wireguard.interface.name != "" && length(var.wireguard.peers) > 0
    error_message = "mod.just falls back to an empty map when `sops -d` fails, and an empty map means every peer is absent from config -- which tofu reads as DESTROY. This is almost certainly a decryption failure, not an intentional empty config. Check SOPS_AGE_KEY_FILE and that ~/.config/sops/age/keys.txt exists."
  }
}

# Manually-created DNS records in /ip/dns/static. Encrypted for the same reason
# as the leases: this is a name-to-address map of the whole network, including
# the IoT and Management VLANs.
#
# ONLY the hand-made records. Of the 282 entries on the router, external-dns
# owns 211 and the DHCP lease scripts own 37; tofu must never see either set.
# The ownership test, and how the lease-script records were caught, is in
# dns.tf. Keys are opaque handles (SOPS encrypts values, not keys) and carry no
# meaning beyond sort order.
variable "dns_records" {
  type = map(object({
    name = string
    type = string

    address  = optional(string)
    cname    = optional(string)
    ttl      = optional(string)
    comment  = optional(string)
    disabled = optional(bool)
  }))
  default = {}

  # Guard against the empty-fallback footgun, not against bad input.
  validation {
    condition     = length(var.dns_records) > 0
    error_message = "mod.just falls back to an empty map when `sops -d` fails, and an empty map means every record is absent from config -- which tofu reads as DESTROY. This is almost certainly a decryption failure, not an intentional empty config. Check SOPS_AGE_KEY_FILE and that ~/.config/sops/age/keys.txt exists."
  }

  # A record is either an address or a cname, never both and never neither.
  # Cheap to get wrong by hand-editing the decrypted file, and the router's
  # error for it is unhelpful.
  validation {
    condition = alltrue([
      for k, v in var.dns_records :
      (v.address != null) != (v.cname != null)
    ])
    error_message = "Every record needs exactly one of `address` or `cname`. Check for an entry with both set, or with neither."
  }
}
