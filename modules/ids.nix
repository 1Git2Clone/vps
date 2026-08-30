# ==============================================================================
# Service account ids
# ==============================================================================
# A container that runs as root does so because nobody chose otherwise. This is
# where that choice is written down.
#
# Ids are ASSIGNED, not derived. A hash of the service name was the alternative
# and it loses on every axis that matters here: the algorithm becomes immutable
# the moment the first file is written, a rename silently orphans that file, and
# `ls -n` shows you a number that means nothing. A table costs one line per
# service and is legible in a diff.
#
#   APPEND ONLY. Never renumber, never reuse a retired offset.
#
# These numbers end up in file ownership on disk — in docker volumes, in restic
# snapshots, on the ACME certificate directory. Changing one does not migrate
# anything; it orphans it, and the failure is a permission error at some later
# date rather than at the moment of the edit.
{ config, lib, ... }:

let
  cfg = config.infra;

  # 1_000_000 clears every allocator this host actually uses:
  #
  #   1-999          system users
  #   1000-29999     normal users (hutao is 1000)
  #   30001+         nixbld, and it GROWS with nix.nrBuildUsers
  #   60001-60513    systemd-homed
  #   61184-65519    systemd DynamicUser
  #   65534          nobody
  #   100000+        /etc/subuid, handed out in 65536-wide blocks per user, so
  #                  a second normal user takes 165536-231071 and so on
  #
  # The ceiling is 2097151: a ustar header stores uid in seven octal digits, so
  # anything above that cannot be represented in a plain tar archive.
  base = 1000000;
  ceiling = 2097151;

  ids = lib.mapAttrs (_: offset: base + offset) cfg.serviceIdOffsets;
in
{
  options.infra = {
    serviceIdOffsets = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.positive;
      default = { };
      example = {
        caddy = 1;
      };
      description = ''
        Offset from the id base for each service that runs under its own
        account. Append only: the resulting uid is written into file ownership,
        so renumbering orphans data rather than moving it.
      '';
    };

    serviceId = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      readOnly = true;
      description = ''
        Resolved uid/gid per service, as `base + offset`. Read this rather than
        writing a literal into a container module, so `grep -rn serviceId` finds
        every use of a given account.
      '';
    };
  };

  config = {
    # Only services that actually run under their own account belong here.
    # Assigning an id to a container that still runs as root would be a claim
    # the config does not keep.
    infra.serviceIdOffsets = {
      caddy = 1;
    };

    infra.serviceId = ids;

    # A group per assigned id, so an id in the table always has something on
    # the host to own files. This is what lets security.acme chown the
    # certificate directory to `caddy` rather than to `acme`.
    #
    # Groups only, deliberately: the uid lives inside a container and needs no
    # host account, and declaring users here would put entries in /etc/passwd
    # for accounts nothing on the host ever logs into.
    users.groups = lib.mapAttrs (_: id: { gid = id; }) ids;

    assertions = [
      {
        assertion =
          let
            offsets = lib.attrValues cfg.serviceIdOffsets;
          in
          lib.length (lib.unique offsets) == lib.length offsets;
        message = ''
          infra.serviceIdOffsets contains a duplicate. Two services sharing a
          uid can read each other's data, and nothing else would report it:
            ${lib.generators.toPretty { } cfg.serviceIdOffsets}
        '';
      }
      {
        assertion = lib.all (id: id > base && id <= ceiling) (lib.attrValues ids);
        message = ''
          A service id fell outside ${toString base}..${toString ceiling}.
          Below the base it can collide with nixbld, systemd or an /etc/subuid
          block; above the ceiling it cannot be stored in a ustar archive.
        '';
      }
    ];
  };
}
