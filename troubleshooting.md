## Get All Images Using Docker Hub

```sh
kubectl get pods --all-namespaces -o jsonpath="{.items[*].spec['initContainers', 'containers'][*].image}" | tr -s '[[:space:]]' '\n' | grep -v '^(registry.k8s.io|quay.io|mirror.gcr.io|ghcr.io|lscr.io|dock.mau.dev|codeberg.org|code.forgejo.org|gcr.io|forgejo.ellis.link|public.ecr.aws)/' | sort | uniq -c
```

## Mounting a new NFS share from Synology

- Create a user and group in Synology. I called them both "k8s".
- Change the UID in /etc/passwd for k8s to 1000
- Change the GID in /etc/groups for k8s to 1000
- Create the new shared directory
- Give k8s user and group full access via Synology permissions
- chown the directory to 1000:1000
- chmod the directory to 755
- Via Synology Control Panel -> Shared Folder, edit the folder and change the NFS Permissions
  - Add 192.168.1.0/24, Read/Write, Map root to admin, Security: sys, Enable asynchronous, Allow users to access mounted subfolders

Now mount the folder. Ex via app-template:
```yaml
    persistence:
      data:
        type: nfs
        server: ${SECRET_NAS_URL}
        path: /volume1/garage-k8s/data
        globalMounts:
          - path: /data
```

## Loki queries hang / all Grafana Loki panels spin forever

Loki (`core/monitoring/loki`) runs in SimpleScalable mode with **Garage** as its
S3 object store. Two independent failures produce the same symptom — every
Loki-backed panel spins and even `GET /loki/api/v1/labels` times out (`http=000`):

1. **Garage storage is unhealthy.** Check the ingester flush path:
   ```sh
   kubectl -n monitoring logs loki-write-0 --since=10m | grep -iE "failed to flush|malformed|quorum|50[23]"
   ```
   Errors like `S3 PutObject 503 ... Could not reach quorum of 1 ... Sqlite:
   database disk image is malformed` mean Garage's metadata DB is corrupt / a
   node is down. Fix Garage first (`garage status`, repair/replace the bad node).

2. **`loki-read` is wedged even though Garage is healthy.** After a Garage
   outage the query-frontend↔scheduler↔querier queue can get stuck: new queries
   enqueue and are never serviced, so reads hang with **no error logs**. Confirm
   the store itself is fine — the ruler on `loki-backend` keeps running store
   queries at `status=200`:
   ```sh
   kubectl -n monitoring logs loki-backend-0 -c backend --since=5m | grep "status=200"
   ```
   If the backend queries fine but `loki-read` hangs, bounce the read tier
   (stateless, no data loss):
   ```sh
   kubectl -n monitoring rollout restart deployment/loki-read
   # if still stuck, also reset the scheduler tier:
   kubectl -n monitoring rollout restart statefulset/loki-backend
   ```

## Coraza WAF false positives (CRS rule exclusions)

The Coraza WAF (`core/networking/envoy-gateway/proxy/envoy-extension-policy-coraza-wasm.yaml`)
runs OWASP CRS on the **towonel** gateway in blocking mode (`SecRuleEngine On`,
`failOpen: false`). CRS uses anomaly scoring: each matched rule adds to a score
and a single critical rule (score 5) is enough to cross the blocking threshold, so
**one false positive = a 403** for otherwise-legitimate traffic. Self-hosted apps
trip these constantly because they carry machine payloads (XML, JSON-LD, git
packs) and federated/arbitrary user content that *looks* like attacks.

Because the WAF is **fail-closed**, a malformed exclusion that fails to parse takes
down *all* towonel ingress — so every change below is a single `SecRule` (no
chained rules), validated, and verified through the live edge before trusting it.

### The process

1. **Find what fired — from Loki, not the pod.** The envoy pod's log buffer
   rotates in minutes; Loki has the retention. Query the human-readable `Coraza:`
   line — its `[data ...]` field names the rule id, the matched token, and the
   **target variable**, which is what you scope against. Its `[uri ...]` gives the
   path; the JSON `AuditLog:` line's `server_id` gives the **vhost** (the
   `[hostname ...]` in the text line is the backend pod IP, not the domain).
   ```sh
   # loki-gateway has no external route → run curl from a throwaway in-cluster pod
   kubectl -n monitoring run q --rm -it --image=curlimages/curl -- sh -c \
    'curl -s -G http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/query_range \
      --data-urlencode "query={namespace=\"networking\",pod=~\"envoy-towonel-.*\"} |= \"Coraza:\" |~ \"id .930130\"" \
      --data-urlencode "start=$(($(date +%s)-259200))000000000" --data-urlencode "end=$(date +%s)000000000"'
   ```
2. **Read the actual CRS rule** before excluding. Fetch it from the pinned CRS
   version (`rules/REQUEST-NNN-*.conf` at `coreruleset` tag `v4.14.0`) to learn its
   **phase**, its target variables, and whether it *also* catches real attacks
   (e.g. 930130 blocks legit `/<user>/.profile` **and** `/.env` / `/.git/HEAD`
   scans). This decides how narrowly to scope.
3. **Reproduce and baseline through towonel** so you have a before/after signal
   (see verification below). Confirm it's currently a 403.
4. **Write the narrowest exclusion that fixes it** (host and/or path scoped),
   place it in the before-CRS block, deploy, and re-verify.

### Scoping: host vs path vs body-processor

Pick the tightest lever for the actual cause:

- **Path-scoped** (`SecRule REQUEST_URI "@rx ^/path/"`) when the path is
  app-unique — e.g. `/remote.php/dav` (Nextcloud), `/_matrix/` (Matrix). The path
  itself bounds the blast radius.
- **Host-scoped** (`SecRule REQUEST_HEADERS:Host "@streq host"`, or `@rx` for
  several) when the trigger is generic — e.g. `/rest/` (Navidrome Subsonic) or a
  cookie/method that any app could send. A path rule there would silently disable
  protection for other apps that share the path.
- **Fix the parser, don't remove the rule**, when the real cause is a mis-parsed
  body. Coraza only auto-selects the JSON body processor for bare
  `application/json`, so `application/activity+json` / XML bodies get parsed as
  **urlencoded form args** — the raw markup then trips XSS/SQLi/unicode rules
  (941/942/920540). Forcing the right processor inspects the payload correctly and
  kills the whole class at once:
  `SecRule REQUEST_HEADERS:Content-Type "@rx (?i)^application/(activity\+json|ld\+json)" "...,ctl:requestBodyProcessor=JSON"`.
- **Federation / arbitrary-content APIs** (Matrix `/_matrix/`, ActivityPub
  inboxes) carry content from the whole network that legitimately contains SQL/
  shell/HTML strings. These are FP factories with ~no benefit (the apps aren't
  content-injectable and return JSON, not browser HTML), so drop the injection
  families wholesale for that host — e.g. `ctl:ruleRemoveById=932000-944999`
  (RCE/PHP/Node/XSS/SQLi/session/Java) for `matrix.wynning.tech`.

### Gotchas that cost real debugging time

1. **Ordering (the big one).** Exclusions must be defined **before**
   `Include @owasp_crs/*.conf`. Coraza runs rules within a phase in *definition
   order*, and many CRS rules are **phase 1** (911100 methods, 920xxx protocol,
   930130). A phase-1 `ctl:ruleRemoveById` placed *after* the include runs after
   the target already fired and scored — silently ineffective, the app still 403s.
   Keep every exclusion in the before-CRS block so it works regardless of the
   target's phase.
2. **Never `setvar` the `tx.allowed_*` lists with a `%{...}` append.** Those
   variables (`tx.allowed_methods`, `tx.allowed_request_content_type`) expand to
   **empty** at exclusion time in this build, so `setvar:'...=%{...} extra'`
   *replaces* the whole list with just `extra` — e.g. it once wiped the allowed
   content-type list on the fediverse hosts, 403-ing all normal `json`/form traffic
   while AP still worked. Prefer `ctl:ruleRemoveById` on the enforcing rule
   (920420/920470/911100). The one safe append is when *you* set the base first in
   an unconditional global `SecAction` (as 900201 does for methods) and append in a
   later rule.
3. **Scope, don't nuke.** Require a leading path segment or host so real attacks
   still hit the rule — e.g. `^/[^/]+/\.profile(/|$)` exempts Forgejo profile repos
   but still blocks a root `/.profile` probe. When you *do* drop a rule host-wide,
   note the trade-off in a comment (e.g. forge no longer catches `/.env` via 930130).
4. **The app's own error ≠ a WAF block.** A signed federation endpoint returns
   401/403 for missing signatures *after* the WAF passes. Don't read a 403 as "still
   blocked" — confirm from the logs whether Coraza actually fired (no `Coraza:` line
   for the request = the WAF let it through; the status came from the app).
5. **The `Host` header can include the port.** Server-to-server clients (Matrix/
   ActivityPub federation, some API clients) send `Host: matrix.wynning.tech:443`,
   so `@streq matrix.wynning.tech` silently never matches and the exclusion doesn't
   fire on real federation traffic. Match hosts with an anchored, port-tolerant
   regex: `@rx (?i)^matrix\.wynning\.tech(:[0-9]+)?$`. A `curl --resolve` test sends
   `Host` *without* the port, so it passes and hides this — pin the port explicitly
   with `-H "Host: host:443"` when verifying a host-scoped federation rule.

### Verify through towonel — internal DNS bypasses the WAF

App hostnames resolve (split-horizon) to the `envoy-internal` gateway, which has
**no WAF** — so `curl https://cloud.wynning.tech/...` from the LAN tests nothing.
Drive the request through the towonel edge instead:

- **Path-scoped** rules match on any host → just use the echo pilot:
  `curl https://echo.wynning.tech/<the/path>`.
- **Host-scoped** rules → force the real host through the edge with `--resolve`
  (the public IP of heimdall, the towonel VPS — same for every app hostname):
  `curl --resolve social.wynning.tech:443:<vps-ip> https://social.wynning.tech/...`.
  Get the IP with `dig +short @1.1.1.1 echo.wynning.tech`.
- **Prove content-gating** with a clean-vs-malicious pair on the same path: clean
  body → 200, injection body → 403 confirms the block is the WAF reacting to
  content (and that a host-scoped exemption really is off elsewhere).

### Exclusions on record (why each exists)

| App / host | Rule(s) dropped | Cause |
| --- | --- | --- |
| Nextcloud `cloud.wynning.tech` | 911100 (append WebDAV verbs, host-scoped) | WebDAV/CalDAV methods (PROPFIND, MKCOL, …) not in the method allowlist |
| Nextcloud `/remote.php/dav` | 941xxx | CalDAV XML body parsed as form args, markup trips XSS |
| Forgejo `forge.wynning.tech` | 930130, 920420 | repos legitimately contain dotfiles; git smart-HTTP content types |
| Navidrome `navidrome.wynning.tech` | 942100, 932160 | Subsonic hex tokens read as SQLi; RFC 2965 `$Path` cookie = shell var |
| GoToSocial + proxy `social*.wynning.tech` | 920420, 920470 + force JSON processor | ActivityPub content types + `profile` param + JSON-LD unicode escapes |
| Matrix `matrix.wynning.tech` | 932000-944999 (injection families) | federation carries arbitrary network content |
| Blog `blog.jameswynn.com` | 920420 | Plausible `/api/event` beacon uses `text/plain` |

**Recurring offenders.** 920420 (content-type allowlist) has false-positived
across four apps and is a weak control — apps reject unexpected content types
themselves. If it keeps recurring, prefer expanding the allowed list once (safely,
i.e. an explicit full list, not a macro append) or dropping 920420 broadly over
more per-host `ctl` rules.
