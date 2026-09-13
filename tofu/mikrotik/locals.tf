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

    # Orphan: no user is in this group and mktxp is not deployed in this repo.
    # Imported so the state matches the device; a candidate for removal.
    "mktxp_group" = {
      policies = [
        "read", "api",
        "!local", "!telnet", "!ssh", "!ftp", "!reboot", "!write", "!policy",
        "!test", "!winbox", "!password", "!web", "!sniff", "!sensitive",
        "!romon", "!rest-api",
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
    # in core/monitoring/alloy/app/syslog-service.yaml).
    #
    # NOTE the protocol mismatch, mirrored here as found rather than fixed:
    # this sends UDP, and that listener is TCP-only — the Service, the container
    # port and `loki.source.syslog`'s `protocol = "tcp"` all agree. Promtail was
    # TCP before it, so these logs have never arrived. Changing it is not a
    # one-word fix: the router sends BSD-format (RFC3164) and Alloy's syslog
    # component expects RFC5424, so format has to be settled alongside protocol.
    # Tracked separately; this wave is an import.
    "remote" = {
      target = "remote"
      attrs = {
        remote             = "192.168.1.207"
        remote_port        = 1514
        remote_protocol    = "udp"
        remote_log_format  = "default"
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

    # The one rule that feeds the remote action above.
    "remote-syslog" = { topics = ["info", "critical", "warning", "error"], action = "remote" }
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
  }
}
