# docker/vps

One of two non-Flux, non-k8s deployments in this repo (the other is `docker/nas`): Docker Compose stacks on the public VPS, deployed
by [doco-cd](https://doco.cd). Hosts the self-hosted **towonel** tunnel hub replacing Cloudflare Tunnel as
public ingress for `wynning.tech` (see [[towonel_migration]]).

Adding a stack = a new `NN-name/` dir with a `docker-compose.yaml`; doco-cd auto-discovers it. Secrets come
from Bitwarden Secrets Manager via `.doco-cd.yaml`; bootstrap creds are committed SOPS-encrypted as
`.doco-cd/secret.sops.env`. doco-cd never redeploys itself; `.forgejo/workflows/deploy-doco-cd-vps.yaml`
does, running `docker/update-doco-cd.sh vps` on the VPS over SSH whenever `.doco-cd/**` changes on `main`.

**`docker/vps/README.md`** is the full reference — bootstrap steps, doco-cd mechanics, the CrowdSec host
setup, and the compose-file conventions (schema header, tag pinning, `---` prefix). Read it before touching
anything here.
