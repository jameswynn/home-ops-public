---
name: ingress-triage
description: |
  Audit envoy-gateway access logs in Loki to find real ingress problems (broken routes,
  misattached HTTPRoutes, direct-response 500s, WAF/rate-limit misfires, dead gateways)
  and separate them from internet background noise.

  Use when: (1) asked to analyze/audit envoy or gateway logs over some window,
  (2) investigating elevated 4xx/5xx on a hostname, (3) a route "works internally but
  not externally" (or vice-versa), (4) Gatus endpoints are failing and you need to know
  whether the app or the route is at fault, (5) verifying an ingress change actually took
  effect after a Flux reconcile.

  Triggers: "analyze envoy logs", "gateway errors", "why is <host> 404ing",
  "check ingress health", "500s on", "audit the access logs", "is the route working"
user-invocable: true
---

# Ingress triage — envoy access logs via Loki

The envoy gateways emit one JSON access-log line per request. Loki has ~all of it;
`kubectl logs` does **not** (see Trap 4). This skill is the funnel for turning that
firehose into a short list of real, actionable problems.

The funnel is mechanical. The diagnosis at the end is not — most of the value is in
*not* chasing the ~90% of anomalies that are internet background noise.

## Setup

Use `scripts/lq.sh`. It manages the port-forward, sets `X-Scope-OrgID: fake`, enforces
the step/range invariant (Trap 1), and prints a table.

```bash
S=.claude/skills/ingress-triage/scripts/lq.sh

# Aggregation (default: last 24h, step=3600)
bash $S --hours 48 'sum by (code) (count_over_time({job="networking/envoy"} | json code="response_code" [1h]))'

# Raw lines — newest first
bash $S --raw --hours 2 --limit 20 '{job="networking/envoy"} | json code="response_code" | code=~"5.."'
```

Stream selector is `{job="networking/envoy"}`. The `pod` label distinguishes gateways —
`envoy-towonel-*` (VPS tunnel, the only public path) and `envoy-internal-*` (LAN).
There is no gateway-name label; group by `pod` and map the prefix yourself.

## The four traps

These produce **plausible wrong numbers, not errors**. Every one of them has burned a
previous run of this analysis.

1. **Range selector must be `[1h]` and step must be 3600.** Loki splits queries on a 1h
   boundary; `[2h]`/step=7200 double-counts across splits. The same metric returned 9,012
   at `[1h]` and 43,606 at `[2h]`. `lq.sh` warns if the query contains a non-`[1h]` range.

   **Corollary — the first bucket bleeds in up to an hour of earlier data.** Steps align to
   absolute time, so a window starting 12:11Z gets a bucket at 12:00 covering 11:00–12:00.
   Measured live: a 6h window reported 11,354 rate-limited requests when the most recent one
   was 63 minutes before the window even opened (4h and 5h windows both correctly returned
   0). So a total is only trustworthy to ±1h at the leading edge. If a number matters, walk
   the window (`--hours 4,5,6,7`) and watch where it jumps, then confirm against raw
   `start_time`. Never report a total from a single window without that check.
2. **Bare `| json` blows the 500-series cap** — it promotes every field to a label, and you
   silently get ~5 buckets instead of 48. Always extract only what you need:
   `| json code="response_code", rt="route_name"`.
3. **Fields with special characters need bracket notation**: `| json ua="[\"user-agent\"]"`,
   `auth="[\":authority\"]"`. Plain `ua="user-agent"` is a parse error. High-cardinality
   fields still need `topk()` under the cap.
4. **Never read timing off bucket labels.** Loki aligns range-query steps to absolute time,
   and the label's relationship to the interval it covers is not reliable across queries —
   observed both end-aligned and start-aligned. Bucket labels are fine for *shape* (is this
   bursty or sustained?) and useless for *when*. To state a time, pull the **raw lines** and
   read `start_time` out of the JSON. This has produced a wrong incident correlation twice.

Corollary: `kubectl logs` is not a substitute. Rotation is aggressive — `--since=48h` on the
towonel envoy pod returned 5k lines where Loki had 651k.

## The funnel

Run these in order. Each step narrows; don't skip to grepping for a hostname.

```bash
# 1. Volume per gateway — establishes the baseline and catches a dead gateway
sum by (pod) (count_over_time({job="networking/envoy"} [1h]))

# 2. Response flags — the highest-signal single cut
sum by (flag) (count_over_time({job="networking/envoy"} | json flag="response_flags" [1h]))

# 3. Status codes, per gateway
sum by (pod, code) (count_over_time({job="networking/envoy"} | json code="response_code" [1h]))

# 4. For each interesting (flag, code): which route?
topk(20, sum by (rt) (count_over_time(
  {job="networking/envoy"} | json code="response_code", rt="route_name" | code=~"5.." [1h])))

# 5. Was it Envoy or the app? — the load-bearing distinction
sum by (det) (count_over_time(
  {job="networking/envoy"} | json code="response_code", det="response_code_details"
  | code=~"5.." [1h]))
```

### `response_code_details` is the key field

| value | meaning |
| --- | --- |
| `via_upstream` | the **app** produced this status. Go look at the app. |
| `direct_response` | **Envoy** produced it locally — route filter, or a rule with no `backendRefs`. This is a config bug in the HTTPRoute, not an app problem. |
| `route_not_found` | no route matched the `:authority` + path on that listener |
| `ext_authz_denied` | forward-auth rejected it |

A rule that matches a path but has **no `backendRefs` and no filters** yields a
`direct_response` 500. That is the signature of a half-commented-out route.

### Response flags worth knowing

`-` clean · `NR` no route configured · `UF` upstream connection failure ·
`UH` no healthy upstream · `UC` upstream connection termination · `URX` retry/connect-attempt
limit · `UT` upstream timeout · `UAEX` ext_authz denied · `RL` rate-limited ·
`DC` downstream connection termination · `DPE` downstream protocol error ·
`SI` stream idle timeout · `NC` no cluster found.

Flags combine (`RL,DR`, `URX,UF`). `DR` shows up here almost exclusively alongside `RL` —
i.e. the downstream reset that follows a locally-generated rate-limit response, not an
independent fault. Anything unfamiliar: look it up in the Envoy access-log docs rather than
guessing — a misread flag sends the whole investigation the wrong way.

## Noise vs signal

Most anomalies on the public gateways are the internet, not a bug. Classify before escalating.

**Noise — do not report as an issue:**
- 404s on `envoy-towonel` for `/wp-admin`, `/.env`, `/.git/config`,
  phpMyAdmin paths, etc. Bot scanning. Confirm by checking `user-agent` and path spread.
- `DC` on long-lived streams (websockets, SSE, Matrix sync, `/notifications/hub`) — clients
  disconnect; that's normal.
- 401/403 on forward-auth-protected hosts from unauthenticated crawlers.
- Federation/ActivityPub delivery failures where the **remote** side is broken (410 Gone,
  406, redirect loops). Check the failure is remote-side before touching our config.

**Signal — real, act on it:**
- Any `direct_response` 5xx (config bug, always ours).
- `NR` / `route_not_found` on a hostname we intend to serve — typically a typo in
  `parentRefs.name`, or a route attached to a gateway that doesn't carry that hostname.
- A route present on one gateway but absent from another when it should be on both
  (split-horizon: `envoy-internal` **and** `envoy-towonel`).
- Any nonzero volume on a gateway that should be idle, or ~zero on one that shouldn't be.
- `RL` on a legitimate client — check the regexes in the relevant `ratelimitpolicy.yaml`
  actually match what you think they do before blaming the rate limit. (gRPC paths like
  `/api/actions/runner.v1.RunnerService/*` match none of the anti-scraper patterns.)
- Sustained 5xx from `via_upstream` on one route → it's an app problem; hand off to app logs.

## Cross-checks that resolve ambiguity

- **xDS health.** If a gateway is serving stale config, log symptoms won't match the manifests.
  `kubectl -n networking logs deploy/envoy-gateway | grep -iE "reject|NACK|Didn't find"`.
  A NACK invalidates the **whole** update for that gateway, so an unrelated listener error
  (e.g. a TCP-only filter on a QUIC listener) silently freezes everything.
- **Gatus is the oracle.** Its endpoint count is generated from HTTPRoute annotations, so a
  failing Gatus endpoint is either a real outage *or* a bad auto-generated probe URL. The
  sidecar picks the first non-root rule path, which is frequently wrong (a websocket port, a
  prefix with no handler at its bare path). Pin it rather than "fixing" a healthy app:
  ```yaml
  annotations:
    gatus.home-operations.com/endpoint: |-
      url: https://host/healthz
      conditions: ["[STATUS] == 200"]
    # or, for a route that is a public 404 by design:
    gatus.home-operations.com/enabled: "false"
  ```
  **Always curl the probe target before pinning it** — pin the URL you verified, not the one
  you assume works.
- **Which gateway?** `downstream_local_address` port + the `pod` label. On `envoy-towonel`,
  `downstream_remote_address` is the real client IP only because PROXY protocol v2 is
  working; if every request shows the same RFC1918 address, suspect the ClientTrafficPolicy —
  *unless* that address is a known VPS-side client (172.18.0.1 is the Forgejo build agent on
  the VPS docker bridge, and is legitimate).

## Verification loop

After any ingress change, do not trust `kubectl get httproute` alone — Flux reconcile,
envoy-gateway translation, and xDS push are three separate steps that can each stall.

```bash
flux -n <ns> reconcile ks <name> --with-source
kubectl -n networking get gateway,clienttrafficpolicy -o wide   # look for Warning/Deprecated conditions
# then hit the actual path through each gateway it should differ on:
curl -sI https://host/path                          # public (towonel/external)
curl -sI --resolve host:443:<lan-ip> https://host/path   # internal
```
Confirm the fix in the logs too — re-run funnel step 4 for that route and check the bad
bucket goes to zero. Then confirm the Gatus failing-endpoint count dropped.

## Reporting

Give the user a ranked list of **real** issues with: hostname/route, what the logs show
(with counts and the window they cover), the mechanism, and the fix. Explicitly say what
you classified as noise and why — otherwise "no issues found" is indistinguishable from
"didn't look". If a count came from a query you later found suspect, say so and re-derive
it; a confidently wrong number is worse than no number.
