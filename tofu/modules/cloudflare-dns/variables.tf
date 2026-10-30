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
  # "minecraft", "mc" and "mc2" to "mc4" are all the same address on 25565. mc-router
  # tells the worlds apart by the hostname in the client's handshake (see
  # modules/containers/minecraft.nix in the NixOS config), so a world needs
  # only its A record here, no SRV and no port of its own.
  default = ["mail", "git", "minecraft", "mc", "mc2", "mc3", "mc4", "horizon", "status", "smtp", "pages", "crafts", "compress", "docs"]
}

variable "tailnet_ipv4" {
  description = <<-EOT
    This box's tailscale address, e.g. "100.109.115.12". The tailnet-only
    subdomains below become plain A records pointing at it.

    A CGNAT address in public DNS looks alarming and is not: 100.64.0.0/10 is
    unroutable on the internet, so the record is a dead end for anyone off the
    tailnet, and four further layers sit behind it (see the handbook's
    "Network and trust boundaries").

    A RECORDS RATHER THAN A CNAME to the node's MagicDNS name, which was the
    first design here. Tailscale does NOT publish <node>.<tailnet>.ts.net in
    public DNS — verified 2026-09-17, empty answers from 1.1.1.1, 9.9.9.9 and
    8.8.8.8 — it resolves only through the tailnet's own split-DNS route. A
    CNAME would therefore work on a device with MagicDNS active and fail
    silently on one without it, which is a worse failure than the one below.

    The cost, stated plainly: this is a literal, and replacing the machine
    gives it a new tailnet address that this value will not follow. That is
    the trap modules/containers/tempo.nix documents. It is accepted here
    because the failure is loud and local — the names stop resolving to the
    box — and the fix is this one variable.

    Empty disables the records entirely.
  EOT
  type        = string
  default     = ""
}

variable "tailnet_subdomains" {
  description = <<-EOT
    Subdomains served over the tailnet ALONE. Deliberately not in
    `var.subdomains`: caddy answers these on a second listener that neither
    firewall exposes, so a public A record would not merely be useless, it would
    hand the internet a name that connects and then hangs.

    Must agree with the tailnet sites in modules/containers/caddy.nix and with
    infra.certSubdomains — the certificate covers them, and DNS-01 needs no
    record of their own to issue it.
  EOT
  type        = set(string)
  default     = ["dozzle", "grafana", "music", "search", "syncthing"]
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

variable "bsky_record" {
  type = string
}

variable "caa_iodef" {
  description = <<-EOT
    Address a CA reports a REFUSED issuance to, through the CAA iodef record.
    It is the only way these records ever tell you someone tried.

    Defaults to infra.acmeEmail from modules/options.nix — the same person
    already gets Let's Encrypt expiry mail, and a refused issuance is the same
    kind of news. Bare address; the mailto: is added.
  EOT
  type        = string
  default     = "ivan@hu-tao.dev"
}
