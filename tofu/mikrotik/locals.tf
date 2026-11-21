locals {
  # Only the groups this repo owns. RouterOS's built-in `read`, `write` and
  # `full` groups are deliberately absent: they cannot be deleted, nothing here
  # changes them, and declaring them would only create drift to chase.
  #
  # `policy` is a set in the provider schema, so the order below is cosmetic.
  # The `!` entries are explicit denials and are part of what the router stores —
  # dropping one is a real change, not a formatting difference.
  user_groups = {
    # Sized for exactly one job: external-dns writing /ip/dns/static over REST.
    # `rest-api` was denied here, which is why that account still sits in the
    # built-in `write` group instead. Granting it, and dropping winbox/password/
    # web/sensitive at the same time, was safe in one step because the group had
    # no members. Moving the user into it is the follow-up — see BOOTSTRAP.md.
    "dns-admin" = {
      policies = [
        "read", "write", "api", "rest-api",
        "!local", "!telnet", "!ssh", "!ftp", "!reboot", "!policy", "!test",
        "!winbox", "!password", "!web", "!sniff", "!sensitive", "!romon",
      ]
    }

    # Read-only API access for the mktxp exporter (core/monitoring/mktxp, #461).
    # `api` covers api-ssl; `rest-api` stays denied because mktxp speaks the
    # native API protocol, not REST.
    "mktxp_group" = {
      policies = [
        "read", "api",
        "!local", "!telnet", "!ssh", "!ftp", "!reboot", "!write", "!policy",
        "!test", "!winbox", "!password", "!web", "!sniff", "!sensitive",
        "!romon", "!rest-api",
      ]
    }

    # Nightly config export CronJob (core/networking/mikrotik-backup, #2322):
    # `/export show-sensitive` over SSH needs exactly read, ssh and sensitive.
    # Binary `/system backup save` is deliberately NOT automated: on 7.20.4 it
    # fails without both `policy` and `test` (plus write, and ftp to fetch the
    # file over SFTP), and `policy` can edit users, so a stolen key would be
    # admin-equivalent. Binary backups are taken by hand.
    "backup" = {
      policies = [
        "read", "ssh", "sensitive",
        "!local", "!telnet", "!ftp", "!reboot", "!write", "!policy", "!test",
        "!winbox", "!password", "!web", "!sniff", "!api", "!romon",
        "!rest-api",
      ]
    }

    # The account this module authenticates as. Removing `read`, `write`, `api`
    # or `rest-api` here locks tofu out of the router mid-apply.
    "tofu" = {
      policies = [
        "read", "write", "policy", "sensitive", "api", "rest-api",
        "!local", "!telnet", "!ssh", "!ftp", "!reboot", "!test", "!winbox",
        "!password", "!web", "!sniff", "!romon",
      ]
    }
  }

  # The six physical ports. Only the per-port differences live here; everything
  # shared (autoneg, MTU, loop-protect, ARP) is on the resource in network.tf.
  #
  # No SOPS file, unlike the rest of the L2/L3 layout. The one identifying value
  # a port carries is its MAC, and this module deliberately does not manage
  # those — see the resource comment. What is left is generic hardware config.
  #
  # ether1 is the WAN and is the only port not enslaved to the bridge. Of the
  # five LAN-side ports only ether5 carries traffic; ether2, ether3, ether4 and
  # sfp1 have moved zero packets since boot, so this is effectively a two-port
  # router with a switch hanging off ether5.
  ethernet_ports = {
    ether1 = {}
    ether2 = {}
    ether3 = {}
    ether4 = {}

    # The LAN trunk, and the only PoE-capable port on a hEX S. `auto-on` means
    # it will energise a PoE device if one is attached.
    ether5 = {
      poe_out                  = "auto-on"
      poe_priority             = 10
      power_cycle_interval     = "none"
      power_cycle_ping_enabled = false
    }

    sfp1 = { sfp_shutdown_temperature = 95 }
  }

  # Wave 14 -- the IPv6 firewall, entirely RouterOS defconf. Plaintext rather
  # than SOPS: every address here is a well-known reserved range from the stock
  # ruleset, and none of it is device-identifying. Encrypting it would hide a
  # security control for no benefit.
  #
  # ORDER IS LOAD-BEARING, exactly as in Wave 4. Never let tofu CREATE one of
  # these -- a created rule lands at the bottom of its chain, below the final
  # drop. Add it on the router in the right position first, then import.
  ipv6_filters = {
    v6f01 = { chain = "input", action = "accept", connection_state = "established,related,untracked", comment = "defconf: accept established,related,untracked" }
    v6f02 = { chain = "input", action = "drop", connection_state = "invalid", comment = "defconf: drop invalid" }
    v6f03 = { chain = "input", action = "accept", protocol = "icmpv6", comment = "defconf: accept ICMPv6" }
    v6f04 = { chain = "input", action = "accept", protocol = "udp", port = "33434-33534", comment = "defconf: accept UDP traceroute" }
    v6f05 = { chain = "input", action = "accept", protocol = "udp", dst_port = "546", src_address = "fe80::/10", comment = "defconf: accept DHCPv6-Client prefix delegation." }
    v6f06 = { chain = "input", action = "accept", protocol = "udp", dst_port = "500,4500", comment = "defconf: accept IKE" }
    v6f07 = { chain = "input", action = "accept", protocol = "ipsec-ah", comment = "defconf: accept ipsec AH" }
    v6f08 = { chain = "input", action = "accept", protocol = "ipsec-esp", comment = "defconf: accept ipsec ESP" }
    v6f09 = { chain = "input", action = "accept", ipsec_policy = "in,ipsec", comment = "defconf: accept all that matches ipsec policy" }
    v6f10 = { chain = "input", action = "drop", in_interface_list = "!LAN", comment = "defconf: drop everything else not coming from LAN" }
    v6f11 = { chain = "forward", action = "accept", connection_state = "established,related,untracked", comment = "defconf: accept established,related,untracked" }
    v6f12 = { chain = "forward", action = "drop", connection_state = "invalid", comment = "defconf: drop invalid" }
    v6f13 = { chain = "forward", action = "drop", src_address_list = "bad_ipv6", comment = "defconf: drop packets with bad src ipv6" }
    v6f14 = { chain = "forward", action = "drop", dst_address_list = "bad_ipv6", comment = "defconf: drop packets with bad dst ipv6" }
    v6f15 = { chain = "forward", action = "drop", protocol = "icmpv6", hop_limit = "equal:1", comment = "defconf: rfc4890 drop hop-limit=1" }
    v6f16 = { chain = "forward", action = "accept", protocol = "icmpv6", comment = "defconf: accept ICMPv6" }
    v6f17 = { chain = "forward", action = "accept", protocol = "139", comment = "defconf: accept HIP" }
    v6f18 = { chain = "forward", action = "accept", protocol = "udp", dst_port = "500,4500", comment = "defconf: accept IKE" }
    v6f19 = { chain = "forward", action = "accept", protocol = "ipsec-ah", comment = "defconf: accept ipsec AH" }
    v6f20 = { chain = "forward", action = "accept", protocol = "ipsec-esp", comment = "defconf: accept ipsec ESP" }
    v6f21 = { chain = "forward", action = "accept", ipsec_policy = "in,ipsec", comment = "defconf: accept all that matches ipsec policy" }
    v6f22 = { chain = "forward", action = "drop", in_interface_list = "!LAN", comment = "defconf: drop everything else not coming from LAN" }
  }

  # The `bad_ipv6` list the two forward drops above reference.
  ipv6_addr_lists = {
    v6a01 = { list = "bad_ipv6", address = "::/128", comment = "defconf: unspecified address" }
    v6a02 = { list = "bad_ipv6", address = "::1/128", comment = "defconf: lo" }
    v6a03 = { list = "bad_ipv6", address = "fec0::/10", comment = "defconf: site-local" }
    v6a04 = { list = "bad_ipv6", address = "::ffff:0.0.0.0/96", comment = "defconf: ipv4-mapped" }
    v6a05 = { list = "bad_ipv6", address = "::/96", comment = "defconf: ipv4 compat" }
    v6a06 = { list = "bad_ipv6", address = "100::/64", comment = "defconf: discard only " }
    v6a07 = { list = "bad_ipv6", address = "2001:db8::/32", comment = "defconf: documentation" }
    v6a08 = { list = "bad_ipv6", address = "2001:10::/28", comment = "defconf: ORCHID" }
    v6a09 = { list = "bad_ipv6", address = "3ffe::/16", comment = "defconf: 6bone" }
  }

  # Logging actions — the four RouterOS ships with. Three are stock; `remote` is
  # the only one carrying local configuration, and it is why this wave exists.
  #
  # Imported rather than left alone so a change to any of them shows up in a
  # plan. None of these is secret: the syslog target is already in the clear as
  # SVC_SYSLOG_ADDR in components/cluster-vars/cluster-configs.yaml, so unlike
  # the leases and firewall this wave needs no SOPS file.
  logging_actions = {
    "memory" = {
      target = "memory"
      attrs  = { memory_lines = 1000, memory_stop_on_full = false }
    }

    "disk" = {
      target = "disk"
      attrs = {
        disk_file_name      = "flash/log"
        disk_file_count     = 2
        disk_lines_per_file = 1000
        disk_stop_on_full   = false
      }
    }

    "echo" = {
      target = "echo"
      attrs  = { remember = true }
    }

    # Points at Alloy's syslog listener (SVC_SYSLOG_ADDR:1514, the LoadBalancer
    # in core/monitoring/alloy/app/syslog-service.yaml). UDP on purpose: RouterOS
    # sends `syslog` (RFC 3164) with no delimiter over TCP, so only UDP frames
    # correctly; Alloy has a matching udp/rfc3164 listener. Before #2073 this
    # was UDP against a TCP-only listener and had never delivered a line.
    "remote" = {
      target = "remote"
      attrs = {
        remote             = "10.11.0.207"
        remote_port        = 1514
        remote_protocol    = "udp"
        remote_log_format  = "syslog"
        src_address        = "0.0.0.0"
        syslog_facility    = "daemon"
        syslog_severity    = "auto"
        syslog_time_format = "bsd-syslog"
        vrf                = "main"
      }
    }
  }

  # Logging rules, in the order the router holds them. Unlike firewall rules
  # these carry no ordering semantics — every matching rule fires — so the map
  # is safe.
  logging_rules = {
    "info-memory"    = { topics = ["info"], action = "memory" }
    "error-memory"   = { topics = ["error"], action = "memory" }
    "warning-memory" = { topics = ["warning"], action = "memory" }
    "critical-echo"  = { topics = ["critical"], action = "echo" }

    # Someone's debugging session, left switched off. Kept so it is visible in
    # the repo rather than lurking on the device.
    "dhcp-debug" = { topics = ["debug"], action = "memory", prefix = "dhcp", disabled = true }

    # The rules that feed the remote action above. One per topic: RouterOS ANDs
    # the topics within a rule, so the imported single rule with
    # ["info","critical","warning","error"] could never match a message - the
    # second reason (after the transport mismatch) nothing ever reached Loki.
    "remote-info"     = { topics = ["info"], action = "remote" }
    "remote-warning"  = { topics = ["warning"], action = "remote" }
    "remote-error"    = { topics = ["error"], action = "remote" }
    "remote-critical" = { topics = ["critical"], action = "remote" }
  }

  # Service accounts only. `admin` and `wynnj` are deliberately unmanaged: they
  # are the break-glass path back in if this module locks itself out, and their
  # passwords are not in Bitwarden. Tofu ignores router users absent from state,
  # so leaving them out costs nothing.
  users = {
    # Was in the built-in `write` group, which also granted ssh, telnet, sniff,
    # password and sensitive. dns-admin is read,write,api,rest-api — exactly
    # what mirceanton/external-dns-provider-mikrotik documents as required, and
    # all its v1.6.3 source ever touches is /rest/ip/dns/static and
    # /rest/system/resource.
    "external-dns" = {
      group   = "dns-admin"
      address = null
    }

    "tofu" = {
      group   = "tofu"
      address = "192.168.1.0/24,10.10.2.0/24"
    }

    # mktxp exporter (#461). Pods reach the router SNATed to their node's IP, so
    # the node subnet is the only source that needs to log in. Created over REST
    # with its password and imported; the password lives in the mktxp-secret
    # SOPS file in core/monitoring/mktxp.
    "mktxp" = {
      group   = "mktxp_group"
      address = "192.168.1.0/24"
      comment = "mktxp exporter (#461)"
    }

    # Config backup CronJob (#2322). SSH-key only: the password set at creation
    # over REST was random and discarded, and RouterOS refuses SSH password
    # login for a user that has a key. The key is routeros_system_user_sshkeys.backup.
    "backup" = {
      group   = "backup"
      address = "192.168.1.0/24"
      comment = "config backup CronJob (#2322)"
    }
  }
}
