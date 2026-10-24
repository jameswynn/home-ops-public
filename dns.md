# Resilient DNS

- Mikrotik router hosts all local DNS
    - External DNS with Mikrotik provider to sync all internal DNS, and override external DNS
- AdGuard Primary deployed on cluster
    - 192.168.1.5 - adguard1.${SECRET_INTERNAL_DOMAIN}:80/53
    - adguard-primary.${SECRET_INTERNAL_DOMAIN}:443
- AdGuard Secondary on cluster
    - 192.168.1.6 - adguard2.${SECRET_INTERNAL_DOMAIN}:80/53
    - adguard-secondary.${SECRET_INTERNAL_DOMAIN}:443
- Use router as reverse DNS in AdGuard
- AdGuard synced from Primary to Secondary
