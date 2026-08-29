variable "zone_id" {
  description = "Cloudflare zone ID."
  type        = string
}

variable "domain" {
  description = "Apex domain."
  type        = string
}

variable "vps_ip" {
  description = "Public IPv4 of the VPS. Also hard-coded into the SPF record."
  type        = string
}

variable "subdomains" {
  description = <<-EOT
    Subdomains that resolve straight to the VPS. Unproxied on purpose: caddy
    terminates TLS with a real certificate and cloudflared, although connected,
    routes none of this.
  EOT
  type        = set(string)
  default     = ["mail", "git", "minecraft", "music", "status", "smtp"]
}

variable "dkim_cloudflare_key" {
  description = "DKIM public key for the cf2024-1 selector."
  type        = string
}

variable "dkim_default_key" {
  description = "DKIM public key for the default selector."
  type        = string
}

variable "dmarc_rua" {
  description = "DMARC aggregate-report address."
  type        = string
}
