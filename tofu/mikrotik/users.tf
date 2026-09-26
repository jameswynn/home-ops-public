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

  depends_on = [routeros_system_user_group.this]

  lifecycle {
    # Passwords are held in Bitwarden and set out of band. Managing them here
    # would put credentials in state and risk rotating the one this module
    # authenticates with.
    ignore_changes = [password]
  }
}
