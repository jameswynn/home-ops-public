# mikrotik-backup

Nightly off-device backup of the MikroTik hEX S (#2322): `/export show-sensitive` →
`crypt:<YYYY-MM-DD>/router.rsc` in the `mikrotik-backup` bucket on `garage-nas`,
encrypted (names and contents) with rclone `crypt` before upload. 30 nights are kept.

The router user `backup` is SSH-key only, node-subnet only, and holds just
`read,ssh,sensitive` (`tofu/mikrotik/locals.tf`).

## What the export does and does not cover

The export is the whole configuration, secrets included, and imports onto a reset
router of any model (`/import file-name=router.rsc`). It does **not** carry:

- **user passwords** — re-set them; the tofu-managed users' passwords are in Bitwarden,
  `mktxp` is in `core/monitoring/mktxp/app/secret.sops.yaml`, `backup` is key-only
- **certificate private keys** — re-create `api-ssl` (see `tofu/mikrotik/services.tf`)
  and re-import the LE cert (#459)

## Binary backups are manual

`/system backup save` needs the `policy` permission, which can edit users, so the
nightly job does not take one. Before risky changes (e.g. RouterOS upgrades, #1786),
take one with your own admin account and keep it off the router:

```bash
name=manual-$(date +%F)
ssh admin@192.168.1.1 "/system backup save name=$name password=<pick one>"
scp "admin@192.168.1.1:$name.backup" .
ssh admin@192.168.1.1 "/file remove $name.backup"
```

It restores only onto the same model with a similar RouterOS version.

## Restore an export to your workstation

```bash
sops -d core/networking/mikrotik-backup/app/secret.sops.yaml > /tmp/mb.yaml
export RCLONE_CONFIG_CRYPT_TYPE=crypt RCLONE_CONFIG_CRYPT_REMOTE=garage:mikrotik-backup
export RCLONE_CONFIG_CRYPT_PASSWORD=$(yq '.stringData.CRYPT_PASSWORD' /tmp/mb.yaml)
export RCLONE_CONFIG_CRYPT_PASSWORD2=$(yq '.stringData.CRYPT_PASSWORD2' /tmp/mb.yaml)
rm /tmp/mb.yaml
kubectl -n default port-forward svc/garage-nas 3900 &
eval "$(kubectl -n networking get secret mikrotik-backup -o json | jq -r '.data
  | "export RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID=\(."access-key-id"|@base64d)
     export RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY=\(."secret-access-key"|@base64d)"')"
export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
  RCLONE_CONFIG_GARAGE_FORCE_PATH_STYLE=true RCLONE_CONFIG_GARAGE_REGION=garage \
  RCLONE_CONFIG_GARAGE_ENDPOINT=http://localhost:3900
rclone lsf crypt:
rclone copy crypt:2026-11-04 ./router-restore
```

Run a backup now: `kubectl -n networking create job --from=cronjob/mikrotik-backup mikrotik-backup-manual`.

## Rotating the SSH key

Generate a new ed25519 pair, put the public half in `routeros_system_user_sshkeys.backup`
(`tofu/mikrotik/users.tf`) and the private half in `app/secret.sops.yaml`, then apply both.
If the router's host key changes, refresh `app/config/known_hosts`.
