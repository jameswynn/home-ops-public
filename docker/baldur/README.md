# docker/baldur

Docker Compose stacks on **baldur**, a LAN desktop (Bazzite-DX / Fedora Kinoite, Docker CE).
Unlike [`docker/vps`](../vps/README.md) and [`docker/nas`](../nas/README.md) there is no
doco-cd here: stacks are started and updated by hand.

## The host

| | |
| --- | --- |
| LAN address | `10.10.2.244` (`br0`, MTU 1500) |
| Docker | Docker CE from the Bazzite-DX image, socket-activated (`docker.socket`) |
| Other load | Also runs the LLM server LiteLLM reaches as `baldur/*`; keep CI memory bounded |

`forge.wynning.tech` and other `*.wynning.tech` names resolve to `envoy-internal`
(`10.11.0.223`) over `br0`, so the VPS hairpin and MTU workarounds do not apply.

## Stacks

| Path | What |
| --- | --- |
| `runner/` | Forgejo Actions runner (`baldur`), capacity 2, dind capped at 6 GB. Labels `ubuntu-latest`, `default`, `docker`, `baldur`. |

## Prerequisites

1. Docker access for your user: `ujust dx-group`, then log out and back in
   (`id -nG` must list `docker`).
2. `sudo systemctl enable --now docker.socket`

## Runner: first start

1. In Forgejo, create a runner (Site administration → Actions → Runners → Create new runner,
   or the user/repo equivalent). Copy the **UUID** and **token**; they are shown once.
2. Write them next to the compose file (gitignored):

   ```sh
   cd docker/baldur/runner
   (umask 077 && cat > .env <<'EOF'
   FORGEJO_RUNNER_UUID=<uuid>
   FORGEJO_RUNNER_TOKEN=<token>
   EOF
   )
   docker compose up -d
   docker logs -f forgejo-runner   # expect "declared successfully" with the labels above
   ```

## Runner: updates

Renovate bumps the images in `runner/docker-compose.yaml`. Job containers run *inside*
`forgejo-runner-dind`, so recreating it kills whatever is running there. Drain first:

```sh
git pull --ff-only
cd docker/baldur/runner
# 1. Stop the runner. It takes no new jobs and waits for the running one, but only up to
#    shutdown_timeout (30m); a job still running after that is cancelled.
docker compose stop forgejo-runner
# 2. Confirm no job containers are left in dind (must print nothing). dockerd there only
#    listens on tcp, hence -H.
docker exec forgejo-runner-dind docker -H tcp://127.0.0.1:2375 ps -q --filter name=FORGEJO-ACTIONS-TASK
# 3. Update and start everything.
docker compose pull && docker compose up -d
```

If a long job matters, wait for it to finish in Forgejo before step 1.
