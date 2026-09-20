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
  description = <<-EOT
    Server name as it exists in the Hetzner console. Purely a label; it is NOT
    networking.hostName and NOT the tailnet node name. Kept equal to the live
    value so a plan never proposes a cosmetic rename — config describes what is
    there, it does not nag about naming.
  EOT
  type        = string
  default     = "nixos-16gb-fsn1-1"
}

variable "primary_ip_name" {
  description = <<-EOT
    Label on the primary IP. Defaults to the name Hetzner generated when it was
    created; renaming it would be churn for no behavioural change, and this
    address is the one carrying the mail reputation and PTR — the last thing
    worth touching for aesthetics.
  EOT
  type        = string
  default     = "primary_ip-134632948"
}

variable "primary_ip_v6_name" {
  description = "Label on the IPv6 primary IP, matching what Hetzner generated."
  type        = string
  default     = "primary_ip-147045245"
}

variable "ssh_key_name" {
  description = "Label on the install ssh key, matching what is in the account."
  type        = string
  default     = "hutao@laptop"
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

    EMPTY NOW. The CX33 (137766340) was deleted after the migration settled —
    `GET /v1/servers/137766340` is a 404 — and an id in this list is not
    inert once the server is gone: the attachment sends the whole applied_to
    list to the API, so a dead id fails the apply rather than being ignored.
  EOT
  type        = list(number)
  default     = []
}

variable "vps_is_tagged" {
  description = <<-EOT
    Whether the VPS already carries tag:vps. Gates the two deny assertions in
    the tailnet policy's tests block, and exists to break a genuine deadlock.

    THE DEADLOCK. The policy cannot be applied while the VPS is untagged,
    because `autogroup:self:*` still covers it on every port and the deny tests
    say otherwise. And the VPS cannot be tagged while the policy is unapplied,
    because Tailscale refuses to assign a tag that no tagOwners entry defines —
    tag:vps is defined only in the policy waiting to be applied. Neither the
    console nor tailscale_device_tags gets around that; it is the API's rule,
    not a tooling limit.

    So the bootstrap is three steps, once in the life of the tailnet:

      1. tofu apply -var vps_is_tagged=false
         Publishes tagOwners and the tag:vps rules. Changes no access: nothing
         carries the tag yet, so the VPS is still reached through the
         autogroup:self rule exactly as before.
      2. Machines -> vps -> Edit ACL tags -> tag:vps. Now offered, because
         step 1 defined it.
      3. tofu apply
         The deny assertions come back and now hold. This is the apply that
         actually narrows anything.

    Default true, so the un-narrowed policy is never what you get by accident —
    reaching for the weaker one has to be deliberate and visible in the command.
  EOT
  type        = bool
  default     = true
}

variable "tailnet_ipv4" {
  description = <<-EOT
    This box's tailscale address, from `tailscale status`. dozzle, grafana and
    syncthing become A records pointing at it — resolvable by anything,
    reachable only from the tailnet. Empty creates no records.

    ALSO THE `vps` HOST IN THE TAILNET POLICY FILE, which is why the validation
    below arrived alongside tofu/tailscale.tf. Empty is a legitimate answer for
    the DNS records — it simply makes none — and is NOT one for the policy: it
    would render `"vps": ""` and turn every rule keyed on that host into a rule
    about nothing. Silent, and in the permissive direction.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.tailnet_ipv4 == "" || can(cidrhost("${var.tailnet_ipv4}/32", 0))
    error_message = "tailnet_ipv4 must be a bare IPv4 address (from `tailscale status`), or empty."
  }
}

variable "tailscale_oauth_client_id" {
  description = <<-EOT
    OAuth client id for the tailnet policy file (tofu/tailscale.tf).

    Created once at admin console -> Settings -> OAuth clients, with the single
    scope `acl` (write). Nothing else: this client rewrites the policy file and
    has no business enumerating devices or minting auth keys.

    NOT marked sensitive, unlike its secret. A client id is an identifier that
    authenticates nothing on its own, and hiding it would only redact it out of
    the plan output, which is the one place it is useful for telling two clients
    apart.

    REQUIRED once tofu/tailscale.tf exists: one state means one provider set, so
    a plan for an unrelated DNS change fails without it.
  EOT
  type        = string
}

variable "tailscale_oauth_client_secret" {
  description = <<-EOT
    The secret half of tailscale_oauth_client_id. Shown exactly once when the
    client is created; if it is lost the client is regenerated rather than
    recovered.
  EOT
  type        = string
  sensitive   = true
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

variable "bsky_record" {
  type        = string
  description = "Bluesky AT Protocol DID."
}

variable "runner_names" {
  description = <<-EOT
    The CI runners, by Hetzner server name. One box per entry; every entry needs
    a matching key in var.runner_identities.

    A LIST rather than a single name because the runners are meant to be
    interchangeable. Nothing in `modules/runner/` is per-box: the same closure
    boots on every one of them and each learns its own identity from its own
    user_data, so a second runner is an entry here plus its pair in
    runner_identities -- no flake change, no deploy, no commit.

    Deliberately SEPARATE from runner_identities rather than one map of
    name => identity: OpenTofu refuses to use a sensitive value as a `for_each`
    argument, and marking a map sensitive marks its keys too. Splitting keeps
    the keys usable for iteration and the secrets marked.

    The name here is cosmetic in Forgejo. A runner's display name in Site
    Administration -> Actions -> Runners comes from networking.hostName, baked
    into the shared image, and Forgejo tells runners apart by the uuid in
    `server.connections` regardless. Keep the first entry equal to the live
    server name so a plan never proposes a cosmetic rename.
  EOT
  type        = list(string)
  default     = ["forgejo-runner"]

  validation {
    condition     = length(var.runner_names) == length(toset(var.runner_names))
    error_message = "runner_names must be unique: each entry is one hcloud server."
  }

  validation {
    condition     = toset(var.runner_names) == toset(keys(var.runner_ipv4s))
    error_message = "runner_names and runner_ipv4s must cover exactly the same server names -- a runner with no address is unreachable over the jump, and an address with no runner is a stale hole in the VPS egress allow-list."
  }
}

variable "runner_identities" {
  description = <<-EOT
    Each runner's Forgejo identity, keyed by the same name used in
    runner_names, as the single line

        forgejo-runner: <uuid> <secret>

    Created by hand at Site Administration -> Actions -> Runners -> Create new
    runner, which shows the uuid and the secret together exactly once. A record
    is server-side state with no tie to any machine and is NOT a registration
    token -- not one-shot, and it does not expire from non-use -- so replacing
    or reinstalling a box reuses the same pair. Only deleting the record
    invalidates it, and that invalidates both halves at once.

    `forgejo-runner:` there is a KEY, not a name: modules/runner/identity.nix
    searches the user-data body for a line starting with it, so the blob may
    hold other things (a #cloud-config document, other keys) in any order.

    CHANGING AN ENTRY REPLACES THAT BOX. hcloud has no way to set user_data on
    an existing server, so the provider marks the attribute
    replace-forces-new. That is acceptable here and nowhere else in this
    config: a runner holds a nix store and an Actions cache, both caches by
    definition. Note the box's public IPv4 changes with it -- see
    var.runner_ipv4s for the two places that pin it.
  EOT
  type        = map(string)
  sensitive   = true

  validation {
    condition     = alltrue([for v in values(var.runner_identities) : can(regex("^forgejo-runner: [0-9a-fA-F-]{36} [A-Za-z0-9]{32,}$", v))])
    error_message = "Each identity must be exactly 'forgejo-runner: <uuid> <secret>' -- a 36-char uuid then 32+ alphanumerics. modules/runner/identity.nix refuses anything else at boot, which is a much slower way to find a typo."
  }

  validation {
    condition     = length(setsubtract(toset(var.runner_names), toset(keys(var.runner_identities)))) == 0
    error_message = "Every name in runner_names needs an entry in runner_identities."
  }
}

variable "runner_server_type" {
  description = <<-EOT
    Server type for the CI runner. cx33 is 4 vCPU / 8 GB / 80 GB.

    Kept equal to the LIVE type on purpose. A rescale done in the console is a
    change tofu can see — leaving this at the old value does not mean "not
    managed", it means the next apply proposes shrinking the box, and Hetzner
    cannot shrink a disk, so that plan either fails or destroys data depending
    on how it is answered. Rescale, then change this line.

    Sizing, measured rather than guessed: the two CI eval steps peak at 668 MB
    and 732 MB RSS, so memory was never the binding constraint at cx23 either —
    disk was, and 40 GB of it. What the extra cores actually buy is concurrent
    rust builds, which is why runner capacity can go back to 2 at this size.
    Even at 80 GB the GC timer is not optional: a nix store, job images and a
    cargo cache grow without bound and nothing prunes them by default.
  EOT
  type        = string
  default     = "cx33"
}

variable "runner_ipv4s" {
  description = <<-EOT
    The runners' public IPv4 addresses, as /32 CIDRs, for the VPS's egress
    allow-list: `ssh -J vps root@<runner>` is the permanent admin path, and the
    runners are deliberately not on the tailnet.

    KEYED BY SERVER NAME, like runner_identities, not a positional list. Three
    parallel lists correlated by index is a data structure that silently
    survives being wrong: delete the middle entry of one and every later runner
    is pointed at its neighbour's address, with nothing to notice it. The map
    key is checked against runner_names below.

    NOT derived from hcloud_server.runner[*].ipv4_address, though it could be.
    That would make every firewall rule depend on the servers, so a plan that
    replaces a box also rewrites the firewall in the same apply -- and the VPS's
    own nftables copy in modules/firewall.nix (infra.runnerIPv4s) is a NixOS
    deploy that tofu cannot sequence anyway. Two explicit lists an operator
    updates together beat one clever list that updates half the control and
    silently leaves the other half stale.

    Keep this equal to infra.runnerIPv4s in modules/options.nix. A rule here
    without the matching nftables line is not sufficient: the VPS output chain
    is policy-drop and swallows the connection before it leaves the box.
  EOT
  type        = map(string)
  default     = { "forgejo-runner" = "46.225.61.172/32" }
}
