# tofu/mikrotik

OpenTofu module for the MikroTik hEX S at `192.168.1.1`, driven by the
[`terraform-routeros/routeros`](https://registry.opentofu.org/providers/terraform-routeros/routeros)
provider over the RouterOS REST API.

It manages **180 resources**: system identity/clock/NTP, service users and
groups, the whole DHCP layer (68 static leases, 7 pools, 6 servers, 7 networks),
the firewall (19 filter rules, 1 NAT rule, 31 address-list entries), and the
L2/L3 layout (bridge, 5 bridge ports, 5 bridge VLANs, 5 VLAN interfaces, 8 IP
addresses, 2 interface lists and their 7 members), and WireGuard (the interface
plus 5 peers). `just mikrotik plan` reports "No changes" against the live router.

`just mikrotik wg-add NAME` adds a WireGuard peer: it generates the keypair
locally, registers only the public half, and writes the client config outside
the repo. No peer private key is in the repo or in tofu state.

Everything was imported, never created — see [BOOTSTRAP.md](BOOTSTRAP.md) for
the wave order, what is deliberately *not* managed (ethernet interfaces,
WireGuard, DNS records, BGP), and the findings each import surfaced.

Device-identifying data (leases, DHCP topology, firewall rules and address
lists) is SOPS-encrypted in `*.sops.yaml` and reaches OpenTofu as JSON
`TF_VAR_*` through the environment; this repo is mirrored publicly.

## Usage

```bash
sops tofu/mikrotik/env.sops.yaml   # one-time: fill in the two BWS_* placeholders

just mikrotik init
just mikrotik plan
just mikrotik apply                # confirm-gated; applies plan.tfplan
```

`just --list mikrotik` shows the rest (`refresh`, `show`, `import`, `shell`,
`run`, `fmt`, `validate`).

## How secrets get in

`bws run --project-id "$BWS_TOFU_PROJECT_ID"` injects every secret in that
Bitwarden project as an environment variable named after the secret's key. The
secrets are therefore named `TF_VAR_routeros_username`, `TF_VAR_routeros_password`,
and so on — OpenTofu picks them up directly, and nothing is ever written to disk.

There is deliberately **no `tofu.tfvars`**. The `.gitignore` still covers
`*.tfvars` as a backstop, but the intended path never creates one.

Non-secret inputs (`TF_VAR_routeros_url`, `TF_VAR_routeros_insecure`) are set as
defaults in `mod.just` and can be overridden from your shell.

The two credentials `bws` itself needs — `BWS_ACCESS_TOKEN` and
`BWS_TOFU_PROJECT_ID` — live SOPS-encrypted in `env.sops.yaml` and are decrypted
into the environment by `mise.toml`. See BOOTSTRAP.md § How the encryption is
wired, particularly the `.sops.yaml` ordering rule — the repo's catch-all would
silently leave these in plaintext.

## State

Local `terraform.tfstate`, gitignored. It contains the router password in
plaintext. See BOOTSTRAP.md § State for why it is not in the cluster.

## Related

- [eleboucher/homelab `tofu/mikrotik/`](https://github.com/eleboucher/homelab/tree/29610155ed6bc9a2b904dc2dc519807f67ebb694/tofu/mikrotik) @ `2961015` — the upstream
  config this is modelled on. BOOTSTRAP.md § Reading the upstream config has a
  table of everything that differs from this network.
- `hardware.md` — the router model and what is plugged into it.
- `dns.md` — how the router's DNS relates to AdGuard and external-dns.
- `core/networking/external-dns/app/helmrelease-mikrotik.yaml` — external-dns
  writes DNS records to this router at runtime. Do not manage those records here.
