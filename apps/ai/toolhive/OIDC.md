# ToolHive OIDC & Cedar Authorization

Replaces the previous anonymous `incomingAuth` with Authentik OIDC + Cedar deny-by-default
policy authorization. Every MCP call requires a valid JWT **and** an explicit Cedar permit.

---

## Profile / Group / Tool mapping

| Profile | Authentik group | Tools |
|---------|----------------|-------|
| Zug / basic | `toolhive-basic` | SearXNG, memini-zug |
| Anton / accountant | `toolhive-accountant` | SearXNG, Ghostfolio, memini-anton, Actual Budget *(pending)* |
| Jonathon / secretary | `toolhive-secretary` | SearXNG, memini-jonathon, Koffan, CalDAV, CardDAV |
| Carol / coach | `toolhive-coach` | SearXNG, Joplin (read-only), memini-carol, CardDAV *(backend deployed, permit not granted)* |
| Hephaestus / coder | `toolhive-coder` | SearXNG, forgejo-hephaestus, Context7, GitHub, memini-hephaestus, Grafana, KubeSearch |
| Roberto / home-ops | `toolhive-home-ops` | SearXNG, forgejo-roberto, Context7, GitHub, memini-roberto, Grafana, KubeSearch, Home Assistant, Flux Operator |
| Sagan / researcher | `toolhive-researcher` | SearXNG, Karakeep (read-only), Joplin (read-only), memini-sagan |

Backends marked **pending** have no deployed MCP server yet. Cedar permits for them are
commented out in `authzconfig.yaml` and the backend resource is commented out in
`config/kustomization.yaml`. Uncomment both when the backend is ready.

### Tool name sources and verification status

| Backend | Cedar prefix | Tool names | Source | Verification |
|---------|-------------|-----------|--------|-------------|
| memini-zug | `memini-zug_` | `memory_briefing`, `memory_recall`, `memory_remember`, `memory_answer`¹, `memory_list`, `memory_get`, `memory_history`, `memory_update`, `memory_forget` | eleboucher/memini `docs/reference/mcp-tools.md` + `mcp.go` | HIGH — from source |
| memini-anton | `memini-anton_` | same 9 tools | same | HIGH |
| memini-jonathon | `memini-jonathon_` | same 9 tools | same | HIGH |
| memini-carol | `memini-carol_` | same 9 tools | same | HIGH |
| memini-hephaestus | `memini-hephaestus_` | same 9 tools | same | HIGH |
| memini-roberto | `memini-roberto_` | same 9 tools | same | HIGH |
| memini-sagan | `memini-sagan_` | same 9 tools | same | HIGH |
| joplin | `joplin_` | `joplin_search_notes`, `joplin_read_note`, `joplin_list_notes`, `joplin_list_notebooks`, `joplin_list_tags` (Cedar names: `joplin_joplin_*`) | james/containers#12 joplin-mcp adapter source | HIGH — from source³ |
| grafana | `grafana_` | 33 tools from `MCPToolConfig.toolsFilter` in `grafana.yaml` | Static manifest | EXACT — no verification needed |
| kubesearch | `kubesearch_` | `search_releases`, `get_release`, `search_images`, `grep_values`, `status`, `repo_clone`, `repo_list_files`, `repo_read_file`, `repo_grep`, `repo_cleanup` | perfectra1n/kubesearch-mcp README² | HIGH — verify post-deploy |
| homeassistant | `homeassistant_` | 83 `ha_*` tools | homeassistant-ai/ha-mcp v8.3.0 source (`@mcp.tool(name="ha_*")`) | HIGH — from source |
| flux-operator | `flux-operator_` | `get_flux_instance`, `get_kubernetes_resources`, `get_kubernetes_logs`, `get_kubernetes_metrics`, `get_kubernetes_api_versions`, `get_kubeconfig_contexts`, `set_kubeconfig_context`, `reconcile_flux_resource`, `suspend_flux_reconciliation`, `resume_flux_reconciliation`, `apply_kubernetes_manifest`, `delete_kubernetes_resource`, `diff_kubernetes_manifest`, `install_flux_instance`, `search_flux_docs` | flux-operator-mcp v0.58.1 source constants | HIGH — from source |
| koffan | `koffan_` | `get_lists`, `get_list`, `create_list`, `update_list`, `delete_list`, `get_items`, `add_item`, `update_item`, `delete_item`, `get_sections`, `add_section`, `update_section`, `delete_section`, `batch_update`, `get_history` | forge.wynning.tech/james/koffan-mcp adapter source (image not yet published) | LOW — defined by adapter; verify with `tools/list` after image is published |
| caldav | `caldav_` | 9 of 18: `nc_calendar_list_calendars`, `nc_calendar_list_events`, `nc_calendar_get_event`, `nc_calendar_get_upcoming_events`, `nc_calendar_find_availability`, `nc_calendar_create_event`, `nc_calendar_update_event`, `nc_calendar_create_meeting`, `nc_calendar_delete_event` | `tools/list` against the pinned digest⁴ | EXACT — read from the running image |
| carddav | `carddav_` | 6 of 11: `nc_contacts_list_addressbooks`, `nc_contacts_list_contacts`, `nc_contacts_search_contacts`, `nc_contacts_get_contact`, `nc_contacts_create_contact`, `nc_contacts_patch_contact` | `tools/list` against the pinned digest⁴ | EXACT — read from the running image |

**¹** `memini_memory_answer` requires `MEMINI_LLM_BASE_URL` to be set. Not configured in the current
`helmrelease.yaml` — the permit is dormant and harmless until an LLM endpoint is wired.

**²** KubeSearch tool names: the README lists tools as `kubesearch_search_releases` etc. The repo-clone
tools (`repo_clone`, `repo_list_files`, etc.) have no `kubesearch_` prefix in the README, confirming
these are the ToolHive-prefixed names (workload `kubesearch` + raw tool names `search_releases`,
`repo_clone`, etc.). Post-deploy: run `tools/list` and confirm no double-prefix
(`kubesearch_kubesearch_search_releases`). Correct Cedar permits if needed.

**³** Joplin tool names: the joplin-mcp adapter (james/containers#12,
`forge.wynning.tech/james/joplin-mcp:3.6.2@sha256:65187aae7a186ff361281d670d7c2f0b00ba2db6d6e3c7257510ce8a12704a2b`)
registers tools with a `joplin_` prefix internally. ToolHive then prepends the MCPServer name
(`joplin`) as its own prefix, yielding Cedar names in the form `joplin_joplin_<tool>`. Post-deploy:
run `tools/list` and confirm the double-prefix is present; correct Cedar permits in `authzconfig.yaml`
if the adapter is changed to drop its own prefix.

**⁴** CalDAV/CardDAV tool names were read from `tools/list` against
`ghcr.io/pi0n00r/nextcloud-mcp-server:v1.8.1@sha256:0984b2a0…` rather than inferred from docs.
Both backends are the same image, split into two MCPServers and restricted with the `--enable-app`
CLI argument (`calendar` / `contacts`) so neither pod registers the other's tools; `toolsFilter`
then narrows 18→9 and 11→6. Full rationale, the exclusion list, and the timezone / recurrence /
duplicate / destructive-operation behaviour are in [CALDAV-CARDDAV.md](CALDAV-CARDDAV.md).

---

## Manual Authentik prerequisites

All steps below must be completed before Flux can reconcile a working OIDC endpoint.

### 1. Create the Authentik OAuth2 provider

- Admin UI → **Applications → Providers → Create → OAuth2/OpenID Provider**
- **Name**: `ToolHive` *(must match the `key:` in `externalsecret-oidc.yaml`)*
- **Authorization flow**: `default-provider-authorization-implicit-consent` (or explicit)
- **Client type**: Confidential
- **Client ID**: *(auto-generated UUID — copy for step 3)*
- **Client Secret**: *(auto-generated — not needed in cluster-secrets, fetched via ExternalSecret)*
- **Redirect URIs**: not required for the resource-server role; add `https://mcp.${SECRET_INTERNAL_DOMAIN}/callback` if a browser-based flow is ever added
- **Signing key**: `authentik Self-signed Certificate`
- **Scopes**: `openid`, `profile`, `email`, `groups` (enable the Groups scope)

### 2. Create the Authentik Application

- **Name**: `ToolHive`; **Slug**: `toolhive`; **Provider**: the provider above
- The issuer URL is derived from the slug: `https://auth.<domain>/application/o/toolhive/`

### 3. Configure the `aud` (audience) claim

The VirtualMCPServer validates `aud == "https://mcp.<SECRET_INTERNAL_DOMAIN>"` in every JWT.
Authentik does **not** set this by default. Add a **scope mapping** or **property mapping**:

Option A — Scope mapping (recommended):
- Admin UI → **Customisation → Scopes → Create Scope Mapping**
- **Name**: `ToolHive audience`; **Scope name**: `toolhive-audience`
- **Expression**:
  ```python
  return {"aud": ["https://mcp.wynning.tech"]}
  ```
- Add this scope to the ToolHive provider's **Selected scopes**.
- Hermes must request this scope when obtaining tokens.

Option B — Property mapping override on the provider:
- Set `Access token validity` and configure the access token to include the audience via
  the provider's **Advanced protocol settings → Additional scopes**.

### 4. Enable the Groups scope and property mapping

Ensure the provider includes the `groups` scope (so group names appear in the `groups` JWT
claim). The built-in `authentik-default-oauth2-access-token-groups` property mapping maps
the user's Authentik group names to the `groups` claim. Verify it is selected under
**Advanced protocol settings → Selected scopes**.

### 5. Create Authentik groups

Create these groups in Admin UI → **Directory → Groups**. Assign users:

| Group | User(s) |
|-------|---------|
| `toolhive-basic` | Zug |
| `toolhive-accountant` | Anton |
| `toolhive-secretary` | Jonathon |
| `toolhive-coach` | Carol |
| `toolhive-coder` | Hephaestus |
| `toolhive-home-ops` | Roberto |
| `toolhive-researcher` | Sagan |

### 6. Add per-persona Memini API keys to Bitwarden

The `toolhive-mcp` Bitwarden Secrets Manager item must include **seven** Memini API key
fields, one per persona. Each key is scoped to that persona's namespace in the Memini UI:

| Bitwarden key | Persona | MCPServerEntry |
|---------------|---------|----------------|
| `MEMINI_ZUG_API_KEY` | Zug | `memini-zug` |
| `MEMINI_ANTON_API_KEY` | Anton | `memini-anton` |
| `MEMINI_JONATHON_API_KEY` | Jonathon | `memini-jonathon` |
| `MEMINI_CAROL_API_KEY` | Carol | `memini-carol` |
| `MEMINI_HEPHAESTUS_API_KEY` | Hephaestus | `memini-hephaestus` |
| `MEMINI_ROBERTO_API_KEY` | Roberto | `memini-roberto` |
| `MEMINI_SAGAN_API_KEY` | Sagan | `memini-sagan` |

Value format: a plain Memini API key. The ExternalSecret template pre-formats it as
`Bearer <key>` and stores it under `MEMINI_<PERSONA>_AUTHORIZATION` — ToolHive reads
the formatted value directly for its `headerForward.addHeadersFromSecret` injection.

### 7. Add per-profile Forgejo PATs to Bitwarden

The `toolhive-mcp` Bitwarden Secrets Manager item must include **two** Forgejo PAT keys,
one per Forgejo service account (see issue #1561 for account creation):

| Bitwarden key | Forgejo account | Used by |
|---------------|----------------|---------|
| `HEPHAESTUS_FORGEJO_PAT` | `hephaestus` service account | `forgejo-hephaestus` MCPServer → `toolhive-coder` Cedar profile |
| `ROBERTO_FORGEJO_PAT` | `roberto` service account | `forgejo-roberto` MCPServer → `toolhive-home-ops` Cedar profile |

Value format: a plain Forgejo personal access token (the MCPServer passes it via
`FORGEJO_ACCESS_TOKEN` env var, which the `git.b4mad.industries/agentic-forges/forgejo-mcp` image handles).
Do **not** prefix with `token ` — that format was for the old `MCPServerEntry` header injection.

### 8. Add Nextcloud DAV service-account credentials to Bitwarden

The `toolhive-mcp` item must include **four** fields for the CalDAV/CardDAV backends —
one dedicated Nextcloud app password each, so either can be revoked independently:

| Bitwarden key | Used by |
|---------------|---------|
| `NEXTCLOUD_CALDAV_USERNAME` | `caldav` MCPServer |
| `NEXTCLOUD_CALDAV_APP_PASSWORD` | `caldav` MCPServer |
| `NEXTCLOUD_CARDDAV_USERNAME` | `carddav` MCPServer |
| `NEXTCLOUD_CARDDAV_APP_PASSWORD` | `carddav` MCPServer |

Value format: a plain Nextcloud app password (Settings → Security → Devices & sessions).
Both pods `CrashLoopBackOff` until these exist — the server requires them at startup in
`single_user_basic` mode. Nextcloud app passwords are **account-wide**; create a dedicated
service account and share only the intended calendars/address books with it. The full
least-privilege recipe is in [CALDAV-CARDDAV.md](CALDAV-CARDDAV.md#credentials).

ToolHive OIDC credentials (`client_id`, `client_secret`) must come from Authentik via
`externalsecret-oidc.yaml` (key `authentik-oauth`), **not** from the `toolhive-mcp`
Bitwarden item. Keep these two Bitwarden items separate and never mix them.

The ExternalSecret will pick up new keys on the next 15-minute refresh cycle.

---

## How Hermes profiles obtain tokens

Each Hermes profile is configured with an OAuth2 client that authenticates with Authentik
and requests an access token for the ToolHive resource server:

- **Flow**: Client Credentials (machine-to-machine) or Device Code (user-delegated)
- **Required scopes**: `openid groups toolhive-audience`
- **Token endpoint**: `https://auth.<domain>/application/o/toolhive/token/`

Hermes then presents the access token as `Authorization: Bearer <token>` on every MCP
request to `https://mcp.<SECRET_INTERNAL_DOMAIN>`.

---

## Cedar tool name verification

Cedar policies in `authzconfig.yaml` use tool names in the form `{backend}_{tool}`.
After Flux reconciles with the new MCPServers, verify exact names by running:

```bash
# Port-forward the VirtualMCPServer service (or use an in-cluster pod):
kubectl -n ai port-forward svc/vmcp-unified 4483:4483 &
# List all tools (replace the token with a valid JWT for any permitted group):
curl -s -H "Authorization: Bearer $TOKEN" \
  http://localhost:4483/tools/list | jq '.[].name'
```

Compare the output against the `resource == Tool::"..."` entries in `authzconfig.yaml`
and add any missing tools.

---

## Architecture notes

- **Single VirtualMCPServer**: all backends are in the `all` MCPGroup and visible in
  `tools/list` to any authenticated user regardless of group. Cedar enforces call-time
  authorization only; `tools/list` is not filtered per profile. This is a deliberate
  trade-off for operational simplicity. If `tools/list` privacy is required, migrate to
  per-profile VirtualMCPServers with separate MCPGroups and path-based routing.
- **Two Forgejo backends**: `forgejo-hephaestus` (authenticates as the `hephaestus` Forgejo
  service account) and `forgejo-roberto` (authenticates as the `roberto` service account)
  are separate MCPServer resources using `git.b4mad.industries/agentic-forges/forgejo-mcp:v2.34.1`. Each
  mounts a distinct PAT from the `toolhive-secrets` ExternalSecret (`HEPHAESTUS_FORGEJO_PAT`
  and `ROBERTO_FORGEJO_PAT`). ToolHive OIDC credentials are **not** passed through to
  Forgejo — the Forgejo PATs are static service-account tokens independent of the Authentik
  OIDC flow. Cedar permits are strictly scoped: `toolhive-coder` can only call
  `forgejo-hephaestus_*` tools, and `toolhive-home-ops` can only call `forgejo-roberto_*`
  tools. Neither profile can use the other's Forgejo session.
- **Read-only constraints**: Sagan/researcher is limited to Karakeep read tools
  (`get_bookmark`, `get_bookmark_content`, `get_lists`, `search_bookmarks`). Write tools
  (`create_bookmark`, `add_bookmark_to_list`, etc.) have no Cedar permit and are denied
  by default.
- **CalDAV/CardDAV backends**: one upstream image
  (`pi0n00r/nextcloud-mcp-server`, 164 tools) deployed twice as `caldav` and `carddav`.
  The split is load-bearing: the epic gives Carol/coach CardDAV without CalDAV, which
  needs two Cedar prefixes, and `--enable-app` means neither pod registers the other's
  tools even if a policy were mis-edited. Each carries its own Nextcloud app password.
  `carddav` exposes **no destructive tool** — contact and address-book deletion are
  excluded at `toolsFilter`, so that boundary holds for every profile rather than only
  for those without a permit. `caldav` exposes exactly one, `delete_event`. Calendar
  collection management, filter-matched bulk edits, and all VTODO/task tools are
  excluded. See [CALDAV-CARDDAV.md](CALDAV-CARDDAV.md).
- **Assigned backends**: `grafana`, `homeassistant`, `flux-operator`, `kubesearch`,
  `koffan`, `caldav`, `carddav`, and seven per-persona Memini backends now have Cedar
  permits. `caldav` and `carddav` are permitted for `toolhive-secretary` only.
  Each persona gets exactly its own Memini backend (`memini-zug_*` for Zug,
  `memini-anton_*` for Anton, etc.) — no persona can call another's Memini tools.
  `grafana` and `kubesearch` are permitted for `toolhive-coder` and `toolhive-home-ops`.
  `homeassistant` and `flux-operator` are permitted for `toolhive-home-ops` only.
  `koffan` is permitted for `toolhive-secretary` only (full read+write — a shopping-list
  secretary needs CRUD access). All other profiles cannot call these backends (deny-by-default).
- **Koffan adapter**: no upstream MCP server exists for Koffan. The adapter
  (`forge.wynning.tech/james/koffan-mcp`) is a custom FastMCP HTTP bridge wrapping the
  Koffan REST API. Its source lives in a separate repository and must be built and published
  before the `koffan` MCPServer pod starts. Until the image is available the pod is in
  ImagePullBackOff — Cedar continues to deny all `koffan_*` calls while the pod is absent,
  so no security gap opens. Once published, pin the image to a digest in `koffan.yaml`.
- **Per-persona Memini credentials**: each MCPServerEntry (`memini-zug`, `memini-anton`,
  `memini-jonathon`, `memini-carol`, `memini-hephaestus`, `memini-roberto`, `memini-sagan`)
  injects a static API key via `headerForward.addHeadersFromSecret`. The pre-formatted
  `Bearer <key>` value is stored in `toolhive-secrets` under `MEMINI_<PERSONA>_AUTHORIZATION`
  (e.g. `MEMINI_ZUG_AUTHORIZATION`), derived from the raw `MEMINI_<PERSONA>_API_KEY` field
  in the ExternalSecret template. Both raw key and formatted header are stored in the
  Kubernetes secret; only the `_AUTHORIZATION` variant is referenced by ToolHive.
  ToolHive does **not** pass the incoming OIDC token through to Memini — each backend uses
  its own static key scoped to its persona namespace in the Memini UI.

  | MCPServerEntry | Bitwarden field | Secret key (header) |
  |----------------|----------------|---------------------|
  | `memini-zug` | `MEMINI_ZUG_API_KEY` | `MEMINI_ZUG_AUTHORIZATION` |
  | `memini-anton` | `MEMINI_ANTON_API_KEY` | `MEMINI_ANTON_AUTHORIZATION` |
  | `memini-jonathon` | `MEMINI_JONATHON_API_KEY` | `MEMINI_JONATHON_AUTHORIZATION` |
  | `memini-carol` | `MEMINI_CAROL_API_KEY` | `MEMINI_CAROL_AUTHORIZATION` |
  | `memini-hephaestus` | `MEMINI_HEPHAESTUS_API_KEY` | `MEMINI_HEPHAESTUS_AUTHORIZATION` |
  | `memini-roberto` | `MEMINI_ROBERTO_API_KEY` | `MEMINI_ROBERTO_AUTHORIZATION` |
  | `memini-sagan` | `MEMINI_SAGAN_API_KEY` | `MEMINI_SAGAN_AUTHORIZATION` |

  All seven fields must exist in the `toolhive-mcp` Bitwarden Secrets Manager item.
  The ExternalSecret picks up new keys on the next 15-minute refresh cycle.
