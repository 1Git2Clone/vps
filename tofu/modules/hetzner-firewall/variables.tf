variable "name" {
  description = "Logical name for the firewall."
  type        = string
}

variable "server_ids" {
  description = "Servers the firewall applies to."
  type        = list(number)
}
