# docker/vps

The **only** non-Flux, non-k8s deployment in this repo: Docker Compose stacks on the public VPS, deployed
by [doco-cd](https://doco.cd). Hosts the self-hosted **towonel** tunnel hub replacing Cloudflare Tunnel as
public ingress for `wynning.tech` (see [[towonel_migration]]).

Adding a stack = a new `NN-name/` dir with a `docker-compose.yaml`; doco-cd auto-discovers it. Secrets come
from Bitwarden Secrets Manager via `.doco-cd.yaml`; bootstrap creds are committed SOPS-encrypted as
`.doco-cd/secret.sops.env`.

**`docker/vps/README.md`** is the full reference — bootstrap steps, doco-cd mechanics, the CrowdSec host
setup, and the compose-file conventions (schema header, tag pinning, `---` prefix). Read it before touching
anything here.
