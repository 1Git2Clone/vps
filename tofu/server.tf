# ==============================================================================
# The VPS
# ==============================================================================
# Provisioning is two steps that tofu drives in order: create a Hetzner server
# from an ordinary image, then let nixos-anywhere kexec into the NixOS installer,
# repartition with disko and install this flake's closure over it. The bootstrap
# image does not survive.
#
# Adopting the EXISTING server instead of creating a second one is not done by
# hand: imports.tf carries an import block for every live resource, so a plan
# from empty state imports rather than creates. Do NOT run apply against an
# unimported server — tofu would build a new one and the DNS records would
# follow it — and read imports.tf for what a correct recovery plan looks like.

resource "hcloud_ssh_key" "main" {
  name = var.ssh_key_name

  # Type and base64 only. Hetzner stores a key WITHOUT its trailing comment, so
  # passing "ssh-ed25519 AAAA... user@host" verbatim makes every plan see a
  # difference in public_key — and public_key forces replacement, so a cosmetic
  # comment turns into destroy-and-recreate on an otherwise no-op apply.
  public_key = join(" ", slice(split(" ", var.ssh_public_key), 0, 2))
}

# A primary IP as its own resource, deliberately: the SPF record hard-codes this
# address and every A record points at it, so it must outlive the server. With
# auto_delete off, rebuilding the machine keeps the address and DNS never moves.
resource "hcloud_primary_ip" "main" {
  name        = var.primary_ip_name
  type        = "ipv4"
  location    = var.location
  auto_delete = false

  # Declared, because it is set live and matters: this address carries the mail
  # reputation and the smtp.<domain> PTR. Leaving it out of the config means
  # every plan quietly proposes turning the protection OFF.
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

# The IPv6 /64. Declared for the same reason as the v4 above: without it the
# server's public_net.ipv6 is "known after apply", which leaves an attachment
# attribute undetermined in every plan. It is imported, not created — the block
# already exists and is attached.
#
# auto_delete stays true, matching how Hetzner created it. Unlike the v4 address
# this one carries nothing: DNS publishes no AAAA, and docker gives containers
# no IPv6, so postfix never presents an IPv6 address to a recipient.
resource "hcloud_primary_ip" "main_v6" {
  name        = var.primary_ip_v6_name
  type        = "ipv6"
  location    = var.location
  auto_delete = true

  # Declared because it is set live. An attribute you protect by hand but leave
  # out of the config does not stay protected — it becomes a silent
  # "true -> false" on the next plan, and a plan full of cosmetic noise is
  # exactly where that line gets skimmed past.
  #
  # Same omission cost the v4 address earlier: a stale plan detached
  # 167.233.24.58 and then tried to DELETE it. This flag is the only thing that
  # refused. It is worth more than it looks.
  delete_protection = true
}

resource "hcloud_server" "vps" {
  name        = var.server_name
  image       = var.bootstrap_image
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.main.name]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.main.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.main_v6.id
  }

  # The firewall is attached by hcloud_firewall_attachment rather than listed
  # here, so a firewall rule change never reads as a change to the server.
  ignore_remote_firewall_ids = true

  # Both, and Hetzner requires them to be equal — the API rejects setting only
  # one with "'delete' and 'rebuild' field required to be the same value".
  # This is the guard against the single most expensive mistake available here:
  # a deleted server cannot be undeleted, and CX-class capacity in a given
  # location is not guaranteed to exist when you go to replace it.
  delete_protection  = true
  rebuild_protection = true

  lifecycle {
    # Hetzner injects ssh_keys only at creation. Without this, rotating the
    # install key would destroy and recreate the machine.
    #
    # public_net is ignored for a different reason. The provider's importer and
    # its Read both leave public_net OUT of state, so any plan made after an
    # import — a fresh clone, a lost state file, the import blocks in
    # imports.tf — shows the block as an ADDITION. On this resource that is
    # not a metadata edit: the provider detaches the current primary IPs before
    # attaching what the config names. On 2026-09-05 that detached
    # 167.233.24.58 from the running mail server. ignore_changes does not apply
    # at creation, so a new server is still built with these IPs attached; it
    # only stops "state does not know about the block" from ever becoming an
    # action. The IPs themselves are their own resources, with their own
    # protection, and are where an attachment change should be made anyway.
    ignore_changes = [ssh_keys, image, public_net]
  }
}

# NOTE: the nixos-anywhere module used to live here and has been REMOVED, on
# purpose. It declared `null_resource.nixos-remote`, whose creation runs a full
# install — disko repartitions the disk and the closure is written over whatever
# is there. That is correct for a blank machine and catastrophic for a running
# one, and it is exactly what a plan proposes any time tofu's state does not
# already contain it: a fresh clone, a lost state file, or a `state rm` all
# produce a plan that silently includes "reinstall the mail server".
#
# The split is now:
#   infrastructure (server, IPs, firewall, DNS, rDNS)  -> tofu, here
#   installing NixOS onto a blank machine              -> nixos-anywhere, by hand
#   updating a machine that already runs NixOS         -> deploy .#vps
#
# Both commands are in docs/deploying.md. Neither can be triggered by an
# `apply`, which is the point.
