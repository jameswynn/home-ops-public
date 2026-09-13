# CalDAV & CardDAV MCP backends

Calendar (#1551) and contacts (#1552) for Jonathon's `secretary` profile, from the
Nextcloud instance at `cloud.${SECRET_ROOT_DOMAIN}`.

Manifests: [`config/caldav.yaml`](config/caldav.yaml),
[`config/carddav.yaml`](config/carddav.yaml). Cedar permits:
[`config/authzconfig.yaml`](config/authzconfig.yaml). Profile map: [`OIDC.md`](OIDC.md).

---

## Upstream

| | |
|---|---|
| Project | [`pi0n00r/nextcloud-mcp-server`](https://github.com/pi0n00r/nextcloud-mcp-server) — maintained fork of `cbcoutinho/nextcloud-mcp-server` |
| License | AGPL-3.0 |
| Image | `ghcr.io/pi0n00r/nextcloud-mcp-server:v1.8.1` |
| Digest | `sha256:0984b2a0a2a5546fc8ef188282ad2c8a78070c823d92977e40d3fc9766ca677b` (multi-arch index) |
| Architectures | `linux/amd64`, `linux/arm64` |
| Full surface | 164 tools across 12 Nextcloud apps — narrowed to 9 + 6 here |

Upstream publishes exact release tags and deliberately ships **no floating `latest`**,
so Renovate must match on the `v`-prefixed tag. There is no CalDAV- or CardDAV-only
MCP server; this image is the whole-Nextcloud one, restricted at deploy time.

**Why two MCPServers from one image.** The epic (#1547) gives Carol/coach CardDAV
*without* CalDAV, which needs two Cedar prefixes. Splitting also means the calendar
pod never registers a contacts tool and vice versa, and each carries its own
Nextcloud app password. Cost is a second ~325 MiB pod.

---

## Tool surface

Three independent layers, each narrower than the last. Layer 3 alone is **not** a
surface reduction: `tools/list` on the unified VMCP is not filtered per profile
(see [OIDC.md](OIDC.md)), so layers 1 and 2 are what keep excluded tools out of
every profile's view.

| Layer | Mechanism | caldav | carddav |
|---|---|---|---|
| 1. Server process | `--enable-app` CLI arg | 18 tools | 11 tools |
| 2. ToolHive proxy | `MCPToolConfig.toolsFilter` | 9 tools | 6 tools |
| 3. Gateway authz | Cedar permit, deny-by-default | `toolhive-secretary` | `toolhive-secretary` |

### CalDAV — `caldav_nc_calendar_*`

| Tool | Class | Notes |
|---|---|---|
| `list_calendars` | read | |
| `list_events` | read | date-range + filters; `search_all_calendars` |
| `get_event` | read | |
| `get_upcoming_events` | read | next N days |
| `find_availability` | read | free-slot search across attendees |
| `create_event` | write | RRULE, reminders, attendees |
| `update_event` | write | only passed arguments are touched; rest preserved |
| `create_meeting` | write | convenience wrapper with meeting defaults |
| `delete_event` | **destructive** | `destructiveHint=true` |

Excluded: `manage_calendar` (creates/deletes whole collections),
`bulk_operations` (filter-matched mass update/delete — blast radius is whatever the
model's filter matches), and all 7 VTODO/task tools (`list_todos`, `get_todo`,
`search_todos`, `create_todo`, `update_todo`, `complete_todo`, `delete_todo`).

Tasks are out of scope for #1551 and this profile's list-shaped work is served by the
Koffan backend. To enable them: uncomment the block in `caldav.yaml`'s `toolsFilter`
**and** add matching `caldav_nc_calendar_*todo*` permits to `authzconfig.yaml`. A
permit without a filter entry does nothing.

### CardDAV — `carddav_nc_contacts_*`

| Tool | Class | Notes |
|---|---|---|
| `list_addressbooks` | read | |
| `list_contacts` | read | returns ETags by default, for chaining into a patch |
| `search_contacts` | read | substring over FN/nickname/email; phone digits-normalised |
| `get_contact` | read | returns raw vCard + ETag |
| `create_contact` | write | accepts full vCard text or a JSON projection |
| `patch_contact` | write | byte-preserving, `If-Match` required |

**This backend exposes no destructive tool.** Excluded: `delete_contact` and
`delete_addressbook` (both `destructiveHint=true`), `create_addressbook`
(collection structure is a human decision), `put_contact` (full raw vCard replace —
drops any property the model does not echo back), and `update_contact` (upstream
marks it DEPRECATED; lossy JSON shim over `patch_contact`).

Because that boundary lives in `toolsFilter`, it holds for *every* profile, not just
the ones with a Cedar permit. Deleting a contact stays a human action in the
Nextcloud UI.

---

## Behaviour the operator needs to know

### Timezones

`create_event` / `update_event` take ISO-8601 `start_datetime` / `end_datetime`, and
the `timezone` argument selects the encoding: with a timezone the value is written as
a zoned `DTSTART;TZID=`, without one it is written floating, and a date-only value
produces an all-day `VALUE=DATE` event. The cluster's `CLUSTER_TZ` is **not** consulted
— the container has no `TZ` set, so anything the model omits is interpreted by the
server, not by local configuration. Callers should pass `timezone` explicitly.

### Recurrence

`create_event` accepts `recurring=true` plus an RFC 5545 `recurrence_rule`
(e.g. `FREQ=WEEKLY;BYDAY=MO`). Read tools expand recurrences and apply `EXDATE` and
`RECURRENCE-ID` overrides.

The sharp edge is on writes: `update_event` and `delete_event` act on the **event UID**,
so they hit the whole series, not one occurrence. There is no "this occurrence only"
argument in the exposed surface. To change a single instance, the model must be told to
create a `RECURRENCE-ID` override event rather than update the series.

### Destructive operations

`delete_event` is the only destructive tool exposed across both backends.

- A missing event returns success (404 treated as already-gone), so retries are safe.
- A server *refusal* — a scheduled/iMIP object with attendees, or a stale trashbin
  entry still holding the UID — returns `success=false` with an explanation rather
  than raising. **The model may read that as "done".** Treat a `success=false` from
  `delete_event` as "the event is still there".
- Nextcloud's calendar trashbin applies, so a deletion is recoverable from the web UI
  for the retention window.

### Duplicate handling

CardDAV has no server-side duplicate detection. `create_contact` requires a caller-chosen
`uid`; reusing an existing UID **overwrites** that contact rather than erroring, and a
fresh UID creates a second card for the same person with no warning. Nextcloud's own
"merge contacts" UI is the cleanup path.

The mitigation is procedural, and belongs in the Hermes secretary profile prompt:
search before creating. `search_contacts` matches substrings over full name, nickname,
email, and phone (digits-normalised, so `2345678` matches `+1 234-567-8`).

### Concurrency

`patch_contact` requires an `If-Match` ETag from a prior `get_contact` or
`list_contacts`. A concurrent edit from a phone or the web UI surfaces as a 412
conflict instead of silently overwriting. Untouched properties — PHOTO blobs,
`X-` extensions, line-folded NOTEs — round-trip byte-equal.

---

## Credentials

Two dedicated Nextcloud **app passwords**, one per backend, in the `toolhive-mcp`
Bitwarden Secrets Manager item:

| Bitwarden key | Consumed as | Backend |
|---|---|---|
| `NEXTCLOUD_CALDAV_USERNAME` | `NEXTCLOUD_USERNAME` | `caldav` |
| `NEXTCLOUD_CALDAV_APP_PASSWORD` | `NEXTCLOUD_PASSWORD` | `caldav` |
| `NEXTCLOUD_CARDDAV_USERNAME` | `NEXTCLOUD_USERNAME` | `carddav` |
| `NEXTCLOUD_CARDDAV_APP_PASSWORD` | `NEXTCLOUD_PASSWORD` | `carddav` |

Templated in [`operator/externalsecret.yaml`](operator/externalsecret.yaml) and picked
up on the next 15-minute refresh. The Nextcloud **admin** Bitwarden item is deliberately
not extracted into this namespace.

### Scoping the account down

> Nextcloud app passwords are **account-wide**. There is no per-calendar or
> per-address-book credential scope — an app password can reach everything its account
> can reach. The tool surface, not the credential, is what limits these backends.

The narrowest arrangement Nextcloud actually supports, and what to create:

1. A **dedicated Nextcloud user** (e.g. `mcp-secretary`) that owns nothing. Do not use
   a personal account: the credential inherits every calendar and address book on it.
2. **Share** just the calendars and address books the secretary should reach with that
   user, at the intended permission (read-only shares stay read-only through CalDAV —
   this is the only real write boundary Nextcloud offers).
3. Create two app passwords on it — Settings → Security → Devices & sessions — one per
   backend, and **untick "Allow filesystem access"** on both. Neither backend enables
   the `webdav` app module, so file tools are not registered; the toggle is belt and
   braces if the module list is ever widened.
4. Revoke either app password independently from that same screen. Revocation takes
   effect on the next request; no Flux change is needed.

Because scopes are the *shares*, verify them from the Nextcloud UI as
`mcp-secretary` — the manifests cannot express or enforce this, and a
`toolsFilter` entry for a write tool is only as narrow as the share behind it.

### A note on the `scopes` in upstream's tool definitions

Upstream decorates tools with `@require_scopes("calendar.read")`, `"contacts.write"`
and so on. **Those are inert here.** They are only enforced in the OAuth/Login-Flow
deployment modes; in `single_user_basic` there is no access token, and the decorator
allows every call. Do not read them as a live boundary — the real ones are
`--enable-app`, `toolsFilter`, Cedar, and the Nextcloud shares above.

---

## Deployment notes

- **Endpoint.** `NEXTCLOUD_HOST=https://cloud.${SECRET_ROOT_DOMAIN}`, not the
  `nextcloud2.office.svc.cluster.local` Service, matching the joplin backend: internal
  DNS resolves the public name to the internal gateway so traffic stays in-cluster, and
  it is the only value guaranteed to be in Nextcloud's `trusted_domains`. The Coraza WAF
  is attached to the `towonel` gateway only and already carries DAV carve-outs
  (rules `900202` for the DAV verbs, `900310` for XML/vCard bodies), so neither path
  inspects these requests into failure. Switching to the in-cluster Service would save a
  hop but requires confirming `trusted_domains` first.
- **Transport.** Image ENTRYPOINT is
  `nextcloud-mcp-server run --host :: --dual-stack` with no CMD, so `args:` are
  appended. Default transport is streamable-http on port 8000 at `/mcp` — which is what
  ToolHive expects, so no path override is needed (unlike the Actual Budget backend).
- **Filesystem.** The operator imposes `readOnlyRootFilesystem`. Both pods mount
  emptyDirs at `/tmp` (SQLite session store, `TOKEN_STORAGE_DB` pinned there) and
  `/app/data` (image WORKDIR state). Verified by running the pinned digest with
  `--read-only --user 1000:0` and exactly these mounts.
- **Probes.** `/health/live` checks nothing external, so a Nextcloud blip never restarts
  the pod. `/health/ready` gates only on local config — Nextcloud reachability is
  reported in the body but is non-gating upstream by design, so an outage degrades tools
  rather than pulling the single replica from its Service.
- **Resources.** Measured 325 MiB (caldav) / 316 MiB (carddav) RSS idle from the pinned
  digest. Request 384Mi, limit 768Mi, no CPU limit per cluster convention. Declaring
  `ephemeral-storage` is required: the `ai` LimitRange defaults every container to a
  64 MiB limit that the emptyDirs count against.
- **Image size.** ~341 MiB compressed / ~1 GiB unpacked (bundles tesseract and document
  processors that this configuration does not use). Spegel mirrors it peer-to-peer after
  the first pull.

---

## Verification

The tool surface below was read from the pinned digest, not inferred from docs.
Confidence is **EXACT** for both backends.

```bash
docker run -d --name nc-caldav-test --user 1000:0 --read-only \
  --tmpfs /tmp:rw,size=64m --tmpfs /app/data:rw,size=16m \
  -e NEXTCLOUD_HOST=http://nextcloud.invalid:8080 \
  -e NEXTCLOUD_USERNAME=probe -e NEXTCLOUD_PASSWORD=probe \
  -e MCP_DEPLOYMENT_MODE=single_user_basic \
  -p 18000:8000 \
  ghcr.io/pi0n00r/nextcloud-mcp-server:v1.8.1@sha256:0984b2a0a2a5546fc8ef188282ad2c8a78070c823d92977e40d3fc9766ca677b \
  --enable-app calendar

curl -s localhost:18000/health/live   # {"status":"alive","mode":"basic"}
# then MCP initialize → notifications/initialized → tools/list on /mcp
```

Results, with an unreachable Nextcloud (proves the surface is static, not
capability-gated — upstream never gates calendar/contacts, since they speak
CalDAV/CardDAV and work with the web apps uninstalled):

- `--enable-app calendar` → exactly the 18 `nc_calendar_*` tools, nothing from
  files/mail/deck/talk/notes.
- `--enable-app contacts` → exactly the 11 `nc_contacts_*` tools.
- `readOnlyHint=true` on every read tool, `destructiveHint=true` on `delete_event`,
  `delete_todo`, `delete_contact`, `delete_addressbook`. Upstream annotations are
  correct, so they are passed through unmodified rather than overridden.
- `nc_get_capabilities` is an MCP **resource**, not a tool, so it does not appear in
  `tools/list` and needs no Cedar permit.

### Post-deploy

`toolsFilter` and the Cedar names are derived from the above, so no name correction
should be needed. Still confirm the VMCP prefix is applied as expected:

```bash
kubectl -n ai port-forward svc/vmcp-unified 4483:4483 &
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:4483/tools/list \
  | jq -r '.[].name' | grep -E '^(cal|card)dav_'
```

Expect 9 `caldav_nc_calendar_*` and 6 `carddav_nc_contacts_*`. If names come back
double-prefixed or unprefixed, correct `authzconfig.yaml`.

Then exercise the acceptance flows as Jonathon:

- **Calendar read** — `caldav_nc_calendar_list_calendars`, then
  `caldav_nc_calendar_list_events` over a known range.
- **Contact read** — `carddav_nc_contacts_search_contacts` for a known name.
- **Denial** — the same calls as a `toolhive-basic` token must be denied by Cedar, and
  `carddav_nc_contacts_delete_contact` must fail as unknown for *every* profile, since
  `toolsFilter` never exposes it.

### Known blocker

Both pods will `CrashLoopBackOff` until the four Bitwarden fields above exist and the
ExternalSecret has synced them — the server requires `NEXTCLOUD_USERNAME` and
`NEXTCLOUD_PASSWORD` at startup in `single_user_basic` mode. This is inert, not a
security gap: Cedar denies every `caldav_*`/`carddav_*` call while the backends are
absent. Create the Nextcloud service account and app passwords first.
