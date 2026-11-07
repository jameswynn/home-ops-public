# Spegel / Embedded Registry

Enable the embedded registry on the control plane nodes.

```sh
sudo vim /etc/systemd/system/k3s.service
```

```yaml
        '--embedded-registry' \
```

Registry mirrors (`/etc/rancher/k3s/registries.yaml`) are managed by ansible — don't edit them on the nodes:

```sh
task ansible:registries            # add `-- --check --diff` to preview
```

The playbook (`ansible/playbooks/registries.yaml`) renders a `"*"` mirror so Spegel serves every registry,
plus the zot pull-through cache (`https://zot.core.wynning.tech`) as the next endpoint for docker.io, ghcr.io,
quay.io and mirror.gcr.io. zot stores content under an upstream-host prefix, hence the per-mirror `rewrite`.
Mirror list lives in `ansible/inventory/group_vars/all/registry.yaml`; registry credentials in
`registry.sops.yaml` alongside it. Changed nodes get `k3s`/`k3s-agent` restarted one at a time (`serial: 1`),
waiting for the node to go Ready before moving on.

Test whether metrics work with:

```sh
kubectl get --raw /api/v1/nodes/<NODENAME>/proxy/metrics | grep -F 'spegel' | wc -l
```
