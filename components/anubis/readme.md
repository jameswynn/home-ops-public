Add to the application's `ks.yaml`:

```yaml
  components:
    - ../../../components/anubis
  postBuild:
    substitute:
      APP: *app
      APP_NAMESPACE: *namespace
      # this will be the url to the target service
      ANUBIS_TARGET: http://plausible:8000
```

Then point the route at the `<app>-anubis` backend on port 8080. How you do that depends on which
chart owns the route.

## bjw-s app-template charts

The chart renders the route from values, so add to the `helmrelease.yaml`:

```yaml
    route:
      plausible:
        parentRefs:
          - name: envoy-towonel
            namespace: networking
        rules:
          # This rule will redirect traffic to anubis
          - backendRefs:
              - name: plausible-anubis
                port: 8080
```

## Charts that render their own HTTPRoute

Some upstream charts (Forgejo, for one) expose only `hostnames`/`parentRefs` and give you no way to
set `backendRefs`, so the values above have nowhere to go. Turn the chart's route off:

```yaml
    httpRoute:
      enabled: false
```

and write a standalone `httproute.yaml` instead. Carry over any annotations the chart was setting —
`external-dns` and `gethomepage` in particular, since dropping them silently removes the DNS record
and the dashboard tile:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  # Not the same name as the chart's route: the chart owns that name until the
  # httpRoute.enabled=false upgrade lands, and reusing it is a server-side-apply
  # ownership conflict. Distinct names also make the cutover graceful, since
  # Gateway API resolves same-hostname conflicts oldest-first.
  name: forgejo-public
  annotations:
    external-dns.alpha.kubernetes.io/hostname: "forge.${SECRET_ROOT_DOMAIN}"
spec:
  parentRefs:
    - name: envoy-towonel
      namespace: networking
  hostnames:
    - "forge.${SECRET_ROOT_DOMAIN}"
  rules:
    - backendRefs:
        - name: forgejo-anubis
          port: 8080
      # Give git pushes room; the default is too short.
      timeouts:
        request: 300s
```

The app is briefly unreachable during this cutover: helm-controller deletes the chart's route as
soon as the upgrade lands, while the anubis HelmRelease is still installing. It self-heals within a
minute. See `apps/dev/forgejo/app/httproute.yaml` for a live example.

No `X-Real-Ip` filter is needed on the route — the `ClientTrafficPolicy` on both gateways already
sets it from the downstream address, which is what lets anubis tell clients apart.

## Netpols

If the app has a `netpols.yaml`, add an egress rule so anubis can reach its dragonfly:

```yaml
  egress:
    # Allow anubis dragonfly instance
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": anubis
            app: anubis-dragonfly
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
```
