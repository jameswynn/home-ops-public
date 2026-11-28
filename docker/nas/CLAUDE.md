# docker/nas

One of two non-Flux, non-k8s deployments in this repo (the other is `docker/vps`): Docker Compose
stacks on the Synology NAS (`192.168.1.3`), deployed by [doco-cd](https://doco.cd) from the stack
dirs here. Garage S3 (backs Loki, postgres backups, renovate cache…) and the zot registry live here.

**`docker/nas/README.md` is the full reference** — host quirks, doco-cd mechanics, secrets model,
bootstrap, controller updates, and per-app incident notes (Garage metadata DB). Read it first; this
file only lists the rules that are easy to break.

## Access

- `ssh 192.168.1.3` works with key auth (user `wynnj`, passwordless sudo).
- Non-interactive shells need `source /etc/profile` before `docker`.
- doco-cd logs: `docker logs --since 10m doco-cd 2>&1 | grep -v "in progress"`.

## Rules

- **Renaming or deleting a stack dir destroys that stack** (`auto_discovery.delete`), and the
  Compose project is named after the dir. That's why these dirs are unnumbered, unlike `docker/vps`.
- **Never commit plaintext secrets.** Bootstrap creds go in `.doco-cd/secret.sops.env`; app
  secrets go in Bitwarden and are mapped by UUID in `.doco-cd.yaml`.
- **Verify every new Bitwarden UUID before pushing** (README → Secrets). One unreadable UUID
  fails *every* stack.
- **Never print secret values** when debugging; print names or lengths.
- Reference injected secrets explicitly in compose (`FOO: ${APP_FOO}`); don't use `env_file`
  for them, and don't hardcode a key in `environment:` that `.env` also sets.
- Don't rename the doco-cd Compose project/container (`doco-cd`).
- doco-cd here is pinned to **0.121.0** (Docker 24 / API 1.43). Don't bump it without testing.
- Every service must become healthy within doco-cd's 3-minute wait. Override image
  healthchecks with long intervals; Docker 24 has no `start_interval`.
- Don't publish host ports 5000/5001 (DSM).
- Relative bind mounts resolve into read-only per-commit artifacts: never store app data there.
  Persistent data goes under `/volume1/docker/<app>/`, created on the NAS first.
- `docker compose -f FILE` goes before the subcommand.
- Compose here is v2.20: no `configs.content`. To turn secrets into files, use a one-shot init
  container (see `zot`).

## Verifying a change

1. Merge to `main`; doco-cd deploys on its next 180s poll.
2. Watch doco-cd logs for `deploying stack` / `deployment failed`.
3. Check `docker ps -a --filter label=com.docker.compose.project=<app>` and exercise the service
   itself (HTTP status, `garage status`, a pull through zot).
