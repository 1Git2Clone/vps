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
  # "mc" is an alias for "minecraft": same A record, same address. Minecraft
  # needs nothing more, because the server is on the default 25565 and clients
  # connect with a bare hostname.
  #
  # "mc2" is the SECOND world, which is on 25566 and therefore does need more:
  # Minecraft — unlike ssh — DOES read SRV records (_minecraft._tcp.<host>),
  # which is the supported way to hide a port from players. See the SRV record
  # in main.tf. That is exactly the trick forgejo could not use, which is why it
  # owns port 22 and this host's sshd sits on 2222.
  #
  # The A record for mc2 is still required: an SRV target has to resolve.
  default = ["mail", "git", "minecraft", "mc", "mc2", "music", "status", "smtp", "search", "pages"]
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
