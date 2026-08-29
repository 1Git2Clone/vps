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
  name       = "${var.server_name}-install"
  public_key = var.ssh_public_key
}

# A primary IP as its own resource, deliberately: the SPF record hard-codes this
# address and every A record points at it, so it must outlive the server. With
# auto_delete off, rebuilding the machine keeps the address and DNS never moves.
resource "hcloud_primary_ip" "main" {
  name        = "${var.server_name}-ipv4"
  type        = "ipv4"
  location    = var.location
  auto_delete = false

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

# nixos-anywhere installs, then keeps the machine up to date with nixos-rebuild
# on subsequent applies — so there is no second deployment tool to keep in sync.
module "deploy" {
  source = "github.com/nix-community/nixos-anywhere//terraform/all-in-one"

  # vps-hetzner, not vps: Hetzner Cloud presents the root disk as /dev/sda while
  # the local QEMU VM gets /dev/vda. Installing the wrong one repartitions
  # nothing and fails at disko.
  nixos_system_attr      = "${abspath("${path.module}/..")}#nixosConfigurations.vps-hetzner.config.system.build.toplevel"
  nixos_partitioner_attr = "${abspath("${path.module}/..")}#nixosConfigurations.vps-hetzner.config.system.build.diskoScript"

  target_host = hcloud_primary_ip.main.ip_address

  # Changing this triggers a reinstall, so it is the server's identity: a
  # replaced machine gets NixOS installed on it, an existing one does not.
  instance_id = hcloud_server.vps.id

  # Without the age key on the target, sops-install-secrets fails during
  # activation and the machine comes up with no root or user password at all.
  extra_files_script = "${path.module}/install-sops-key.sh"

  # debug_logging   = true
  # build_on_remote = true
}
