# components/anubis

Anubis anti-scraper proxy placed in front of a service. Pulled in as a component with
`APP`, `APP_NAMESPACE`, `ANUBIS_TARGET` (and optional `ANUBIS_DIFFICULTY`, `ANUBIS_MEM_LIMIT`,
`ANUBIS_REDIRECT_DOMAINS`) substitutes.

`ANUBIS_REDIRECT_DOMAINS` defaults to the root domain plus a `*.` glob of it. Anubis matches these
exactly, so an app served on a hostname outside the root domain (e.g. `blog.jameswynn.com`) must
override it or the post-challenge redirect is refused.

Unlike most components, this one is **not fully declarative from the `ks.yaml`** — the consuming app must
also hand-edit three things: the HTTPRoute (`route:` → point at the `<app>-anubis` backend on port 8080),
and a netpol egress rule to reach the anubis dragonfly on 6379.

See **`components/anubis/readme.md`** for the exact route + netpol snippets to paste.
