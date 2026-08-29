# ==============================================================================
# The VPS
# ==============================================================================
# Provisioning is two steps that tofu drives in order: create a Hetzner server
# from an ordinary image, then let nixos-anywhere kexec into the NixOS installer,
# repartition with disko and install this flake's closure over it. The bootstrap
# image does not survive.
#
# Adopting the EXISTING server instead of creating a second one:
#   tofu import hcloud_primary_ip.main <primary-ip-id>
#   tofu import hcloud_server.vps 137766340
#   tofu import hcloud_ssh_key.main <ssh-key-id>
# then `tofu plan` and reconcile. Do NOT run apply against an unimported server
# — tofu would build a new one and the DNS records would follow it.

resource "hcloud_ssh_key" "main" {
  name = "${var.server_name}-install"

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
  name        = "${var.server_name}-ipv4"
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
    ignore_changes = [ssh_keys, image]
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
