resource "routeros_system_user_group" "this" {
  for_each = local.user_groups

  name   = each.key
  policy = each.value.policies
}

resource "routeros_system_user" "this" {
  for_each = local.users

  name    = each.key
  group   = each.value.group
  address = each.value.address
  comment = try(each.value.comment, null)

  depends_on = [routeros_system_user_group.this]

  lifecycle {
    # Passwords are held in Bitwarden and set out of band. Managing them here
    # would put credentials in state and risk rotating the one this module
    # authenticates with.
    ignore_changes = [password]
  }
}

# Public half only; the private key is the mikrotik-backup-secret SOPS file in
# core/networking/mikrotik-backup. Rotating it means replacing both together.
resource "routeros_system_user_sshkeys" "backup" {
  user    = routeros_system_user.this["backup"].name
  key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIITVDY8ZnTxZ2esx9UMY//xGCeONOMuOUVurrWPr719v mikrotik-backup@k8s (#2322)"
  comment = "config backup CronJob (#2322)"
}
