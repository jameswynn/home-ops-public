# Tailscale

The tailnet is a single-user network (`james@wynning.tech`) that does three jobs:
give personal devices a path into the cluster from anywhere, give the off-cluster
VPS (`heimdall`) a private path to push metrics and logs in, and provide the
internal split-DNS resolvers to roaming devices. The access policy is **not** in
this repo — it is edited in the admin console's visual editor
(<https://login.tailscale.com/admin/acls/visual>). This file records what it says
and why, so the next security review does not have to rediscover it.

Last reconciled with the console: 2026-11-03 (#1333).

## Devices and tags

| device | identity | role |
| --- | --- | --- |
| `baldur`, `vizier`, `flywheel`, `haven-tailscale`, `kindle`, `Pixel 9 Pro` | user-owned (`james@`) | personal devices; members |
| `heimdall` | `tag:vps` | OVH VPS: public ingress edge (towonel hub), Forgejo runner, doco-cd, prometheus-agent, fluent-bit, CrowdSec |
| `prometheus` (`100.82.29.118`), `loki` (`100.67.197.96`) | `tag:k8s-ingest` | tailscale-operator proxies in front of `monitoring/kube-prometheus-stack-prometheus` and `monitoring/loki-gateway`. **No auth of their own**; remote_write and log push receivers |
| `default-adguard-primary-udp` (`100.113.108.41`), `default-adguard-secondary-udp` (`100.96.162.106`) | `tag:home`, `tag:k8s` | AdGuard over the tailnet; the tailnet's split-DNS resolvers for `wynning.tech` |
| `booklore` | `tag:k8s` | operator proxy for the booklore app |
| `app-connector-0/1` | `tag:connector` | operator `Connector` (`apps/tailscale/tailscale-operator/config/connector.yaml`) advertising `10.11.0.223/32` (envoy-internal) and, until #2064 retires it, `192.168.1.223/32` |
| `tailscale-operator` | `tag:k8s-operator` | the operator itself; talks to the control plane only, never to peers |

Tag owners: `tag:vps` → `autogroup:admin`; `tag:k8s-ingest` → `autogroup:admin`
**and `tag:k8s-operator`** (the operator must own a tag to mint proxies with it).

## Grants

Grants are additive and unordered; there is no deny. The catch-all
`* → *` was removed on 2026-11-03 and replaced by:

```
1  autogroup:member → autogroup:self, tag:k8s, tag:home, tag:connector, tag:vps,
                      10.11.0.223/32, 192.168.1.223/32                      : all ports
2  tag:vps          → tag:k8s-ingest                                        : tcp:9090, tcp:80
3  tag:vps          → tag:home, tag:connector, 10.11.0.223/32, 192.168.1.223/32 : all ports
```

- Rule 1 is "everything a personal device could do before, minus the two ingest
  proxies". The two IPs are the connector routes: without them members cannot use
  `*.wynning.tech` over the tailnet even though the connector is reachable.
- Rule 2 is the point of the exercise (#1333): only the VPS can reach the
  unauthenticated Prometheus and Loki write endpoints.
- Rule 3 exists because a tagged node gets no rights from rule 1. heimdall
  resolves `*.wynning.tech` through the AdGuard proxies (split DNS) and reaches
  Forgejo, Authentik and doco-cd's source through the connector route — losing
  rule 3 silently breaks the runner, doco-cd and CrowdSec's Loki tail.
- `autogroup:self` is only valid with a user/group source; that is why rule 1's
  source is `autogroup:member`, not `*`.

### Tests (saved in the policy)

The console refuses to save a policy that fails its tests, so these pin the
intent:

```
tag:vps               accept 100.82.29.118:9090, 100.67.197.96:80
james@wynning.tech    deny   100.82.29.118:9090, 100.67.197.96:80
                      accept 100.113.108.41:53, 100.114.233.46:22, 10.11.0.223:443
```

Tests evaluate against the policy *being saved*, so they have to be added in
lockstep with the state they describe (a deny cannot be saved while a rule still
allows it). Tag-selector destinations in tests resolve against existing devices;
use IPs.

## What the policy does not cover

- **AdGuard, booklore and the connector routes are reachable by every member
  device.** That is intended: the tailnet is one person's devices. The LAN
  services behind `10.11.0.223` have their own auth (Authentik forward-auth on
  most routes).
- **Prometheus/Loki still have no auth.** The admin API and the Loki ruler write
  API are off (#2075); the policy above is the only thing limiting remote_write
  and log push to heimdall. Loki gateway basic auth was deliberately not added
  (eight producers/consumers plus a manual heimdall redeploy, see #2075).
- heimdall's compose files address the proxies by hard-coded tailnet IP
  (`docker/vps/05-observability`, `docker/vps/03-crowdsec` `extra_hosts`) because
  container DNS cannot resolve MagicDNS names. If a proxy is ever recreated its
  IP changes and those entries must follow.

## Operator caveats

- `tailscale.com/tags` on a Service is applied only when the proxy **first
  registers** (it goes into the one-time auth key). Changing the annotation on a
  live proxy updates nothing on the tailnet. Either retag the device in the
  console (Machines → device → Edit ACL tags — keeps the IP) or delete the
  proxy's state Secret in the `tailscale` namespace so it re-registers (new IP).
  The annotation is still worth keeping correct so recreation comes up right.
- `tailscale.com/expose: "true"` proxies **every port** of the Service. Scope
  with the policy, not by hoping nobody finds the extra ports.
- The operator's OAuth client (`tailscale/operator-oauth`) can list devices via
  the API but cannot read or write the policy; policy changes are console-only.

## Verifying

```sh
# from heimdall: must succeed
curl -s http://100.82.29.118:9090/-/ready
curl -s -o /dev/null -w '%{http_code}\n' http://100.67.197.96/loki/api/v1/labels
curl -sk -o /dev/null -w '%{http_code}\n' https://forge.wynning.tech/   # via connector route

# from a member device: first two must time out, the rest must work
curl -m5 http://100.82.29.118:9090/-/ready
curl -m5 http://100.67.197.96/loki/api/v1/labels
dig +short forge.wynning.tech @100.113.108.41
curl -sk -o /dev/null -w '%{http_code}\n' https://auth.wynning.tech/
```

Device/tag inventory for a review:

```sh
ID=$(kubectl -n tailscale get secret operator-oauth -o jsonpath='{.data.client_id}' | base64 -d)
SEC=$(kubectl -n tailscale get secret operator-oauth -o jsonpath='{.data.client_secret}' | base64 -d)
TOK=$(curl -s -d "client_id=$ID&client_secret=$SEC" https://api.tailscale.com/api/v2/oauth/token | jq -r .access_token)
curl -s -H "Authorization: Bearer $TOK" https://api.tailscale.com/api/v2/tailnet/-/devices \
  | jq -r '.devices[]|"\(.hostname) \(.addresses[0]) user=\(.user) tags=\(.tags//[]|join(","))"' | sort
```

## History

- 2026-11-03 — #1333: catch-all removed; `tag:vps`, `tag:k8s-ingest`, rules 1–3
  and tests introduced; heimdall and the two ingest proxies retagged in the
  console. #2075 had already closed the Prometheus admin API.
