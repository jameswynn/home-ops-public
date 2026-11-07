# Nextcloud Troubleshooting

## CronJob

Nextcloud was never intended to run in kubernetes and is poorly architected for it.

The easiest way to run the cron job is via kubectl, so I created a custom cronjob with service account. Unfortunately
Nextcloud container must be run as root because of how it binds to ports and uses files, which means commands
executed in it's shell are also run as root. The `occ` command requires the executor to have the same uid
as the owner of config.php. The work around is to change the owner of config.php to root, and set the suid bit on
occ.

```sh
chmod u+s occ
chown root:www-data config/config.php
chmod g+w config/config.php
```

## Upgrading

Because Nextcloud upgrades take a while it is best to not do this automatically.

1. suspend the helmrelease

    ```sh
    flux suspend hr -n office nextcloud2
    ```

2. scale the deployment down to 1

    ```sh
    kubectl scale deployment -n office nextcloud2 --replicas 1
    ```

3. disable the probes -- only a StartupProbe now
4. disable the cronjob -- its a sidecar now
5. update the version manually -- be editing the deployment image tag
6. wait 5+ minutes - it will only state that it is "upgrading"
7. update the yamls with the new version, and push it
8. wait for recon
9. resume the helmrelease
10. verify everything still works
11. enable the cronjob

## Performing maintenance inside the container

```sh
su -ps /bin/bash www-data

occ upgrade
```
