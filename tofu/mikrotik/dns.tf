# Static DNS records that were created by hand.
#
# THE OWNERSHIP BOUNDARY IS THE WHOLE POINT OF THIS FILE.
#
# /ip/dns/static holds 282 records and THREE things write to it. Only 34 are
# hand-made. Managing one of the other 248 would put two writers in a fight
# over the same object, each reverting the other on its own schedule.
#
#   external-dns (211 records)
#     Runs with `policy: sync` and reconciles from Kubernetes Services and
#     Ingresses -- core/networking/external-dns/app/helmrelease-mikrotik.yaml.
#     Three signals, any one disqualifying:
#       a. name starts with `k8s.mikrotik-dns.` -- its TXT registry records
#          (`txtPrefix` in the HelmRelease). 103 of them.
#       b. comment is exactly `External-DNS` -- stamped by the webhook. 105.
#       c. name is claimed by a registry TXT: strip the prefix and the `a-`
#          type marker off a registry name and you get the FQDN it owns. 55
#          more that carry neither of the first two markers.
#     Signal (c) is not redundant. Those 55 have no stamp and no prefix and
#     look hand-made; importing them would have been the mistake this file
#     exists to prevent.
#
#   the DHCP lease scripts (37 records)
#     Five of the six DHCP servers carry a ~2.9KB `lease-script` that adds and
#     removes a DNS record as each lease comes and goes, under a per-VLAN
#     domain. Comment prefix `dhcp-lease-script_`, in two suffix forms:
#     `_comment` and `_lease-hostname`. Both count.
#     These churn: a device renewing its lease gets a NEW record `.id`. That is
#     how they were caught -- nine imports failed because the id captured
#     seconds earlier was already stale. An import that had happened to win the
#     race would have looked fine and then fought the script forever.
#
#   this file (34 records)
#     Everything left. All TTL 1d, which is itself a useful signal: every
#     lease-script record is 15m.
#
# Adding a record: add it to dns.sops.yaml with the next free key. Do not add
# anything Kubernetes could own instead -- that belongs on an Ingress
# annotation. Do not add anything a DHCP lease would create.
resource "routeros_ip_dns_record" "this" {
  for_each = var.dns_records

  name = each.value.name
  type = each.value.type

  # Exactly one of these per record; the variable's validation enforces it.
  # 26 A records, 8 CNAMEs.
  address = each.value.address
  cname   = each.value.cname

  # 1d on every one of these, which is not the provider default. Omitting it
  # would rewrite all 34 on the first apply.
  ttl = each.value.ttl

  comment  = each.value.comment
  disabled = each.value.disabled
}
