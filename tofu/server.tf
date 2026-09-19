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

# ==============================================================================
# The CI runner
# ==============================================================================
# A second, deliberately disposable box. It exists because forgejo-runner was
# sharing 15 GB with two JVMs that commit their heaps up front, and on
# 2026-09-18 a 732 MB `nix eval` was enough to push the box over and make the
# kernel shoot minecraft's java — the OOM killer scores by resident size, so the
# biggest idle process loses regardless of who caused the spike.
#
# Created in the console, ADOPTED here: see the import block in imports.tf. As
# with the VPS, do not apply against an unimported server — tofu would build a
# second one.
#
# Everything about it is imported-shaped rather than created-shaped:
#
#   * no public_net block. The provider's importer leaves public_net out of
#     state, so declaring it makes every post-import plan propose an ADDITION
#     that detaches and reattaches the live primary IPs — the exact accident
#     that cost 167.233.24.58 on 2026-09-05. This box's addresses
#     (46.225.61.172 / 2a01:4f8:1c19:cb62::/64) carry no reputation and no PTR,
#     but churn on a live attachment is still churn.
#   * protections are ON. An earlier revision of this comment argued they should
#     stay off because the box holds only caches -- true of the DISK and false
#     of the box: CX server types are limited-availability, so a destroyed
#     runner may simply not be re-creatable when it is wanted back. The operator
#     enabled protection live on 2026-09-19 for exactly that reason, and it is
#     declared here so a plan never proposes removing it.
#
#     THE CONSEQUENCE IS user_data. hcloud treats it as replace-forces-new, and
#     a protected server cannot be replaced -- so it is in ignore_changes below,
#     and an already-created box can never be given or handed a new identity
#     through it. That is what the staged-file channel in
#     modules/runner/identity.nix exists for. New boxes still get user_data at
#     CREATE time, where ignore_changes does not apply, so they stay
#     self-configuring.
resource "hcloud_server" "runner" {
  # One box per entry in var.runner_names. Every runner is the same closure with
  # the same settings; the only thing that differs between them is the identity
  # in user_data below, which each box reads back from its own metadata service.
  for_each = toset(var.runner_names)

  name        = each.key
  server_type = var.runner_server_type

  # nbg1, NOT var.location. The VPS is pinned to fsn1 because its primary IP is
  # location-bound and carries the mail reputation; this box has no such tie, and
  # a private network spans the whole eu-central zone, so the two being in
  # different cities costs nothing. See network.tf.
  location = "nbg1"

  # What the console booted it with. Ignored below, like the VPS's: nixos-anywhere
  # kexecs over it and nothing from this image survives the install.
  image = "ubuntu-26.04"

  ssh_keys = [hcloud_ssh_key.main.name]

  # Set live by the console at creation, so it is declared here. An attribute
  # that exists on the server but not in the config is not "unmanaged" — it is a
  # silent proposed removal on the next plan.
  labels = {
    runner = ""
  }

  # Delete and rebuild protection. See the header: CX types are
  # limited-availability, so "it only holds caches" is an argument about the
  # disk, not about whether the box can be got back.
  #
  # rebuild_protection blocks the hcloud rebuild-from-image action only.
  # nixos-anywhere is unaffected — it kexecs from inside the running system and
  # never calls that API.
  delete_protection  = true
  rebuild_protection = true

  # The Forgejo uuid+secret. Applied at CREATE time only: see ignore_changes.
  # modules/runner/identity.nix reads it back at every boot from
  # http://169.254.169.254/hetzner/v1/userdata — note that path, not the
  # plausible-looking /hetzner/v1/metadata/userdata, which 404s.
  user_data = var.runner_identities[each.key]

  # Same reason as the VPS: the firewall is attached by
  # hcloud_firewall_attachment, so a rule change never reads as a server change.
  ignore_remote_firewall_ids = true

  lifecycle {
    # user_data is here because it is replace-forces-new and these boxes are
    # protected: without it, editing an identity produces a plan that wants to
    # destroy a protected server, which fails the apply outright rather than
    # doing anything useful.
    #
    # ignore_changes suppresses diffs against PRIOR STATE, and a create has
    # none — so a NEW runner still receives its user_data and comes up
    # self-configuring. Only already-created boxes are frozen, and those take
    # their identity from the staged file instead.
    ignore_changes = [
      ssh_keys,
      image,
      public_net,
      user_data,
    ]
  }
}
