variable "hcloud_token" {
  description = "Hetzner Cloud API token. Null falls back to $HCLOUD_TOKEN."
  type        = string
  default     = null
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token, scoped Zone:Read + DNS:Edit."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for var.domain."
  type        = string
}

variable "domain" {
  description = "Apex domain. Must agree with infra.domain in modules/options.nix."
  type        = string
  default     = "hu-tao.dev"
}

variable "server_name" {
  description = "Hetzner Cloud server name."
  type        = string
  default     = "hu-tao"
}

variable "server_type" {
  description = "Hetzner Cloud server type. cx22 is 2 vCPU / 4 GB."
  type        = string
  default     = "cx22"
}

variable "location" {
  description = <<-EOT
    Hetzner Cloud location. MUST match the location of hcloud_primary_ip.main:
    primary IPs are location-bound, so an fsn1 address cannot be attached to a
    server anywhere else. This is what makes the mail IP handover possible at
    all — both boxes are in fsn1, so 167.233.24.58 and its smtp.hu-tao.dev PTR
    can move between them without DNS, SPF or reputation changing.
  EOT
  type        = string
  default     = "fsn1"
}

variable "bootstrap_image" {
  description = <<-EOT
    Image the server first boots, purely so nixos-anywhere has something to ssh
    into. It kexecs into the NixOS installer and repartitions the disk, so
    nothing from this image survives — it only has to boot and accept the key.
  EOT
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_public_key" {
  description = "Public key injected at server creation, used by nixos-anywhere to install."
  type        = string
}

variable "legacy_server_ids" {
  description = <<-EOT
    Servers that share the edge firewall but are NOT managed here — during the
    CX33 -> CX43 migration this is the old box.

    Load-bearing: hcloud_firewall_attachment is authoritative over the whole
    applied_to list, so leaving the old server out of it does not "not manage"
    it, it DETACHES the firewall from a live mail server. Empty this only once
    the old box is retired.
  EOT
  type        = list(number)
  default     = [137766340]
}

variable "dkim_cloudflare_key" {
  description = "DKIM public key for the cf2024-1 selector (Cloudflare Email Security)."
  type        = string
}

variable "dkim_default_key" {
  description = <<-EOT
    DKIM public key for the `default` selector. Its PRIVATE half lives in
    secrets.yaml as email/dkim_private_key and is mounted into DMS. The two must
    be halves of the same key or every recipient fails the signature.
  EOT
  type        = string
}

variable "dmarc_rua" {
  description = "DMARC aggregate-report address."
  type        = string
  default     = "mailto:ae711fd0810a4ba289bb16ca5458799d@dmarc-reports.cloudflare.net"
}
