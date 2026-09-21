# ==============================================================================
# Image archive — keep the bytes, not just the reference
# ==============================================================================
# A registry reference is not a guarantee that the bytes are still there.
# forgejo 16.0.2 proved it on this box: the TAG still resolved on codeberg, but
# a platform manifest inside the index had been deleted, so a rebuild from
# scratch could not reach it (see modules/containers/forgejo.nix). Digest pins
# do not cause that and tags do not prevent it — the only thing that helps is
# owning a copy.
#
# So: `docker save` every pullable image nightly into a directory restic
# already ships to B2, and teach each container unit to fall back to that copy
# when a pull fails. Digest pinning is what makes the fallback SOUND rather
# than merely convenient — a pinned pull either returns those exact bytes or
# fails, so "pull, else restore" can never quietly substitute a different
# image. With a floating tag it could.
#
# The order in ensure-image is deliberate: present, then pull, then disk, then
# restic. The archive is a fallback and never the normal path, so a renovate
# bump still reaches the registry the way it always did.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  archiveDir = "/var/lib/image-archive";
  docker = "${config.virtualisation.docker.package}/bin/docker";

  # The restic module generates this wrapper per backup job. It presets
  # RESTIC_REPOSITORY_FILE and RESTIC_PASSWORD_FILE and sources the B2
  # environment itself, so the restore path needs no secret wiring of its own —
  # it is the same credentials as the backup, by construction rather than by a
  # second copy that could drift.
  resticB2 = "/run/current-system/sw/bin/restic-b2";

  # Images built on this box, not pulled. `docker pull` can never satisfy them
  # and each already has a unit that produces it, so archiving them would
  # duplicate a nix-store artefact and ensuring them would mean a pull that is
  # guaranteed to fail:
  #   caddy, pages-hook    imageFile, a tarball built by dockerTools
  #   serenity-bot-*       serenity-bot-image.service builds it from source
  # serenity-redis is NOT one of these — it runs a registry image and is
  # covered like everything else, which is why this matches on the full prefix.
  locallyBuilt = name: c: c.imageFile != null || lib.hasPrefix "serenity-bot-" name;

  pullable = lib.filterAttrs (
    n: c: !(locallyBuilt n c)
  ) config.virtualisation.oci-containers.containers;

  # Deduplicated: two containers on the same image are one archive entry.
  images = lib.unique (lib.mapAttrsToList (_: c: c.image) pullable);
  imageList = pkgs.writeText "archived-images" (lib.concatStringsSep "\n" images + "\n");

  # ONE definition of the reference-to-filename mapping, in shell, used by both
  # scripts. Two copies of this rule would be a silent miss: the archive would
  # write one name and the restore would look for another, and nothing would
  # notice until the day it mattered.
  # NOT compressed. `docker save` already emits the layer blobs as the registry
  # stores them, so zstd measured 38M -> 38M on redis — and wrapping each
  # archive in one compressed stream would destroy restic's content-defined
  # deduplication, which is what makes a nightly copy of 2.6G nearly free and
  # lets the two minecraft images share their common base layers.
  slugFn = ''
    slug() { printf '%s' "$1" | tr '/:@' '___'; }
  '';

  archive = pkgs.writeShellApplication {
    name = "image-archive";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${slugFn}
      mkdir -p ${archiveDir}
      keep=""

      while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        s=$(slug "$ref")
        f=${archiveDir}/$s.tar
        keep="$keep $s.tar $s.id"

        # The id, not the reference, decides whether to re-save. A floating tag
        # keeps its name while its content moves, so comparing names alone
        # would archive such an image once and never refresh it again.
        id=$(${docker} image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)
        if [ -z "$id" ]; then
          echo "image-archive: $ref is not present locally, skipping"
          continue
        fi
        if [ -f "$f" ] && [ "$(cat "$f.id" 2>/dev/null || true)" = "$id" ]; then
          continue
        fi

        echo "image-archive: saving $ref ($id)"
        ${docker} save "$ref" -o "$f.tmp"
        mv "$f.tmp" "$f"
        printf '%s' "$id" > "$f.id"
      done < ${imageList}

      # An image dropped from the stack should not keep costing B2 space
      # forever. Anything not in this run's keep list goes.
      for f in ${archiveDir}/*; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        case " $keep " in
          *" $b "*) ;;
          *)
            echo "image-archive: removing stale $b"
            rm -f "$f"
            ;;
        esac
      done
    '';
  };

  ensureImage = pkgs.writeShellApplication {
    name = "ensure-image";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${slugFn}
      ref="$1"
      f=${archiveDir}/$(slug "$ref").tar

      if ${docker} image inspect "$ref" >/dev/null 2>&1; then
        exit 0
      fi

      echo "ensure-image: $ref is absent, pulling"
      if ${docker} pull "$ref"; then
        exit 0
      fi

      echo "ensure-image: pull failed, falling back to the archive"
      if [ ! -f "$f" ]; then
        echo "ensure-image: $f is not on disk, restoring it from restic"
        # --path selects the snapshot: this repository also holds the weekly
        # minecraft job's snapshots, and a bare `latest` could name one of
        # those, which carries no image archive at all.
        ${resticB2} restore latest --path ${archiveDir} --include "$f" --target /
      fi

      if [ ! -f "$f" ]; then
        echo "ensure-image: no archived copy of $ref anywhere; cannot start" >&2
        exit 1
      fi

      ${docker} load -i "$f"
      ${docker} image inspect "$ref" >/dev/null
    '';
  };
in
{
  systemd = {
    tmpfiles.rules = [ "d ${archiveDir} 0700 root root -" ];

    # Every pullable container gets the guard. mkBefore so it runs ahead of the
    # oci-containers module's own pre-start rather than replacing it — the list
    # is merged, not overwritten.
    services = lib.mkMerge [
      (lib.mapAttrs' (
        name: c:
        lib.nameValuePair "docker-${name}" {
          serviceConfig.ExecStartPre = lib.mkBefore [ "${ensureImage}/bin/ensure-image ${c.image}" ];
        }
      ) pullable)

      {
        image-archive = {
          description = "Save every pullable container image for offline restore";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe archive;
          };
        };
      }
    ];

    timers.image-archive = {
      description = "Refresh the container image archive nightly";
      wantedBy = [ "timers.target" ];
      # BEFORE the daily restic run, which fires in 00:00-01:00 — same reasoning
      # as postgresqlBackup at 23:15 in modules/backups.nix. An archive written
      # after the backup is an archive that reaches B2 a day late.
      timerConfig = {
        OnCalendar = "23:30";
        RandomizedDelaySec = "10m";
        Persistent = true;
      };
    };
  };
}
