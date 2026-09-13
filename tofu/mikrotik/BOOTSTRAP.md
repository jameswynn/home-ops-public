# Bootstrapping the MikroTik under OpenTofu

A roadmap for bringing the hEX S under `tofu/mikrotik/` without an outage.
Modelled on eleboucher/homelab's [`tofu/mikrotik/`](https://github.com/eleboucher/homelab/tree/29610155ed6bc9a2b904dc2dc519807f67ebb694/tofu/mikrotik) — pinned at
`2961015` (2026-08-19) — adapted to this router, this cluster, and Bitwarden
instead of 1Password.

Delete this file once the waves are done.

---

## The rule that makes this safe

**Import first, apply second. Never let tofu create a resource that already
exists on the router.**

The routeros provider does not merge with what is on the device — an unimported
resource is a *create*, and for singleton config (identity, DNS server, DHCP
server) a create silently replaces the running config. Every wave below is:

```
write the .tf  →  import  →  plan until it says "No changes"  →  only then edit
```

A wave is not done until `just mikrotik plan` is clean against the *existing*
router. That clean plan is the proof the model matches reality; it is also the
baseline that makes the next diff readable.

## What this router already does that can break

Three live dependencies. Each has a wave that is deliberately late or excluded.

| Dependency | Where it lives | How tofu could break it |
| --- | --- | --- |
| **DNS records** | `external-dns` writes `*.wynning.tech` / internal records to this router at runtime (`core/networking/external-dns/app/helmrelease-mikrotik.yaml`, txtPrefix `k8s.mikrotik-dns.`) | Managing `routeros_ip_dns_record` here makes tofu and external-dns fight; tofu deletes records it did not create |
| **BGP + L2 to cilium** | `core/kube-system/cilium/app/networks.yaml` — `localASN: 64514` → `peerASN: 64514` at `192.168.1.1`, plus a `CiliumL2AnnouncementPolicy` | Rewriting the router's BGP instance drops the session; LoadBalancer VIPs stop being advertised |
| **LoadBalancer IPs** | cilium pools: `.5`, `.6`, `.53`, `.200`, `.201`, `.202–.254` | A DHCP pool overlapping those hands a cluster VIP to a laptop. Upstream's `192.168.1.3-200` pool collides with four of them |

That last one is worth stating plainly: **the DHCP pool must exclude
192.168.1.5, .6, .53, .200, .201, and .202–.254.** Anything in `.3–.52` and
`.54–.199` is fair game.

---

## Prerequisites

### 1. Tooling

```bash
mise trust && mise install     # brings in opentofu 1.12.6 and bws 2.1.0
```

### 2. A dedicated router user

Do not point tofu at `admin`, and do not reuse the `external-dns` user (it is
scoped to DNS writes). Create a `tofu` user on the router with a group that has
`read,write,api,rest-api,policy,sensitive` and nothing else — `policy` is needed
to manage users and groups later, `sensitive` to read WireGuard keys.

Restrict it by source address to the LAN:

```
/user group add name=tofu policy=read,write,api,rest-api,policy,sensitive,!local,!telnet,!ssh,!ftp,!reboot,!winbox,!web,!sniff,!romon
/user add name=tofu group=tofu address=192.168.1.0/24 password="<generated>"
```

Generate the password with `openssl rand -hex 32` — 256 bits in a `[0-9a-f]`
charset:

```bash
openssl rand -hex 32
```

Use `-hex`, not `-base64`. Base64 emits `+`, `/`, and `=`; `/` is the RouterOS
command-path separator, so an unquoted `password=` value containing one is a
parsing hazard. `bw generate` is worse again — it emits `$`, `!`, `*`, and `%`,
which are hazardous in the shell as well as on the router. Hex needs no escaping
in the RouterOS console, the shell, a `bws` argument, or JSON. If you ever hit a
length limit on the router, `openssl rand -hex 24` is 192 bits and still far
past anything that matters here.

Quote the value in the `/user add` anyway — cheap, and it keeps the line
copy-pasteable if you ever swap generators.

### 3. Bitwarden Secrets Manager

Create a project (e.g. `tofu-mikrotik`) and a service account with read access
to it. `bws run` injects **every secret in the project** by key name, so the
project must contain only these, and they must be named exactly:

| Secret key | Value | Added in |
| --- | --- | --- |
| `TF_VAR_routeros_username` | `tofu` | Prereqs |
| `TF_VAR_routeros_password` | the password from step 2 | Prereqs |
| `TF_VAR_wireguard_private_key` | the WireGuard interface's private key | Wave 6a |
| `AWS_ACCESS_KEY_ID` | the `tofu-state` bucket key | Wave 7 |
| `AWS_SECRET_ACCESS_KEY` | its secret | Wave 7 |
| `TF_ENCRYPTION` | a `key_provider "pbkdf2"` HCL fragment | Wave 7 |

The last four are set up in their own waves and are not needed to get started;
each wave says where its value comes from. `just mikrotik`'s preflight checks
for all of them, so a missing one is a sentence pointing at the right wave
rather than a provider error.

`bws secret create` takes the value as a positional argument, which puts it in
your shell history and briefly in `ps` output. Generate straight into a variable
instead, use it for both the router and Bitwarden, then drop it:

```bash
pw=$(openssl rand -hex 32)
echo "$pw"        # paste into the /user add above, then clear the scrollback

bws secret create TF_VAR_routeros_username tofu "$BWS_TOFU_PROJECT_ID"
bws secret create TF_VAR_routeros_password "$pw" "$BWS_TOFU_PROJECT_ID"
unset pw
```

Then make both available to your shell. This is already wired up — the
credentials live SOPS-encrypted in `tofu/mikrotik/env.sops.yaml`, which
`mise.toml` decrypts into the environment. Fill it in:

```bash
sops tofu/mikrotik/env.sops.yaml
```

```yaml
BWS_ACCESS_TOKEN: <service account token>
BWS_TOFU_PROJECT_ID: <project uuid>
```

Both ship as `REPLACE_ME`; `just mikrotik`'s preflight rejects that value with a
pointer back to this command, so a half-finished setup fails loudly rather than
as a confusing Bitwarden auth error.

Confirm mise picked them up:

```bash
mise env | grep BWS_
```

Nothing else is needed — no `mise.local.toml`, no exports in your shell rc. On a
machine without the age key, mise degrades quietly (see § How the encryption is
wired) and preflight tells you what is missing.

Verify before going further:

```bash
just mikrotik run version      # exercises preflight + bws + tofu
just mikrotik plan             # expect: No changes
```

### 4. A configuration backup you can actually restore

Pull them **outside the repo** — the `.rsc` export contains credentials in clear
text, and the pre-commit hook runs `gitleaks dir .`, which scans the working tree
and so trips on them even when gitignored:

```bash
mkdir -p ~/router-backups
ssh admin@192.168.1.1 '/system backup save name=pre-tofu'
ssh admin@192.168.1.1 '/export terse file=pre-tofu'
scp admin@192.168.1.1:pre-tofu.{backup,rsc} ~/router-backups/
```

Keep both. The `.rsc` export is what you will read while writing the `.tf`
files; the `.backup` is what you restore from if a wave goes wrong.

`*.rsc` and `*.backup` are in `.gitignore` as a backstop, but that only stops a
commit — it does not stop gitleaks. Keep them out of the working tree.

---

## Wave order

Ordered by blast radius, lowest first. Each wave is one commit and one PR.

### Wave 0 — scaffold *(done)*

Provider, variables, `mod.just`, no resources. `plan` says "No changes".

### Wave 1 — inert system config *(done)*

`system.tf`: `routeros_system_identity`, `routeros_system_clock`,
`routeros_system_ntp_client`. Nothing here is on a data path.

**Import IDs for RouterOS singletons are a literal `.`** — not an internal
`.id`, and `/rest/system/identity` does not return one to look up. After import
the provider rewrites the id to its canonical form (`system.identity`,
`system.clock`, `system.ntp.client`), which is what you will see in state:

```bash
just mikrotik import routeros_system_identity.this .
just mikrotik import routeros_system_clock.this .
just mikrotik import routeros_system_ntp_client.this .
just mikrotik plan          # No changes.
```

Read the current values first so the `.tf` mirrors them — for these three the
REST API is quicker than the `.rsc` export:

```bash
just mikrotik shell
for ep in system/identity system/clock system/ntp/client; do
  curl -sk -u "$TF_VAR_routeros_username:$TF_VAR_routeros_password" \
    "https://192.168.1.1/rest/$ep" | jq
done
```

What was found: identity `MikroTik`; timezone `America/Chicago` with
`time-zone-autodetect` on, which already matches `CLUSTER_TZ`.

**NTP was off, now enabled.** `/rest/system/ntp/client` imported as
`enabled: false` with no servers — the router was not disciplining its clock at
all. It was imported that way to keep the wave a pure import, then enabled as a
separate change, which doubled as the first exercise of the apply path:

```hcl
enabled = true
servers = ["time.cloudflare.com"]
```

`time.cloudflare.com` is anycast, so a single entry is already geographically
redundant, and the router resolves it via its own DNS (1.1.1.1). Confirmed
`status: synchronized`, stratum 3, offset 0.434 ms.

Plan was `0 to add, 1 to change, 0 to destroy` — the other two resources did not
appear, which is the signal that the import is holding.

**Verify:** `plan` clean; router still reachable.

### Wave 2 — users and groups *(imported)*

`locals.tf` (`user_groups`, `users` maps) + `users.tf` (the two `for_each`
resources). Imported clean on the first plan.

Unlike the Wave 1 singletons, these import **by name**:

```bash
just mikrotik import 'routeros_system_user_group.this["tofu"]' tofu
just mikrotik import 'routeros_system_user.this["external-dns"]' external-dns
```

Quote the address as shown. `bws run` joins its argv with spaces and re-runs the
result through `sh -c`, consuming one layer of quoting — an unescaped
`this["tofu"]` reaches tofu as `this[tofu]` and fails with "Index brackets must
contain either a literal number or a literal string". The `import` recipe
re-escapes the quotes for you; the same trap applies to anything else you pass
through, notably `-target`.

Read the current state from `/rest/user` and `/rest/user/group`:

```bash
just mikrotik shell
curl -sk -u "$TF_VAR_routeros_username:$TF_VAR_routeros_password" \
  https://192.168.1.1/rest/user/group | jq -r '.[] | "\(.name)\t\(.policy)"'
```

**What is and is not managed.** Only what this repo owns:

- Groups: `dns-admin`, `mktxp_group`, `tofu`. The built-in `read`/`write`/`full`
  groups are left alone — they cannot be deleted and nothing here changes them.
- Users: `external-dns`, `tofu`. **`admin` and `wynnj` are deliberately
  unmanaged** — they are the way back in if this module ever locks itself out,
  and their passwords are not in Bitwarden.

An earlier draft of this file claimed unimported users would be proposed for
deletion. That is wrong: tofu only destroys what is in its state, so a router
user absent from `locals.users` is simply invisible to it. Leaving the
break-glass accounts out costs nothing.

`policy` is a set in the provider schema, so ordering is cosmetic — but the `!`
entries are explicit denials the router stores, and dropping one is a real
change.

Keep `lifecycle { ignore_changes = [password] }`. Passwords are set out of band
in Bitwarden; managing them here would put credentials in state and risk
rotating the very one this module authenticates with.

**Three findings from the import:**

1. ~~**`dns-admin` denies `rest-api`**~~ — **fixed.** external-dns talks to the
   router over REST, so the group named for that job could not do it, which is
   almost certainly why the account ended up in `write`. Granted `rest-api`, and
   dropped `winbox`/`password`/`web`/`sensitive` in the same change since the
   group had no members and therefore nothing to break. Now
   `read,write,api,rest-api` plus explicit denials — matching what upstream's
   `external_dns` group grants.
2. **`external-dns` is still in the built-in `write` group**, which grants
   `ssh`, `telnet`, `sniff`, `password` and `sensitive` — far beyond writing DNS
   records. `dns-admin` is now ready to receive it; see Wave 2b.
3. **`mktxp_group` is an orphan** — no user is in it and mktxp is not deployed
   anywhere in this repo. Imported so state matches the device; a candidate for
   deletion once confirmed unused.

### Wave 2b — move external-dns onto least privilege *(done)*

`external-dns` moved from the built-in `write` group to `dns-admin`. Plan was
`0 to add, 1 to change, 0 to destroy` — one attribute, with `password` among the
untouched hidden attributes thanks to the `ignore_changes` lifecycle.

It lost `ssh`, `telnet`, `ftp`, `local`, `reboot`, `winbox`, `web`, `sniff`,
`password`, `policy` and `sensitive`, keeping `read,write,api,rest-api`.

**Required policies were confirmed, not inferred.** The deployed webhook is
`ghcr.io/mirceanton/external-dns-provider-mikrotik:v1.6.3`, whose README states:

> This local user needs `api` and `rest-api` policies to authenticate and use
> the RouterOS HTTP APIs. Additionally, this local user needs `read` and `write`
> policies to manage static DNS.

Reading v1.6.3's source, the only router paths it touches are
`/rest/ip/dns/static` and `/rest/system/resource`.

**Verified after the change:**

| Check | Result |
| --- | --- |
| Startup credential check | `connected to board hEX S running RouterOS version 7.20.4` |
| `GET /rest/system/resource` | 200 |
| `GET /rest/ip/dns/static` | 200, 282 records — unchanged from baseline |
| Writes | 10 attempts, 0 failures: `201 Created` on PUT, `204 No Content` on DELETE |

Reproduce with:

```bash
kubectl -n networking rollout restart deploy/mikrotik-dns
kubectl -n networking logs deploy/mikrotik-dns -c webhook | head -20
kubectl -n networking logs deploy/mikrotik-dns -c webhook \
  | grep -E 'sending (PUT|DELETE)|request succeeded|request failed'
```

Note the container name: the deployment runs `external-dns` and `webhook`, and
the router calls are only in `webhook`.

**Do not trust the probes.** `/healthz` and `/readyz` are static handlers that
`WriteHeader(http.StatusOK)` unconditionally and never touch the router, so a
green pod says nothing about connectivity. The startup path is the useful
signal instead: `GetSystemInfo()` runs inside `NewMikrotikProvider`, so an auth
or `read` failure aborts construction and crashes the pod. The one genuinely
silent mode is `read` succeeding while `write` fails, which is why the write
status codes above are the load-bearing evidence.

**Rollback:** set `group` back to `"write"` and apply; or over SSH,
`/user set external-dns group=write`.

### Later: system services are wide open

Not part of any wave yet, noted while checking whether the `api` policy grants
anything real. `/rest/ip/service` shows all of these enabled:

| Service | Port | Note |
| --- | --- | --- |
| `api` | 8728 | **plaintext** binary API — so granting the `api` policy is not inert |
| `api-ssl` | 8729 | |
| `btest` | 2000 | bandwidth-test server; a standard thing to disable |
| `winbox` | 8291 | |
| `discover` | 5678 | MNDP/CDP neighbour discovery |
| `resolver` | 5353 | |

`telnet`, `ftp` and plain `www` do not appear, which is good. There is also a
`wireguard-wireguard1` service on 13231, so a WireGuard interface already
exists on this router and is not yet modelled here.

### Wave 3a — static leases *(done)*

`dhcp.tf` + `leases.sops.yaml`. All 68 reservations imported; plan clean.

**The lease table is a device inventory, so it is encrypted.** This repo is
mirrored to a public repo by `.forgejo/workflows/publish.yaml`, which does
`git add .` over the whole tree — anything tracked is published. MAC OUIs
identify vendors and the comments name devices, so the data lives in
`leases.sops.yaml` and reaches tofu as a JSON `TF_VAR`:

```
leases.sops.yaml → mod.just `export TF_VAR_static_leases := shell(sops -d …)`
                 → environment → bws run → tofu
```

Three things make that work, each verified:

- **Map keys are opaque handles** (`lease01`…`lease68`), never the address or
  MAC. SOPS encrypts *values, not keys* — a map keyed by IP would publish
  exactly what this is hiding. Only the shape leaks: 68 entries with
  address/mac/comment fields.
- **It goes through the environment, never a command line.** `bws run` joins
  argv and re-runs it through `sh -c`, which would mangle JSON braces and
  quotes. Env vars pass through untouched.
- **The `shell()` call falls back to `{}`**, so `just --list` still works on a
  machine without the age key.

`var.static_leases` is deliberately **not** `sensitive`: `for_each` rejects
sensitive values, and marking it would redact plan output to
"(sensitive value)" — unreviewable at exactly the moment you need to read it.
Privacy comes from encryption at rest, not from hiding it locally.

To edit: `sops tofu/mikrotik/leases.sops.yaml`, then `just mikrotik plan`.

**Two attributes that produced drift, and one that nearly bit:**

- `client_id` — 39 leases carry a DHCP client identifier. Omitting it does not
  leave it alone; tofu deletes it, changing how the router matches those
  clients. It is modelled.
- `disabled` — two leases are disabled on the router. It did not show up as
  drift (the provider treats it as computed when unset), but it is modelled
  explicitly so an omission cannot silently re-enable them later.
- `block_access` — the router reports `blocked: false` on all 68, but the
  provider leaves it null on import against a schema default of `false`. That
  is an import artefact, not drift, so it is in `ignore_changes`.

A benign warning on every plan: `Field 'age' not found in the schema` — the
provider does not model a read-only field RouterOS returns on one lease.

### Wave 3b — DHCP servers, pools and networks *(done)*

7 pools, 6 servers, 7 networks imported; plan clean. Topology and comments live
encrypted in `dhcp.sops.yaml`, exported as `TF_VAR_dhcp` by the same mechanism
as the leases — the subnets map the segmentation, and the network comments carry
internal domain names this repo treats as secret elsewhere.

**The router is already segmented**, contrary to what an earlier draft assumed:

| Server | Interface | Pool |
| --- | --- | --- |
| `defconf` | bridge | `default-dhcp` |
| `Management` | Management | `Management` |
| `Servers` | Servers | `Servers` |
| `Workstations` | Workstations | `Workstations` |
| `IoT` | IoT | `IoT` |
| `Guests` | Guest | `Guests` |

**The pool/LoadBalancer collision check, done properly.** Every pool range was
expanded and tested against the cilium reservations from
`core/kube-system/cilium/app/networks.yaml`:

| Pool | Live | Overlaps cilium LB |
| --- | --- | --- |
| `default-dhcp`, `Management`, `Servers`, `IoT`, `Guests`, `Workstations` | yes | none |
| **`Servers-Old`** | **no** | **all six** — adguard ×2, k8s-gateway, nginx internal + external, and the .202–.254 pool |

No *live* pool overlaps, so the danger flagged at the top of this file is real
but currently unarmed. `Servers-Old` (192.168.1.2–254) is referenced by nothing:
no DHCP server, no PPP or hotspot profile, no PPP secret, no
PPPoE/OVPN/L2TP/PPTP/SSTP server, no DHCP relay, and no other pool's `next-pool`
chain. `/ip/pool/used` shows zero addresses allocated from it. It is a leftover
from the migration off 192.168.1.0/24.

**Kept deliberately** (decision 2026-08-22) — deleting it was proposed and
declined, so leave it alone rather than re-proposing it. What still holds is the
reason it was flagged: the range covers *every* cilium reservation (adguard
`.5`/`.6`, k8s-gateway `.53`, both nginx VIPs, and the whole `.202–.254`
LoadBalancer block). It is one `address-pool=Servers-Old` away from leasing
cluster VIPs to clients. **Never point a DHCP server at this pool**, and if
192.168.1.0/24 is ever brought back into DHCP service, narrow the range first.

Note also that the `192.168.1.0/24` network entry has no DHCP server bound to
it: that segment is static-only now.

**A trap worth remembering.** `just mikrotik plan` writes `plan.tfplan`, and
`tofu show -json plan.tfplan` happily reads a *previous* plan when the current
one failed. A "0 resources changing" reading was taken from a stale file while
the plan was in fact erroring on `ranges` (`list of string required, but have
string` — RouterOS returns it comma-separated, the provider wants a list).
Delete `plan.tfplan` before trusting it, or check the plan's exit code.

### Wave 4 — firewall *(imported)*

`firewall.tf` + `firewall.sops.yaml`. 19 filter rules, 2 NAT rules and 31
address-list entries imported; plan clean. Plain resources, not the upstream
`mirceanton/terraform-modules-routeros` module — one less supply-chain edge, and
ordering is handled as described below rather than by an `order` attribute.

**Only static entries exist to manage.** `/ip/firewall/mangle` and
`/ip/firewall/raw` hold *nothing* but RouterOS's dynamic fasttrack counter
rules, so this wave adds no resources for them at all. The filter chain has one
such dynamic rule too, and it is excluded. Do not "fix" their absence later.

Import IDs are the RouterOS `.id` (`*4CC`, `*11`, …), read from
`/rest/ip/firewall/{filter,nat,address-list}`. 52 imports is too many for
`just mikrotik import` one at a time; a batch script inside a single `bws run`
is the practical path, but it must re-export what `mod.just` normally provides
(`TF_VAR_routeros_url` at minimum) or every import fails on an unset variable.

#### Ordering is not modelled, deliberately

Chain order *is* the security model, and neither `for_each` nor `place_before`
preserves it: `place_before` is a create-time hint only. The resolution is that
**tofu never creates a rule here** — every rule was imported, so tofu only
updates in place and the router's order is untouched.

That makes exactly one operation dangerous: **adding a rule**. Add it on the
router by hand, in the right position, then import it. Do not let tofu create
it; a new rule lands at the bottom of its chain, which for anything in `input`
or `forward` means below the final drop.

If that ever stops being good enough, `routeros_move_items` takes an explicit
`sequence` of ids and asserts the order — call it Wave 4b. It is not wired up
here because turning it on is itself a reordering apply.

The map keys carry the order as documentation: `f01`…`f19` is the router's rule
order top to bottom. They are otherwise meaningless handles (see § privacy in
Wave 3a — the same reasoning applies, more so: the ruleset maps the network's
segmentation and the address lists name individual devices).

#### The drift the import caught

First pass omitted `out_interface_list` from the filter resource — present in
the NAT resource, missing from the filter one. Plan was `0 to add, 2 to change`,
both removing `out-interface-list=WAN`:

| Rule | Is | Would have become |
| --- | --- | --- |
| `Allow Privileged IoT to WAN` | accept IoT → internet | accept IoT → **everywhere**, above the deny |
| `Drop IoT to WAN` | drop IoT → internet | drop IoT → **everywhere** |

The second one is a total IoT blackhole and the first quietly voids the IoT
segmentation. This is the same failure mode as `client_id` in Wave 3a: omitting
an attribute does not leave it alone, it deletes it. **The clean plan is the
only thing standing between an unmodelled attribute and an outage.**

#### Wave 4b — close the dangling WAN port-forward *(done)*

`dstnat` rule `n02` — "Forward WAN 443 to envoy-external" — forwards public TCP
443 to `192.168.1.222`. That address no longer exists:

- Commit `22771f670` (2026-08-07) *"retire cloudflared and the envoy-external
  gateway"* removed the Gateway that held it, along with
  `SVC_ENVOY_GATEWAY_EXTERNAL: 192.168.1.222` from `components/cluster-vars`.
  Nothing in the repo references `.222` any more.
- No Service holds it (`kubectl get svc -A`); the router's ARP entry for it is
  `complete=false`.
- **`.222` is inside the cilium `pool` block `192.168.1.202–254`** and is not
  reserved by anything, so cilium is free to hand it to the next LoadBalancer
  service that asks.

So the rule is currently forwarding the internet to nowhere, and will silently
start forwarding it to an arbitrary cluster service — bypassing heimdall,
towonel and the Coraza WAF — the moment `.222` gets allocated. The retirement
commit's own message notes envoy-external was seeing "bot 404s and
route_not_found scans against the bare WAN IP"; those arrived through this rule,
and still do.

**Removed.** `n02` was dropped from `firewall.sops.yaml`; plan was
`0 to add, 0 to change, 1 to destroy` and named only rule `*2`. Public inbound
443 is now closed at the router, and `/ip/firewall/nat` holds nothing but the
`defconf: masquerade` rule.

Two things were checked first, because deleting a NAT rule is only as final as
the paths that can recreate one:

- **UPnP is disabled** (`/ip/upnp` → `enabled: false`, no interfaces), so no
  dynamic forward can reappear behind this.
- **There is no port-80 forward** and never was in this ruleset — an earlier
  note claimed 80 *and* 443 were forwarded to `.222`. Only 443 existed.

If a direct WAN path is ever wanted again, pin the target out of the cilium
pool (`192.168.1.202–254`) first — that is what made this rule dangerous rather
than merely dead.

The `Servers-Old` pool from Wave 3b is the remaining leftover of the same
migration.

#### Other things worth knowing about this ruleset

- **LAN access to `input` is interface-based, not address-based.** An earlier
  draft of this file said to "confirm an accept rule for `192.168.1.0/24` to
  `input` exists above the final drop". There is no such rule. Protection is
  `drop all not coming from LAN` with `in-interface-list=!LAN`, and the `LAN`
  list contains `bridge`, `Management`, `Servers`, `Workstations`, `IoT` and
  `Guest` (`WAN` is `ether1`). **Removing an interface from the `LAN` list locks
  that segment out of the router** — which makes Wave 5 more dangerous than it
  looks, since interface renames pass through this list.
- **The `jump to kid-control` rule is static and is managed here** (`f01`, the
  first rule in `forward`). The chain it jumps to is populated *dynamically* by
  `/ip/kid-control` on a schedule, so `/ip/firewall/filter` grows and shrinks
  dynamic rules through the day. Those are invisible to tofu, which is correct —
  but do not read a changing rule count as drift.
- **Two WireGuard `input` accepts sit above `defconf: drop invalid`** (`f03`,
  `f04`, for udp/13231 and `10.10.5.0/24`). Harmless in practice, but it means
  invalid-state WireGuard packets are accepted. Worth tidying if the ruleset is
  ever reordered.
- Five address-list entries are disabled rather than deleted (devices that come
  and go). `disabled` is modelled explicitly so an omission cannot re-enable
  them.

**Verify after any change here:** SSH from LAN still works; from tailscale still
works; a WAN probe still blocked.

**Rollback:** backup restore. Assume you will lose remote access if you get this
wrong — do it while physically near the router.

### Wave 5 — interfaces, VLANs and addressing *(imported)*

`network.tf` + `network.sops.yaml`. 33 resources — 1 bridge, 5 bridge ports,
5 bridge VLANs, 5 VLAN interfaces, 8 IP addresses, 2 interface lists and 7 list
members. Clean on the first plan.

**Correction to two earlier drafts of this file.** The first said the VLAN split
"does not exist yet"; it does. The second called this a redesign; it is not — it
is an import of a live, working design. Nothing here was changed.

#### The topology, as found

`bridge` runs with `vlan-filtering=true` and `pvid=1`. Five VLAN interfaces hang
off it:

| VLAN | Interface | Gateway | DHCP pool |
| --- | --- | --- | --- |
| 10 | `Management` | 192.168.99.1/24 | `Management` |
| 100 | `Servers` | 10.1.0.1/16 **and** 192.168.1.1/24 | `Servers` |
| 200 | `Workstations` | 10.10.2.1/24 | `Workstations` |
| 300 | `IoT` | 10.3.0.1/24 | `IoT` |
| 400 | `Guest` | 10.4.0.1/24 | `Guests` |

Plus `192.168.88.1/24` on the bridge itself (`defconf`, VLAN 1) and
`10.10.5.1/24` on `wireguard1`.

**`Servers` carries two subnets.** 10.1.0.0/16 is the new one; 192.168.1.0/24 is
the old one, still live — it is where the cluster's LoadBalancer VIPs and the
router's own management address sit. That is why the `Servers-Old` pool exists
and why 192.168.1.0/24 has a DHCP *network* entry but no DHCP *server*.

**Port layout — `ether5` is the only trunk.** It is tagged on all five VLANs.
`ether2` is an untagged Management access port (`pvid=10`, currently unplugged).
`ether3`, `ether4` and `sfp1` sit on `pvid=1` and are unused. `ether1` is WAN.

That makes ether5 a single point of failure for every VLAN, and it makes any
edit to a `tagged` set a whole-VLAN outage if it drops ether5.

**The WAN address is RFC1918** — `192.168.100.66/24`, DHCP-assigned on `ether1`,
which is the AT&T BGW320-500 handing out its DMZplus/passthrough subnet rather
than a public address. It is dynamic, so tofu does not own it.

#### What is deliberately not managed

- **Ethernet interfaces.** All six are on stock settings and
  `routeros_interface_ethernet` carries a large computed surface; importing them
  buys nothing here.
- **`wireguard1` and its 5 peers.** Managing them would write private keys into
  local plaintext state. See Wave 6.
- **The dynamic entries**: the DHCP-assigned WAN address, and the dynamic
  `vlan-ids=1` bridge VLAN entry. Tofu must not own either.
- **The built-in `all`/`none`/`dynamic`/`static` interface lists**, which cannot
  be deleted and which nothing here changes.

#### Everything is modelled, defaults included

Unlike the earlier waves, `network.tf` carries every attribute RouterOS returns,
including values that are simply the default (`path_cost`, `point_to_point`,
`multicast_router`, and so on). That is deliberate: omitting an attribute
deletes it, and this is the one wave where a deleted attribute partitions the
network. The data is generated from the router rather than hand-written, so the
verbosity costs nothing to maintain.

#### Finding: the forward chain has no default drop

Reading the imported ruleset end to end, the `forward` chain finishes with
`Deny IoT to Local Networks` and then simply stops. RouterOS's default policy
for an unmatched packet is **accept**, so inter-VLAN forwarding is open except
where a rule says otherwise — and the only rules that say otherwise are about
IoT (`10.3.0.0/24`).

Concretely, as the rules stand: **Guest (10.4.0.0/24) can reach Servers
(10.1.0.0/16 and 192.168.1.0/24), Workstations and Management.** So can
Workstations. The segmentation that exists is IoT-only; the rest is topological,
not enforced.

The shape of the ruleset suggests this was meant to be a default-drop design
that was never finished: `Allow Local Networks to Universal Accessible` (`f15`)
is dead weight under default-accept — it only starts doing anything once a final
drop exists. Adding that drop is the change that would make the address lists
mean what they look like they mean.

This is a reading of the ruleset, not a live test. Confirm from a Guest-VLAN
host before acting on it, and if you do add a final `drop` to `forward`, add it
on the router in the correct position and import it — see Wave 4 on ordering.

#### If you do change something here

Have console or serial access, or be physically at the router. The two
tripwires, repeated because they are the ones that lock you out:

- Removing `ether5` from a `tagged` set takes that VLAN down entirely.
- Removing an interface from the `LAN` list removes that segment's access to the
  firewall's `input` chain — including the path this module uses to reach the
  router.

Note also that home-assistant pins a MAC and IP on the IoT VLAN via the
`multus-iot` NetworkAttachmentDefinition (`10.3.0.154`, which firewall rule
`f17` grants access to all local networks), so any renumbering has to account
for that attachment.

**Verify:** `plan` clean; every VLAN still reachable; `just mikrotik run version`
still works.

**Rollback:** backup restore, from the console.

### Wave 6 — never

Leave these to the systems that already own them:

| Not managed | Owner |
| --- | --- |
| DNS **records** | `external-dns` (mikrotik provider). The DNS *server* settings — forwarders, cache size — are fine to manage; the records are not. |
| BGP peers/instances | Touch only alongside a matching `core/kube-system/cilium/app/networks.yaml` change, reviewed together. The AS numbers upstream do not match ours. |
| IPv6 | Not deployed here. Upstream's `ipv6.tf` is built around a French GUA allocation. |
| WireGuard **private keys** | Bitwarden (server) and the client device (peers). The interface and peers themselves are managed — see Wave 6a. |
| Ethernet interfaces | All six are on stock settings; the resource has a large computed surface and importing it buys nothing. |

### Wave 6a — WireGuard *(imported)*

`wireguard.tf` + `wireguard.sops.yaml` + `scripts/wg-peer-add.sh`. The interface
and its 5 peers, under one rule:

> **No private key is modelled in this repo, and none reaches tofu state.**

That rule is not free — it dictates the order of operations below, and it is why
the peer resource omits an attribute rather than setting it.

#### Where each key lives

| Key | Home | In tfstate? |
| --- | --- | --- |
| Server private key | Bitwarden, as `TF_VAR_wireguard_private_key` | yes — unavoidable, see below |
| Peer private keys | the client device only | **no** |
| Peer public keys | `wireguard.sops.yaml` | yes (not secret) |

The server key is *asserted* from Bitwarden rather than read-and-forgotten, so a
clean plan doubles as a check that the Bitwarden copy still matches the device.
It does land in local state, like `routeros_password` already does; state is
treated as a secret-bearing local file that is cheap to lose (§ State).

Peer keys are a different matter, and they are the reason for the sequencing.

#### Why the strip has to happen BEFORE the import

`private_key` on `routeros_interface_wireguard_peer` is flagged non-computed in
the schema, but the provider's read populates it anyway. Verified in a scratch
module: importing a peer that has a stored key writes it into `terraform.tfstate`
in plaintext. `lifecycle { ignore_changes }` does not help — it suppresses diffs,
not state storage.

So an import-then-remove would leave the key in `terraform.tfstate` *and* in
`terraform.tfstate.backup`. Strip on the router first; then import reads nothing
to store.

#### What the stored peer keys were

RouterOS keeps a *client's* private key when a peer is created through the
config-generator, so it can re-render that client's config or QR later. Three of
five peers had one. That means the router — and anyone with the `sensitive`
policy, which includes the `tofu` user — could impersonate those clients.

Clearing them does not touch connectivity: WireGuard authenticates by public
key. What is lost is the router's ability to re-render those clients' configs.
If such a client ever loses its config, generate a new peer with
`just mikrotik wg-add` and delete the old one.

**Done.** Verified afterwards: 0 of 5 peers hold a private key, and state
contains exactly one `private_key` — the server's, from Bitwarden. The Bitwarden
copy was checked by deriving its public key and comparing to the router's, so
neither private key had to be displayed:

```bash
wg pubkey <<<"$TF_VAR_wireguard_private_key"   # == /rest/interface/wireguard .public-key
```

The one-time strip, over SSH:

```
/interface/wireguard/peers set [find name="vizier"] private-key=""
/interface/wireguard/peers set [find name="Leroy-Pixel6"] private-key=""
/interface/wireguard/peers set [find name="Sendri"] private-key=""
```

Verify none remain before importing — this must print `0`:

```bash
just mikrotik shell
curl -sk -u "$TF_VAR_routeros_username:$TF_VAR_routeros_password" \
  "$TF_VAR_routeros_url/rest/interface/wireguard/peers" \
  | jq '[.[] | select((."private-key" // "") != "")] | length'
```

#### Seeding the server key into Bitwarden

```bash
just mikrotik shell
key=$(curl -sk -u "$TF_VAR_routeros_username:$TF_VAR_routeros_password" \
  "$TF_VAR_routeros_url/rest/interface/wireguard" \
  | jq -r '.[] | select(.name=="wireguard1") | ."private-key"')
bws secret create TF_VAR_wireguard_private_key "$key" "$BWS_TOFU_PROJECT_ID"
unset key; exit
```

Same caveat as the router password in § Prerequisites: `bws secret create` takes
the value positionally, so it is briefly visible in `ps` and lands in shell
history. Clear the history line afterwards.

If the secret is missing, `var.wireguard_private_key` is null and the resource's
`precondition` fails with a pointer back here — deliberately, because applying
with a null key would clear the interface's key and drop every tunnel.

#### Adding a peer

```bash
just mikrotik wg-add "James Laptop" --qr
just mikrotik plan      # expect exactly: 1 to add
just mikrotik apply
```

The script generates the keypair locally with `wg genkey`, registers only the
public half in `wireguard.sops.yaml`, and writes the client config to
`~/wireguard-clients/<name>.conf` (mode 600, outside the repo — `gitleaks dir .`
scans the working tree regardless of `.gitignore`). Move it to the client and
`shred -u` it.

Defaults are derived rather than hardcoded:

| Value | Derived from |
| --- | --- |
| tunnel address | highest existing peer `/32`, plus one |
| map key | highest existing `wgNN`, plus one |
| DNS | the first `client_dns` already in use (the AdGuard pair) |
| endpoint | `client_endpoint` in `wireguard.sops.yaml` |
| AllowedIPs | the router's own **`Local Network`** address list, plus the WireGuard subnet — a split tunnel that follows the real segmentation. `--full` for `0.0.0.0/0`. |

The server's public key is read from the router at generation time rather than
cached, so a regenerated server key cannot silently produce dead client configs.

Requires `wireguard-tools` for `wg genkey`; `qrencode` is optional and only
needed for `--qr`. Neither is pinned in `mise.toml` — they are host tools.

#### The endpoint is a bare IP, and that is a weakness

`client_endpoint` is `99.172.175.67:13231` — the WAN address, which is
DHCP-assigned from the BGW320-500 and can change, at which point every client
config breaks at once. Not addressed here — it is a change, and this wave is an
import. Wave 10 fixes the DNS half by publishing a stable name; swapping
`client_endpoint` over waits for the next client reissue.

#### Peers worth a look

`Samsung S9` has never completed a handshake, and `vizier` last did so over two
weeks ago. Neither is acted on here; removing a peer is a one-line deletion from
`wireguard.sops.yaml` followed by `plan`/`apply`.

---

### Wave 7 — remote state in Garage *(done)*

State moves out of `terraform.tfstate` on one workstation and into the
`tofu-state` bucket on the NAS Garage. `backend.tf` holds both halves: the S3
backend and an `encryption` block. They arrived together on purpose — see
"Why encryption is not optional here" below.

The bucket and its key are declared in
`apps/default/garage/nas/tofu-state.yaml` (PR #1528) and minted by the
garage-operator. Nothing about them is created by tofu, which keeps the
bootstrap acyclic: tofu never needs state in order to create its own state
store.

#### The endpoint is the Synology, not the cluster

`https://s3.core.wynning.tech`, which is a CNAME to `nas.core.wynning.tech`
(192.168.1.3) — the Garage that actually stores the data, served over TLS with
a Let's Encrypt cert. The obvious-looking choice — the in-cluster `garage-nas`
GarageCluster — does not work from a workstation:

```
kubectl -n default get svc garage-nas-rpc
# LoadBalancer  192.168.1.225  3901:31310/TCP     <- RPC only, no 3900
kubectl get httproute -A | grep s3
# default  garage-cluster-s3  ["s3.int.wynning.tech"]  -> garage-cluster, not garage-nas
```

`garage-nas` is a **gateway** (`gateway: true`, `replicas: 1`) that proxies to
`192.168.1.3:3901`. Its only exposed port outside the cluster is RPC, and the
one S3 HTTPRoute in the repo points at the unrelated `garage-cluster`. So there
is no external S3 endpoint for this Garage — only the origin itself.

The Secret the operator writes carries `endpoint =
http://garage-nas.default.svc.cluster.local:3900`, which is correct for
in-cluster consumers (cnpg, loki, tempo) and useless here. Read
`access-key-id` and `secret-access-key` from it; ignore `endpoint`.

`192.168.1.3:3900` reaches the same Garage over plain HTTP and is the fallback
if DNS is the thing that is broken. Prefer the name: the cert is real, and a
router misconfiguration that breaks internal DNS is a plausible outcome of a
bad `apply` here — but so is one that breaks routing, and neither endpoint
survives that.

#### Why encryption is still not optional

TLS protects the hop, not the object. This state holds the RouterOS password
and the WireGuard server private key, and without the `encryption` block both
would sit readable in a bucket. That bucket is on a Garage several other
workloads hold credentials for, and its contents are one leaked bucket key away
from being someone else's. Encrypting the payload means Garage only ever stores
ciphertext, so a compromised key yields nothing.

Verified before the config was committed, against a throwaway key in the same
bucket:

```
mc cat tofustate/tofu-state/_scratch/probe.tfstate | grep -c terraform_data
0
```

The stored object is `{"serial":...,"meta":{"key_provider.pbkdf2.this":...},
"encrypted_data":"..."}` and nothing else.

`backend.tf` declares the `method` and the `state`/`plan` targets but **not**
the `key_provider`. That block arrives as `TF_ENCRYPTION` from `bws run`, so no
passphrase is written to the repo. If it is missing, tofu stops:

```
There is no key_provider "pbkdf2" "this" block declared in the encryption block.
```

That failure mode is the point. There is no path where a missing passphrase
silently writes plaintext state — the same fail-loud property as
`var.wireguard_private_key`'s precondition.

#### Locking

`use_lockfile = true` — the native S3 lock object, no DynamoDB. Releasing the
lock is a `DeleteObject`, which is why the GarageKey grants `write` and not
just `read`. Everything else in the backend block is a `skip_*` for an AWS-ism
Garage does not implement: no STS, no IMDS, no account IDs, and `garage` is not
a real AWS region.

#### Manual steps

Three secrets go into the same Bitwarden project as the rest. `bws run` injects
every secret in the project under its own key name, so all three are consumed
with no mapping step — the same reason the router credentials are named
`TF_VAR_*`.

**1. The bucket credentials.** Read them out of the operator-minted Secret and
paste each into Bitwarden verbatim:

```
kubectl -n default get secret tofu-state -o jsonpath='{.data.access-key-id}'     | base64 -d; echo
kubectl -n default get secret tofu-state -o jsonpath='{.data.secret-access-key}' | base64 -d; echo
```

- `AWS_ACCESS_KEY_ID` — the first value
- `AWS_SECRET_ACCESS_KEY` — the second

**2. The state passphrase.** Generate one and store the whole HCL fragment, not
just the passphrase, as a single secret named `TF_ENCRYPTION`:

```
printf 'key_provider "pbkdf2" "this" { passphrase = "%s" }\n' "$(openssl rand -base64 48)"
```

Put that entire line in Bitwarden. **Back it up somewhere you would still have
if Bitwarden were unavailable** — losing it means the remote state is
unrecoverable ciphertext. Losing it is survivable (everything here is
importable from the router) but it means redoing every import in this document.

**3. Migrate.** This is two phases, because the `encryption` block gates
reading *local* state as well as remote. On a first attempt it refuses to read
the very plaintext file it is meant to move:

```
Error reading local state: encountered unencrypted payload without unencrypted
method configured
```

The way through is a temporary `fallback`, which means "try aes_gcm, then
accept plaintext". Add it to the `state` block in `backend.tf`:

```hcl
    method "unencrypted" "migrate" {}

    state {
      method = method.aes_gcm.this

      fallback {
        method = method.unencrypted.migrate
      }
    }
```

Then:

```
just mikrotik init -migrate-state        # answer yes
just mikrotik run state list | wc -l     # expect 186
```

**Now take the fallback back out** — both the `method "unencrypted"` line and
the `fallback` block — and confirm reads still work:

```
just mikrotik plan                       # expect: No changes
```

Leaving it in would silently accept an unencrypted state file forever, which is
the exact failure the encryption block exists to prevent. It governs reads
only; the object written during migration is encrypted either way, which is
worth knowing if you are ever unsure whether a migration completed before you
removed it — check the object, not the config:

```
mc cat <alias>/tofu-state/mikrotik/terraform.tfstate | grep -c routeros
# 0
```

Finally, delete the local copies:

```
rm -f tofu/mikrotik/terraform.tfstate tofu/mikrotik/terraform.tfstate.backup
```

`-migrate-state` truncates `terraform.tfstate` to zero bytes but leaves
`terraform.tfstate.backup` behind with real content, so the second path is not
redundant. Both are stale from the moment the migration lands, and the backup
is written encrypted, so no plaintext survives on disk either way.

#### What this retired

`.gitleaks.toml` carried an allowlist entry for `^tofu/.*/terraform\.tfstate`,
added in Wave 6a because the plaintext state legitimately held the router
password and the WireGuard server private key, and `gitleaks dir .` scans the
working tree regardless of `.gitignore`. With state remote and encrypted there
is nothing left to exempt, so the entry is gone — verified by running
`gitleaks dir .` over the whole tree with no exemption and no findings.

That entry was load-bearing in an annoying way: it lived only on this branch,
so any commit from a branch cut off `main` hit the pre-commit hook and blocked.
Removing it removes that whole class of interruption.

#### Result

```
just mikrotik run state list | wc -l   # 186
just mikrotik plan                     # No changes
```

The object in the bucket is 206KiB of ciphertext; `routeros`, `wireguard`,
`password` and `private_key` all return zero matches against it.

Deleting the local files is part of the step, not cleanup. They are plaintext,
they contain the WireGuard server key, and they are what forces the
`terraform.tfstate` entry in `.gitleaks.toml` — once state is remote and
encrypted, neither the files nor that allowlist entry should exist.

#### The objection this reverses

An earlier draft of "## State" below argued against exactly this: *"a
garage/minio backend would mean the router's config depends on the network the
router is routing for — and the one time you most need `tofu plan` is when the
network is broken."*

That objection is real and is not fully answered. What has changed is its
weight:

- The store is the Synology, not k3s. A cluster outage — much more frequent
  here than a LAN outage — no longer touches state.
- A genuine LAN partition still locks you out, but in that scenario the router
  is equally unreachable, so there is nothing to plan against anyway.
- The escape hatch is one command: `tofu init -migrate-state` in the other
  direction pulls state back to local disk.

What tips it is that "back it up with the rest of your home directory" was
never actually true — the file was on one machine, and the alternative to a
shared backend was not a safer local file but no second copy at all.

### Wave 8 — hand-made DNS records *(imported)*

34 records from `/ip/dns/static`, encrypted in `dns.sops.yaml`. This is a
name-to-address map of every VLAN including IoT and Management, so it gets the
same treatment as the leases.

The wave is small. Establishing which 34 was not.

#### Three writers share this table

`/ip/dns/static` holds 282 records. Tofu owns 34 of them. The rest belong to
two other controllers, and the entire risk of this wave is importing one of
theirs by mistake — the result would not be an error, it would be two writers
silently reverting each other on their own schedules.

| Owner | Count | How to tell |
| --- | --- | --- |
| external-dns | 211 | see below — three signals |
| DHCP lease scripts | 37 | comment starts `dhcp-lease-script_` |
| hand-made (this wave) | 34 | everything else; all TTL `1d` |

#### external-dns

Configured in `core/networking/external-dns/app/helmrelease-mikrotik.yaml`
with `policy: sync`, `registry: txt`, `txtPrefix: k8s.mikrotik-dns.`. Any one
of these disqualifies a record:

1. **Name starts with `k8s.mikrotik-dns.`** — the TXT registry records. 103.
2. **Comment is exactly `External-DNS`** — stamped by the webhook. 105.
3. **Name is claimed by a registry TXT** — strip the prefix and the `a-` type
   marker off a registry name and you get the FQDN it owns. 55 more.

Signal 3 is the one that matters. Those 55 records carry no prefix and no
stamp; by inspection they look exactly like hand-made entries. Classifying on
comment alone would have imported all of them.

#### The DHCP lease scripts, and how they were caught

Five of the six DHCP servers carry a ~2.9KB `lease-script` that adds a DNS
record when a lease is granted and removes it when the lease goes, under a
per-VLAN domain (`mgmt.`, `core.`, `dyn.`, `iot.`, `guest.`).

They were not found by reading the config. They were found because **nine
imports failed.** These records churn — a device renewing its lease gets a new
`.id` — so ids captured seconds earlier were already stale.

That failure was the useful part. An import that happened to win the race would
have succeeded, looked correct, and then fought the lease script indefinitely.

The comment has two suffix forms and the first pass only caught one:

```
dhcp-lease-script_IoT_comment              32   <- caught by the first regex
dhcp-lease-script_Servers_lease-hostname    2   <- missed
dhcp-lease-script_Workstations_lease-hostname 2 <- missed
dhcp-lease-script_IoT_lease-hostname        1   <- missed
```

Anchoring on `^dhcp-lease-script_` catches all 37. The five missed ones had
been imported and were removed from state with `tofu state rm` before the
rebuild.

TTL is a useful cross-check: every lease-script record is `15m`, and all 34
hand-made ones are `1d`. If a future import brings in something at 15m, look
at it again.

#### What is in the 34

26 A records and 8 CNAMEs. The CNAMEs all point at `nas.core.wynning.tech` and
include `s3.core.wynning.tech` — the endpoint Wave 7's state backend uses, so
this table is now load-bearing for tofu's own state.

Ten carry descriptive comments (`Tailscale - …`, `NAS`, `Manual entry for k8s
kube-vip LB`, hardware names); 24 have none.

#### Three that deserve a second look

Not acted on here — this wave imports what exists.

- **`ghcr.io → 140.82.113.34`.** A static A record pinning GitHub's container
  registry to one IP, cluster-wide. If GitHub rotates it, image pulls fail in a
  way that will not obviously point back here. Spegel is the embedded registry
  mirror (see `EmbeddedRegistry.md`) and may make this unnecessary.
- **`k8s.wynn → 192.168.1.10`.** Not a valid FQDN under any domain in use.
  Almost certainly a truncated `k8s.wynning.tech`.
- **`router.lan → 192.168.88.1`**, comment `defconf`. RouterOS's factory
  default, pointing at a subnet this router does not use. Two more `192.168.88.x`
  records are in the same category.

#### Import

Ids come from the REST API rather than being typed:

```
curl -sk -u "$USER:$PASS" https://192.168.1.1/rest/ip/dns/static
```

Filter to the 34, then `tofu import 'routeros_ip_dns_record.this["dnsNN"]' '*ID'`
for each. Re-deriving the filter is worth it over reusing a saved list — the
lease-script records move.

### Wave 9 — one lease script instead of five *(done)*

The DHCP lease scripts were already managed — they came in with Wave 3b as
`lease_script` on each server and sat in `dhcp.sops.yaml` as five encrypted
2.9KB blobs. That worked, and it was a bad way to hold them:

- **A script change is invisible in review.** The value is inside SOPS, so a
  diff shows only that ciphertext changed. There is no way to see what the new
  script does without decrypting both sides by hand.
- **They were five copies of one script, and they had drifted.**

This wave replaces the blobs with one plaintext template,
`scripts/dhcp-lease-dns.rsc.tftpl`, rendered per server by `templatefile()` in
`dhcp.tf`. Only the inputs stay encrypted.

#### What the drift was

Management, Servers and Guests were byte-identical apart from `dnsDomain`. The
other two were not:

**Workstations had a fix the other four lacked** — a guard against inserting a
DNS record with an empty name:

```
if ([:len [$h]] > 0) {
   /ip dns static add comment="$leaseComment" address="$leaseActIP" name="$h" ttl="$dnsTtl"
 } else= {
   :log error "$leaseActMAC - not creating DNS entry as derived hostname is empty"
 }
```

Everywhere else that is a bare `add ... name="$h"`. A lease whose derived
hostname comes out empty produces a nameless record or an error on four of the
five VLANs. Somebody hit this on Workstations and patched it in place.

**IoT was running with the script's debug logging enabled** — six `:log info`
lines that are commented out on the other four, firing on every lease event.

IoT also sets `leaseClientHostnameSource "comment"` where the rest use
`"lease-hostname"`. That one is deliberate (IoT devices rarely send a useful
hostname) and is preserved as a per-server input. It is also the origin of the
two comment suffixes that broke the first Wave 8 import filter.

#### Why the template is Workstations' copy

Because it is the only one with the guard, and because it gives a way to prove
the extraction is faithful: **rendering the template with Workstations' own
inputs reproduces that server's script byte for byte.** The plan agrees —
`4 to change`, not 5.

```
routeros_ip_dhcp_server.this["srv01"]  update  attrs=['lease_script']
routeros_ip_dhcp_server.this["srv02"]  update  attrs=['lease_script']
routeros_ip_dhcp_server.this["srv03"]  update  attrs=['lease_script']
routeros_ip_dhcp_server.this["srv04"]  update  attrs=['lease_script']
```

srv05 (Workstations) does not appear, and no attribute other than
`lease_script` changes on any server.

#### What applying did

Added the empty-hostname guard to Guests, IoT, Management and Servers, and
commented IoT's debug logging back out. Nothing else. Existing DNS records were
untouched — the script only runs on the next lease event.

Verified on the router rather than in state, by asking each server's
`lease-script` whether it carries the guard and whether the `:log info` lines
are live:

```
defconf        no-script       debug-off      0
Management     GUARD-present   debug-off   3038
Servers        GUARD-present   debug-off   3038
Workstations   GUARD-present   debug-off   3037
IoT            GUARD-present   debug-off   3030
Guests         GUARD-present   debug-off   3039
```

All five carry the guard where only Workstations did before, IoT's debug logging
is off, and `defconf` still has no script. The remaining length differences are
the per-server `dnsDomain` and IoT's `hostname_source`, which is what the
template intends. `plan` proposes no `lease_script` change on any server, which
is the other half of the proof: config and device agree.

**Read this section's status from the device, not from the plan being clean.**
A clean plan looks identical whether the wave was applied or was never written,
because in both cases config and router match. The distinguishing evidence is
the guard being present on all five.

The template's indentation is ragged in places (`   if` at three spaces, `    }`
at four). That is how it came off the router. Tidying it would break the
byte-identical check that makes this wave verifiable, so it is left alone.

#### Inputs

| Input | Where | Note |
| --- | --- | --- |
| `dns_domain` | `dhcp.sops.yaml` | the only secret one |
| `hostname_source` | `dhcp.sops.yaml` | defaults `lease-hostname`; IoT sets `comment` |
| `dns_ttl` | default `00:15:00` | every lease-script record carries this TTL |
| `dns_debug` | default `false` | renders `${log}` as `#` or empty |
| `dns_remove_all_by_ip` / `_by_name` / `dns_always_nonfqdn` | defaults | identical everywhere; exposed so a future divergence is a data change, not a fork |

A server with no `dns_domain` gets no script. That is how `defconf` keeps its
`lease-script` empty without a special case.

#### The boundary this does not cross

Wave 8 keeps tofu out of the DNS records these scripts create. This wave
manages the scripts. Both are true at once and neither weakens the other: tofu
owns the code, the code owns the records.

Editing the template changes behaviour on five DHCP servers at once, which is
the point and also the risk. `just mikrotik plan` renders the full script diff
inline — read it before applying.

### Wave 10 — cloud DDNS for the WireGuard endpoint *(done)*

`routeros_ip_cloud` in `system.tf`. Closes the weakness recorded in Wave 6a and
issue #1523: `client_endpoint` was the bare WAN address, DHCP-assigned from the
upstream BGW320-500, so a lease change would break all five client configs at
once with no remote way to fix them.

Imported as found first (`ddns_enabled = "auto"`), clean plan at 221 resources,
then flipped to `"yes"` as a one-line change — the same import-then-change shape
as Wave 1's NTP client.

```
~ ddns_enabled = "auto" -> "yes"
Plan: 0 to add, 1 to change, 0 to destroy.
```

Result on the router, and `dig hdh08p0jf1f.sn.mynetname.net` returns the same
address:

```json
{"ddns-enabled":"yes","dns-name":"hdh08p0jf1f.sn.mynetname.net",
 "public-address":"99.172.175.67","status":"updated",
 "warning":"Router is behind a NAT. Remote connection might not work."}
```

**`auto` was doing nothing.** It had assigned no `dns-name` and left
`ddns-update-interval` at `none`. Reading `ddns-enabled` alone suggests DDNS is
half-configured; the *absent* `dns-name` is the field that says whether anything
is actually published. Check that, not the flag.

**The NAT warning is expected, not a failure.** ether1 holds `192.168.100.66/24`
from the BGW, so the router is behind NAT and RouterOS says so. The published
record still points at the correct public address, and inbound UDP/13231
demonstrably works — peers hold current handshakes. The warning is about
MikroTik's own remote-access features, not about the DDNS record.

#### Why the name is not fronted by a `wynning.tech` CNAME

Deliberate. Every public hostname resolves to heimdall (`jameswynn.com` and
`echo.wynning.tech` → `15.204.118.232`); the residential WAN address appears
nowhere in the zone, which is what the towonel edge exists to achieve. A
`wg.wynning.tech` record could not be Cloudflare-proxied — WireGuard is UDP — so
it would necessarily be a grey-cloud A record publishing the home IP under the
domain, and `wg` is among the first subdomains an enumerator guesses.

Using MikroTik's name directly keeps the linkage one-way: IP → name. Someone
enumerating `wynning.tech` finds nothing. Someone who already has the IP can
find the mynetname record by reverse or passive DNS, but they already have the
thing worth protecting.

The costs, both accepted: the serial number is now in public DNS, and changing
DDNS mechanism later means reissuing client configs rather than repointing a
CNAME.

#### Still to do

`client_endpoint` in `wireguard.sops.yaml` is still the bare IP. Changing it
affects only newly generated configs — `wg-peer-add.sh` reads it, no router
resource does — so the five installed clients keep working off the IP until they
are reissued. Do that alongside #1520 (key rotation) and #1526 (prune dead
peers), which require touching every client anyway.

The other moving address is upstream and outside tofu: the BGW forwards
UDP/13231 to `192.168.100.66`, itself a DHCP lease. Reserve it statically on the
BGW — DDNS cannot cover that failure.

### Wave 11 — system logging *(done)*

`logging.tf` plus two maps in `locals.tf`: `routeros_system_logging_action` ×4
and `routeros_system_logging` ×6. No data path — these decide where log lines
go; nothing routes, filters or resolves through them. That is why this is the
first of the remaining waves.

All ten imported clean on the first plan, 231 resources total.

```bash
just mikrotik import 'routeros_system_logging_action.this["memory"]' '*0'   # disk *1, echo *2, remote *3
just mikrotik import 'routeros_system_logging.this["info-memory"]'   '*1'   # ... through *6
```

Actions import before rules: a rule references its action by name.

**The four `default: true` entries were imported too**, unlike the built-in
`read`/`write`/`full` user groups in Wave 2 which were deliberately left out.
The difference is that those groups cannot be changed here and declaring them
would only create drift to chase, whereas a logging action holds real settings —
`memory_lines`, the disk file name — that someone could change. Importing them
is what makes such a change show up in a plan.

**No SOPS file.** The only local value is the syslog target, and it is already
in the clear as `SVC_SYSLOG_ADDR` in
`components/cluster-vars/cluster-configs.yaml`. Encrypting it here would protect
nothing and would make the wave unreviewable.

Logging rules carry no ordering semantics — every matching rule fires — so
unlike the firewall in Wave 4 a `for_each` map is safe and creation order does
not matter.

#### The finding: router syslog has never arrived

The `remote` action sends **UDP** to `SVC_SYSLOG_ADDR:1514`. That listener is
**TCP-only**, and has always been:

| | |
| --- | --- |
| `core/monitoring/alloy/app/syslog-service.yaml` | `protocol: TCP` |
| `core/monitoring/alloy/app/helm-release.yaml` | `extraPorts` `protocol: TCP`, and `loki.source.syslog` `protocol = "tcp"` |
| `core/monitoring/promtail/app/helm-release.yaml` | `protocol: TCP` — the predecessor, same |

So this is not an Alloy-migration regression; the router's log lines have been
dropped on the floor since the remote action was configured. A logging rule
feeding it (`remote-syslog`, topics `info,critical,warning,error`) has been
firing the whole time.

It is not a one-word fix. The router sends BSD-format (RFC3164,
`syslog-time-format: bsd-syslog`, `remote-log-format: default`) and Alloy's
syslog component expects RFC5424, so the format has to be settled alongside the
protocol. Mirrored as found here and tracked separately — this wave is an
import.

---

## Remaining waves

Ordered by blast radius, the same rule as waves 1–6. Each ends when `plan` is
clean against the untouched router.

### Wave 12 — inert system services

`ip/settings` (`rp-filter: no`, `tcp-syncookies: false`), `ip/smb`
(`enabled: auto`, `interfaces: all`) and `ip/service` (8 entries). Singletons
and one small map; importing changes nothing on the device.

Worth doing next because it unblocks issue #1524 — disabling `btest` and the
plaintext `api` is a change, and a change wants the resource imported first.
`ip/smb` on a router is its own question once it is visible.

### Wave 13 — the physical and WAN layer

`interface/ethernet` (6 ports) and `ip/dhcp-client` (the ether1 uplink).

Both are inert to import and unforgiving to get wrong: an ethernet attribute
mismatch can bounce a port, and a recreated `dhcp-client` drops the WAN. Do them
in one wave because they are the same layer, and do them with console access.
Note that the BGW's port-forward for WireGuard targets `192.168.100.66`, the
address this DHCP client holds.

### Wave 14 — IPv6

`disable-ipv6: false` and `forward: true`, no GUA, 22 `defconf` filter rules.
Inert today because the ISP hands out no prefix — which is exactly why it is
worth importing before that changes. The 22 rules have the same ordering
constraint as Wave 4: never let tofu create one.

### Wave 15 — BGP

Five `PEER_TO_K3S_*` connections plus the dead `default` entry. **Highest blast
radius in the module**: these advertise every cilium LoadBalancer VIP, so
breaking them takes down all gateway ingress. This is the failure the original
upstream copy would have caused, in the same subsystem.

Do it last, alongside a reading of `core/kube-system/cilium/app/networks.yaml`
rather than from the router alone, and treat the `default` entry as a separate
decision — it is leftover scaffolding, not config.

### Never

`ip/dns/static` (three writers — see Wave 8), and `ip/firewall/service-port`,
which has no provider resource at all. `queue/interface`, `system/health` and
`system/resource/irq` are derived from hardware, not configuration.

---

## How the encryption is wired

Three pieces, all committed:

**1. `.sops.yaml`** — a rule for `tofu/.*\.sops\.ya?ml$` placed *above* the
catch-all. This matters more than it looks. The catch-all is
`path_regex: .*\.ya?ml` with `encrypted_regex: ^(data|stringData)$`, scoped to
Kubernetes Secrets — under it, a file with top-level keys like `BWS_ACCESS_TOKEN`
gets sops metadata appended and the **values left in plaintext**. `sops --encrypt`
exits 0 and the file looks encrypted, so it fails silently. The new rule carries
no `encrypted_regex`, so every value is encrypted.

After encrypting anything here, check it:

```bash
head -4 tofu/mikrotik/env.sops.yaml     # expect ENC[AES256_GCM,...]
```

Note an empty string encrypts to an empty string — there is nothing to encrypt —
so a `""` placeholder proves nothing either way. That is why the template ships
as `REPLACE_ME` rather than blank.

**2. `mise.toml` `[env]`** — points mise at the key, then at the file:

```toml
SOPS_AGE_KEY_FILE = "{{env.HOME}}/.config/sops/age/keys.txt"
_.file = { path = "{{config_root}}/tofu/mikrotik/env.sops.yaml", redact = true }
```

`SOPS_AGE_KEY_FILE` must come first — mise evaluates `[env]` in order — and it
is required: unlike the `sops` binary, mise does not fall back to the default
age keyring and fails with `no data key retrieved from metadata`.

**3. `mise.toml` `[settings] sops.strict = false`** — load-bearing. With the
default `true`, a machine missing the age key cannot run mise *at all*: the
decrypt hard-fails and takes every `mise exec` and `mise install` with it
(verified — exit 1, zero vars exported). Non-strict degrades to "those two vars
are unset", mise keeps working, and preflight reports it properly.

Only YAML works. mise parses a `_.file` dotenv as plain text and chokes on the
age armor, so the repo's `*.sops.env` rule is not usable here.


## State

The `tofu-state` bucket on the NAS Garage, AES-GCM encrypted before it leaves
this machine. Wave 7 has the wiring and the reasoning; this is the summary.

Not in git: SOPS-encrypting state is possible but makes every plan a
decrypt/re-encrypt cycle, which is exactly the failure mode that made the
previous attempt leak plaintext on disk. The `encryption` block gets the same
protection without a file ever hitting the working tree.

State is still cheap to lose. Everything is importable from the router, which
remains the source of truth — if both the bucket and the `TF_ENCRYPTION`
passphrase were gone, the recovery is re-running the imports from the wave
notes, not a disaster. That is what keeps the passphrase from being a
single point of catastrophic failure.

What is *not* cheap to lose is the router itself. Keep the `/export` backup
from Prerequisites §4 current; state is a record of what tofu owns, not a
backup of the device.

## Coverage audit (2026-08-23)

Swept the live router over REST — 144 config paths, each classified as real
config or RouterOS-generated — and diffed against what tofu manages. The live
router beats the `/export` backup for this: the backup is a point-in-time
snapshot from before Wave 0, and several of these sections have changed since.

**Provider surface:** 254 resource types. **Managed:** 231 resources across 25
types. What follows is everything that exists on the router and is not managed.

### Act on these

| Section | On the router | Provider resource |
| --- | --- | --- |
| `ip/service` | 8 services, `address` empty on every one | `routeros_ip_service` |
| `routing/bgp/connection` | 5 live k3s sessions + 1 dead entry | `routeros_routing_bgp_connection` |
| `ip/dhcp-client` | the WAN uplink | `routeros_ip_dhcp_client` |
| `ip/settings` | `rp-filter: no`, `tcp-syncookies: false` | `routeros_ip_settings` |
| `ipv6/*` | forwarding **on**, no GUA, 22 defconf rules | full coverage |
| `interface/ethernet` | 6 ports | `routeros_interface_ethernet` |
| `ip/smb` | `enabled: auto`, `interfaces: all` | `routeros_ip_smb` |

**`ip/cloud` is now managed — see Wave 10.** It was the answer to the WireGuard
endpoint problem (issue #1523): MikroTik's free DDNS was available and switched
off. The observation behind it still stands — `/ip/dhcp-client` on ether1 holds
`192.168.100.66/24`, a private address, so there is upstream NAT and inbound
WireGuard depends on a port-forward on the BGW. That forward demonstrably works
today, but it targets a DHCP lease.

**The dead BGP connection.** Five `PEER_TO_K3S_*` connections have established
sessions (3–6 days uptime). A sixth, named `default`, has `remote.address:
::/0`, `local.default-address: ::1`, a different instance, and no session. It
is leftover scaffolding: an iBGP wildcard listener for AS 64514 that nothing
uses.

**IPv6 is enabled and forwarding** (`disable-ipv6: false`, `forward: true`)
with only link-local addresses and RouterOS's 22 `defconf` filter rules. Inert
today. If the ISP ever hands out IPv6, forwarding is already on and that
default ruleset is the only thing in the way.

### Cannot be managed

- **`ip/firewall/service-port`** — the connection-tracking helpers (`sip`,
  `h323`, `pptp`, `ftp`, `tftp` enabled; `irc`, `rtsp` disabled) have **no
  provider resource**. `routeros_ip_hotspot_service_port` is unrelated. Turning
  an ALG off is a manual change.

### Must not be managed

- **`ip/dns/static`** — 282 records with three writers. Only the 34 hand-made
  ones are in scope; see Wave 8.
- **`queue/interface`, `system/health`, `system/resource/irq`** — derived from
  hardware, not configuration.

### Confirmed empty

Nothing hiding in OSPF, routing filters, IPsec peers/identities/policies,
hotspot, PPPoE/L2TP/PPTP/SSTP/OVPN clients, bonding, VRRP, GRE/EoIP/IPIP, veth,
wireless, simple and tree queues, netwatch, scheduler, scripts, RADIUS,
containers, bridge filter/NAT/MDB, IPv6 pools/DHCP, `ppp/secret`, `disk`,
`port/remote-access`, `special-login`.

`interface/ovpn-server/server` exists but is `disabled: true`. UPnP, proxy,
SOCKS, SNMP and traffic-flow are explicitly disabled. `user/aaa` has RADIUS
off.

### Reproducing this

The sweep is a loop over REST paths counting entries and discounting anything
flagged `dynamic`, `default`, `builtin` or `invalid`:

```bash
curl -sk -u "$USER:$PASS" "https://192.168.1.1/rest/<path>"
```

Provider surface comes from `just mikrotik run providers schema -json`, whose
`resource_schemas` keys are the full list of `routeros_*` types.

## Reading the upstream config

Upstream is worth diffing against while writing each wave, but it describes a
different network on different hardware. Browse it at the pinned commit rather
than vendoring a copy:

<https://github.com/eleboucher/homelab/tree/29610155ed6bc9a2b904dc2dc519807f67ebb694/tofu/mikrotik>

Refresh the pin when you next consult it:

```bash
git ls-remote https://github.com/eleboucher/homelab.git HEAD
```

Nothing should be copied across without checking it against the `.rsc` export
first. What is upstream-specific:

| Thing | Upstream | Ours |
| --- | --- | --- |
| Router | RB5009-class: `ether1`–`ether8`, `sfp-sfpplus1/2`, 9000 MTU, LACP bond | **hEX S** — 5×GbE + 1×SFP, no SFP+, no LACP (`hardware.md`) |
| Router address | `192.168.1.2` | `192.168.1.1` (`core/kube-system/cilium/app/networks.yaml`) |
| Upstream WAN | Freebox (FR) | AT&T BGW320-500 |
| BGP | router AS 64513 ↔ nodes AS 64514, eBGP | cilium `localASN: 64514` → `peerASN: 64514` at `192.168.1.1` |
| IPv6 | `2a01:e0a:e4b:aa31::/64` GUA, RA/ND, v6 firewall | not deployed |
| Nodes | kharkiv / paris / normandie, Talos | helheim / muspelheim / nidavellir / niflheim / svartalfheim, k3s |
| Domain | `erwanleboucher.dev` | `wynning.tech` |
| Timezone | `Europe/Paris` | see `CLUSTER_TZ` |
| WireGuard | `wg-mb` → "mortebrume" hub, BGP AS 4200005000 | tailscale + towonel/OVH edge |
| Secrets | 1Password (`op run --env-file=op.env`) | Bitwarden Secrets Manager (`bws run`) |
| State | OVH S3 backend | local, gitignored (§ State above) |

The `mikrotik-terraform` branch's original `tf/router/` was an unadapted copy of
that tree; it was removed rather than kept in-repo.
