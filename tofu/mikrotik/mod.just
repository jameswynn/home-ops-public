set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

# Non-secret provider inputs. Override in your shell if the router moves.
export TF_VAR_routeros_url := env('TF_VAR_routeros_url', 'https://192.168.1.1')
export TF_VAR_routeros_insecure := env('TF_VAR_routeros_insecure', 'true')

# `bws run` injects every secret in the project as an env var named after that
# secret's key, so the Bitwarden secrets are named TF_VAR_* directly and land in
# the provider with no mapping step. Nothing is decrypted to disk — which is the
# whole reason this module has no tfvars file.
# Everything runs under `mise exec` rather than trusting the caller's PATH. An
# already-open shell that activated mise before a tool was added to mise.toml
# carries a stale __MISE_DIFF and silently never picks the tool up — and a
# leftover manual install elsewhere on PATH would shadow the pinned version.
# `mise exec` also supplies BWS_ACCESS_TOKEN from the sops-encrypted env file,
# so these recipes work in a stale shell.
# No --project-id: it would be expanded by the recipe's own shell, which is
# outside `mise exec` and so does not have it — silently passing an empty value.
# The service account token is already scoped to one project, which is the real
# access control; `bws run` without the flag injects exactly that project.
bws := 'mise exec -- bws run --'

# DHCP reservations, decrypted straight into the environment — never to disk,
# and never onto a command line, where `bws run`'s sh -c pass would mangle the
# JSON. Falls back to an empty map so `just --list` still works without the age
# key; preflight reports the real problem.
export TF_VAR_static_leases := shell('mise exec -- sops -d --output-type json ' + source_directory() + '/leases.sops.yaml 2>/dev/null || echo {}')

# DHCP pools/servers/networks, same treatment: subnets and internal domains.
export TF_VAR_dhcp := shell('mise exec -- sops -d --output-type json ' + source_directory() + '/dhcp.sops.yaml 2>/dev/null || echo {"pools":{},"servers":{},"networks":{}}')

# Firewall filters/NAT/address lists, same treatment: the ruleset maps the
# segmentation and the address lists name devices.
export TF_VAR_firewall := shell('mise exec -- sops -d --output-type json ' + source_directory() + '/firewall.sops.yaml 2>/dev/null || echo {"filters":{},"nat":{},"addr_lists":{}}')

# Interfaces, VLANs and addressing — the most complete map of the network here.
export TF_VAR_network := shell('mise exec -- sops -d --output-type json ' + source_directory() + '/network.sops.yaml 2>/dev/null || echo {"bridges":{},"bridge_ports":{},"bridge_vlans":{},"vlans":{},"addresses":{},"interface_lists":{},"interface_list_members":{}}')

# Hand-made /ip/dns/static records. NOT the external-dns ones -- see dns.tf for
# the ownership test. Encrypted because this is a name-to-address map of every
# VLAN, IoT and Management included.
export TF_VAR_dns_records := shell('mise exec -- sops -d --output-type json ' + source_directory() + '/dns.sops.yaml 2>/dev/null || echo {}')

# WireGuard interface + peers. NO key material: the server key comes from
# Bitwarden as TF_VAR_wireguard_private_key, and peer private keys stay with the
# clients. What this protects is the peer inventory. The fallback is a complete
# but empty shape -- var.wireguard's validation turns it into a readable error
# rather than a plan that deletes every peer.
export TF_VAR_wireguard := shell('mise exec -- sops -d --output-type json ' + source_directory() + '/wireguard.sops.yaml 2>/dev/null || echo {"client_endpoint":"","interface":{"name":"","listen_port":0},"peers":{}}')

tofu := 'mise exec -- tofu'

[private]
default:
    just --list mikrotik

[private]
preflight:
    command -v mise >/dev/null || { echo "mise is not on PATH; see the repo README" >&2; exit 1; }
    mise which tofu >/dev/null 2>&1 || { echo "tofu not installed — run 'mise install'" >&2; exit 1; }
    mise which bws >/dev/null 2>&1 || { echo "bws not installed — run 'mise install'" >&2; exit 1; }
    mise exec -- bash -c ': "${BWS_ACCESS_TOKEN:?not set — check tofu/mikrotik/env.sops.yaml and mise.toml}"'
    mise exec -- bash -c '[ "$BWS_ACCESS_TOKEN" != REPLACE_ME ] || { echo "env.sops.yaml still holds the placeholder — run: sops tofu/mikrotik/env.sops.yaml" >&2; exit 1; }'
    # State lives in the tofu-state Garage bucket and is encrypted before it
    # leaves this machine. All three come straight from Bitwarden, unmapped.
    # Checked here so a missing one is a sentence rather than a tofu stack
    # trace about an undeclared key_provider or an anonymous S3 request.
    {{ bws }} bash -c ': "${AWS_ACCESS_KEY_ID:?not in the Bitwarden project — see BOOTSTRAP.md Wave 7}"'
    {{ bws }} bash -c ': "${AWS_SECRET_ACCESS_KEY:?not in the Bitwarden project — see BOOTSTRAP.md Wave 7}"'
    {{ bws }} bash -c ': "${TF_ENCRYPTION:?not in the Bitwarden project — without it tofu cannot decrypt remote state; see BOOTSTRAP.md Wave 7}"'

[doc('Initialize the working directory and download providers')]
init *args: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu init {{ args }}

[doc('Format all .tf files in this module')]
fmt *args:
    cd "{{ source_directory() }}" && {{ tofu }} fmt {{ args }}

[doc('Validate the configuration')]
validate: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu validate

[doc('Show planned changes; writes plan.tfplan')]
plan *args: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu plan -out=plan.tfplan {{ args }}

[confirm('Apply tofu changes to the MikroTik router [y|N] ?')]
[doc('Apply the plan written by `just mikrotik plan` (default: plan.tfplan)')]
apply *args='plan.tfplan': preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu apply {{ args }}

[doc('Show current state or a resource (read-only)')]
show *args: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu show {{ args }}

[doc('Reconcile state with the router without changing it (read-only)')]
refresh: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu apply -refresh-only

# `bws run` joins its argv with spaces and re-runs the result through `sh -c`,
# which consumes one layer of quoting. A for_each address like
# this["tofu"] arrives at tofu as this[tofu] and fails to parse, so the double
# quotes are escaped here to survive that extra pass. Pass the address plainly:
#   just mikrotik import 'routeros_system_user.this["tofu"]' tofu
[doc('Import an existing router resource, e.g. just mikrotik import routeros_system_identity.this .')]
import address id: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu import '{{ replace(address, '"', '\"') }}' '{{ id }}'

# Generates the keypair locally and only ever registers the public half. The
# private key goes into the client .conf and nowhere else -- not the router, not
# the repo, not tofu state. Run under `bws run` because it reads the server's
# public key from the router rather than caching a copy.
[doc('Add a WireGuard peer and generate its client config: just mikrotik wg-add NAME [--qr]')]
wg-add *args: preflight
    cd "{{ source_directory() }}" && {{ bws }} bash "{{ source_directory() }}/scripts/wg-peer-add.sh" {{ args }}

[doc('Drop into a secret-populated shell for ad-hoc tofu/router commands')]
shell: preflight
    cd "{{ source_directory() }}" && {{ bws }} bash

[doc('Pass through any tofu subcommand, e.g. just mikrotik run state list')]
run *args: preflight
    cd "{{ source_directory() }}" && {{ bws }} tofu {{ args }}
