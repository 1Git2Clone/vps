variable "name" {
  description = "Logical name for the firewall."
  type        = string
}

variable "server_ids" {
  description = "Servers the firewall applies to."
  type        = list(number)
}

variable "runner_ips" {
  description = <<-EOT
    The CI runners' public IPv4s as /32 CIDRs. Scopes the egress ssh rule to
    exactly those boxes rather than local.anywhere: this is the jump-host half
    of each runner's single inbound rule, so no runner has to open 22 to the
    internet. Empty produces no rule at all.
  EOT
  type        = list(string)
  default     = []
}
