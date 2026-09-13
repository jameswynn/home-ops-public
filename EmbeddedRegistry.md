# Spegel / Embedded Registry

Enable the embedded registry on the control plane nodes.

```sh
sudo vim /etc/systemd/system/k3s.service
```

```yaml
        '--embedded-registry' \
```

Setup registry mirrors on each node.

```sh
sudo vim /etc/rancher/k3s/registries.yaml
```

```yaml
mirrors:
  docker.io:
  registry.k8s.io:
  ghcr.io:
```

Reload k3s on each node.

```sh
sudo systemctl daemon-reload
sudo systemctl restart k3s.service
sudo systemctl restart k3s-agent.service
```

Test whether metrics work with:

```sh
kubectl get --raw /api/v1/nodes/<NODENAME>/proxy/metrics | grep -F 'spegel' | wc -l
```
