# Wave 11 — system logging. No data path: these resources decide where log
# lines go, and nothing routes, filters or resolves through them.
#
# Everything here was imported as found, including the four entries RouterOS
# flags `default: true`. They are real config that a future change could touch,
# and importing them is what makes such a change show up in a plan.

resource "routeros_system_logging_action" "this" {
  for_each = local.logging_actions

  name   = each.key
  target = each.value.target

  # Target-specific attributes. Each action type uses a disjoint set, so they
  # are held as one map per action rather than as a wide schema of nulls.
  memory_lines        = try(each.value.attrs.memory_lines, null)
  memory_stop_on_full = try(each.value.attrs.memory_stop_on_full, null)

  disk_file_name      = try(each.value.attrs.disk_file_name, null)
  disk_file_count     = try(each.value.attrs.disk_file_count, null)
  disk_lines_per_file = try(each.value.attrs.disk_lines_per_file, null)
  disk_stop_on_full   = try(each.value.attrs.disk_stop_on_full, null)

  remember = try(each.value.attrs.remember, null)

  remote             = try(each.value.attrs.remote, null)
  remote_port        = try(each.value.attrs.remote_port, null)
  remote_protocol    = try(each.value.attrs.remote_protocol, null)
  remote_log_format  = try(each.value.attrs.remote_log_format, null)
  src_address        = try(each.value.attrs.src_address, null)
  syslog_facility    = try(each.value.attrs.syslog_facility, null)
  syslog_severity    = try(each.value.attrs.syslog_severity, null)
  syslog_time_format = try(each.value.attrs.syslog_time_format, null)
  vrf                = try(each.value.attrs.vrf, null)
}

resource "routeros_system_logging" "this" {
  for_each = local.logging_rules

  topics = each.value.topics
  action = each.value.action

  prefix   = try(each.value.prefix, null)
  disabled = try(each.value.disabled, null)

  depends_on = [routeros_system_logging_action.this]
}
