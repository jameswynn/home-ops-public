# Remote state in the `tofu-state` bucket on the NAS Garage (see
# apps/default/garage/nas/tofu-state.yaml, PR #1528).
#
# The endpoint is the Garage on the Synology, not the in-cluster `garage-nas`
# gateway: that gateway has no S3 route out of the cluster (its only
# LoadBalancer port is 3901/RPC), and tofu runs from a workstation. Same
# storage either way -- the gateway proxies to this host. Note that the Secret
# the operator mints carries the in-cluster service name in its `endpoint`
# field, which is right for cnpg/loki/tempo and wrong here; take only
# `access-key-id` and `secret-access-key` from it.
#
# `use_lockfile` is the native S3 lock object; no DynamoDB. Garage's `write`
# permission covers the DeleteObject it needs on release, which is why the
# GarageKey grants read+write and not just read.
#
# The skip_* flags are all AWS-isms Garage does not implement: no STS, no IMDS,
# no account IDs, and `garage` is not a real AWS region.
terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "mikrotik/terraform.tfstate"
    region = "garage"

    endpoints = {
      s3 = "https://s3.core.wynning.tech"
    }

    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
  }

  # TLS protects the hop; this protects the object. State holds the RouterOS
  # password and the WireGuard server private key, and without this block they
  # would sit readable in a bucket that several other workloads' credentials
  # can also reach. Encrypting the payload means Garage only ever stores
  # ciphertext, so the blast radius of a leaked bucket key is nothing.
  #
  # The key_provider block is deliberately absent: it arrives as TF_ENCRYPTION
  # from `bws run` (see mod.just), so no passphrase is written to the repo. If
  # it is missing, tofu fails with "There is no key_provider ... declared"
  # rather than silently falling back to writing plaintext state -- the same
  # fail-loud property as var.wireguard_private_key's precondition.
  encryption {
    method "aes_gcm" "this" {
      keys = key_provider.pbkdf2.this
    }

    # If you ever need to migrate plaintext state in again, a temporary
    # `method "unencrypted"` + `fallback` is the way -- see BOOTSTRAP.md
    # Wave 7. Take it back out the moment the migration succeeds; tofu warns
    # while it is present, and left in place it would silently accept an
    # unencrypted state file forever.
    state {
      method = method.aes_gcm.this
    }

    plan {
      method = method.aes_gcm.this
    }
  }
}
