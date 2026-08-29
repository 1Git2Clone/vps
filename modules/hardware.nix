# ==============================================================================
# Hardware
# ==============================================================================
# What `nixos-generate-config` would have written as hardware-configuration.nix.
# This repo has none, and the consequence is not subtle: NixOS's default
# `availableKernelModules` set targets bare metal (ahci, ata_piix, nvme, sata_*)
# and contains NO virtio drivers at all. Hetzner Cloud presents its disk over
# virtio, so an initrd built without these cannot see /dev/sda, cannot mount
# root, and drops to an emergency shell — while the provider still reports the
# server as `running`, because the VM is powered on and only the OS is stuck.
#
# The nixos-anywhere `--vm-test` cannot catch this: the NixOS test harness
# injects its own virtio modules, so the config boots in the test and fails on
# the real machine. The only honest check is the module list itself.
{
  boot.initrd.availableKernelModules = [
    # The disk. virtio_pci is the bus; without it the other two never probe.
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "sd_mod"

    # The network, needed in initrd only if boot.initrd.network is ever enabled,
    # but harmless here and one less thing to discover later.
    "virtio_net"

    # The rescue/ISO path: Hetzner attaches images as an emulated CD-ROM.
    "sr_mod"
    "ata_piix"
    "ahci"
  ];
}
