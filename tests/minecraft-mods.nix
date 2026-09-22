# ==============================================================================
# Minecraft — Modrinth mod compatibility check
# ==============================================================================
# The lists in modules/containers/minecraft.nix are the whole server: itzg's
# MODRINTH_PROJECTS downloads exactly the slugs it is given, and a slug with no
# build for the server's MC version + loader fails the WHOLE start — an outage,
# not a missing mod. The lists are therefore verified by hand every time a
# version moves, and a hand check goes stale the moment the config changes.
#
# This is that check, mechanised. It reads the mod lists and MC versions out of
# the EVALUATED config rather than restating them, so there is no second copy to
# drift: add a world, add a slug, bump VERSION — the check follows, because the
# containers it inspects are whatever the host actually declares. A container
# qualifies when it sets MODRINTH_PROJECTS and VERSION, which is the same
# condition itzg uses to decide to download mods at all.
#
# The compatibility rule is itzg's own, not an invention here. Per its docs,
# MODRINTH_PROJECTS entries are `[prefix:]project[:version|:release_type][?]`:
#
#   project            newest build of the container's DEFAULT CHANNEL, which is
#                      MODRINTH_PROJECTS_DEFAULT_VERSION_TYPE — release unless the
#                      container says otherwise, and read out of the env here
#                      rather than assumed, so that variable cannot drift from
#                      what this check enforces
#   project:beta       newest release OR beta
#   project:alpha      newest release, beta OR alpha
#   project:<id>       a pinned version ID, which per itzg's docs "will override
#                      Minecraft and loader compatibility checks" — so the only
#                      question worth asking is whether Modrinth has it at all,
#                      and the lookup for it is deliberately UNFILTERED
#   project:<number>   a pinned version NUMBER. That override is documented for
#                      IDs alone, so this one is looked up unfiltered and THEN
#                      checked against our MC version + loader.
#   project?           optional: no compatible build is a warning, not a failure
#   fabric:project     loader override (a Fabric mod on a non-Fabric server).
#                      itzg documents datapack/fabric/forge/paper; neoforge and
#                      quilt are accepted here too, which is only more lenient.
#
# `:beta`/`:alpha` are load-bearing in this repo, not decoration: at 1.21.1
# sound-physics-remastered has published no RELEASE at all, so the bare slug
# fails the start outright. `:alpha` is what reaches the newest build
# (fabric-1.21.1-1.5.1, 2025-09-25); `:beta` would also install, but pins that
# world to fabric-1.21.1-1.4.10 from March 2025 — so the suffix chooses WHICH
# build, not whether there is one. Getting the rule backwards would make the
# check bless a slug the image then refuses to install.
#
# WHY THIS IS A PACKAGE AND NOT A `checks` ENTRY.
# It queries api.modrinth.com, so it needs the network, and Nix builds in a
# sandbox with no network by default. A derivation that needs the network must be
# marked __noChroot, and Nix refuses to build one while `sandbox = true`:
#
#   error: derivation '...' has '__noChroot' set, but that's not allowed when
#   'sandbox' is 'true'
#
# In `checks` that error is not confined to this derivation: it fails a plain
# `nix flake check` outright and takes every OTHER check down with it on any
# machine with a normal sandbox. So it lives in `packages.minecraft-mods` and CI
# builds it by name — the Forgejo runner's image already sets `sandbox = false`,
# and the GitHub mirror's step passes `--option sandbox false` for this one
# build. Locally, use the app instead — it builds the script offline and runs it
# with your shell's network:
#
#   nix run .#minecraft-mod-check
#
# The failure mode this exists to prevent is a GREEN check over a list nobody
# read, so both halves of that are guarded: an empty extraction and an empty
# project list each fail loudly rather than pass vacuously.
{
  nixpkgs,
  system,
  # The EVALUATED `virtualisation.oci-containers.containers` of the deploy
  # target. Passed in whole; only environment.TYPE/VERSION/MODRINTH_PROJECTS are
  # forced, so no store path from another container's config is dragged in.
  containers,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;

  # itzg TYPE -> the loader facet the Modrinth API expects. The API's loader
  # names are lowercase and not always the TYPE verbatim (NEOFORGE -> neoforge,
  # PAPER plugins -> paper), so this is a table rather than lib.toLower. An
  # unmapped TYPE falls back to its lowercase form, which is right for the
  # FABRIC/QUILT/FORGE cases we run today and fails loudly at the API for
  # anything that is not a real loader.
  loaderFor =
    type:
    {
      FABRIC = "fabric";
      QUILT = "quilt";
      FORGE = "forge";
      NEOFORGE = "neoforge";
      PAPER = "paper";
      SPIGOT = "spigot";
      BUKKIT = "bukkit";
    }
    .${type} or (lib.toLower type);

  # MODRINTH_PROJECTS is "comma or newline separated" per itzg, and this repo
  # builds it with lib.concatStringsSep "," — but a future hand-written list may
  # use newlines, so split on both and drop the empties.
  splitProjects =
    value:
    builtins.filter (s: s != "") (lib.flatten (map (lib.splitString ",") (lib.splitString "\n" value)));

  # Only containers that actually install mods. This is the auto-discovery: a
  # third world with its own VERSION and MODRINTH_PROJECTS joins the check with
  # no edit here.
  servers = lib.filterAttrs (_: v: v != null) (
    lib.mapAttrs (
      _: container:
      let
        env = container.environment;
      in
      if env ? MODRINTH_PROJECTS && env ? VERSION then
        {
          version = env.VERSION;
          loader = loaderFor (env.TYPE or "VANILLA");
          # What a BARE slug resolves to. itzg's default is release, but a
          # container is free to say otherwise, and a check that hardcoded
          # `release` would be a second copy of exactly the policy this file
          # exists to stop restating.
          defaultChannel = env.MODRINTH_PROJECTS_DEFAULT_VERSION_TYPE or "release";
          projects = splitProjects env.MODRINTH_PROJECTS;
        }
      else
        null
    ) containers
  );

  serversJson = pkgs.writeText "minecraft-servers.json" (builtins.toJSON servers);

  modCheck = pkgs.writeShellApplication {
    name = "minecraft-mod-check";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      gnugrep
      cacert
    ];
    text = ''
      set -euo pipefail

      API=https://api.modrinth.com/v2
      SERVERS=${serversJson}
      # Modrinth asks for a descriptive User-Agent; the default curl one is
      # pooled and rate-limited harder.
      UA='hu-tao/vps minecraft-mod-check (https://git.hu-tao.dev/hutao/vps)'

      # Nix's curl does not read the host's /etc/ssl/certs, and a build has no
      # /etc at all. Without this every request dies in TLS before Modrinth is
      # reached, which reads like a network outage rather than a missing CA.
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      export CURL_CA_BUNDLE="$SSL_CERT_FILE"

      failed=$(mktemp)
      trap 'rm -f "$failed"' EXIT

      servers=$(jq 'length' "$SERVERS")
      if [ "$servers" -eq 0 ]; then
        echo "minecraft-mod-check: no container declares MODRINTH_PROJECTS — refusing to pass vacuously" >&2
        exit 1
      fi

      # An entry that is allowed to be missing is a warning; anything else is a
      # failure, and every failure is printed at the end so one run names every
      # broken slug rather than stopping at the first.
      record() {
        local server=$1 project=$2 optional=$3 reason=$4
        if [ "$optional" -eq 1 ]; then
          printf '  %-12s %-30s SKIPPED (optional): %s\n' "$server" "$project" "$reason"
        else
          printf '%s\t%s\t%s\n' "$server" "$project" "$reason" >> "$failed"
        fi
      }

      echo "Modrinth compatibility — $servers server(s)"
      checked=0

      while IFS=$'\t' read -r server version loader default project; do
        checked=$((checked + 1))

        optional=0
        entry=$project
        case "$entry" in
          *'?')
            optional=1
            entry=''${entry%'?'}
            ;;
        esac

        # Loader prefix, e.g. `fabric:fabric-api`. Overrides the container TYPE.
        case "$entry" in
          datapack:* | fabric:* | forge:* | neoforge:* | quilt:* | paper:*)
            loader=''${entry%%:*}
            entry=''${entry#*:}
            ;;
        esac

        slug=''${entry%%:*}
        spec=""
        if [ "$entry" != "$slug" ]; then
          spec=''${entry#*:}
        fi

        # A release-type spec selects a channel; anything else is a pinned
        # version number or ID. No spec at all means the container's own default.
        pinned=""
        channel=$default
        case "$spec" in
          "") ;;
          release | beta | alpha) channel=$spec ;;
          *) pinned=$spec ;;
        esac

        # UNFILTERED for a pinned entry, and that is the point: itzg documents
        # a version ID as overriding the MC and loader compatibility checks, so
        # asking Modrinth only for versions matching OUR version and loader would
        # report a deliberate cross-version pin as missing. Compatibility is
        # asked below instead, and only for a pin that turns out to be a version
        # number rather than an ID.
        filter=(
          -G
          --data-urlencode "loaders=[\"$loader\"]"
          --data-urlencode "game_versions=[\"$version\"]"
        )
        if [ -n "$pinned" ]; then
          filter=()
        fi

        if ! resp=$(curl -sS -m 30 --retry 3 --retry-delay 2 \
            -H "User-Agent: $UA" -w $'\n%{http_code}' \
            "''${filter[@]}" \
            "$API/project/$slug/version"); then
          record "$server" "$project" "$optional" "request failed (network or DNS)"
          continue
        fi

        code=''${resp##*$'\n'}
        body=''${resp%$'\n'*}

        if [ "$code" = 404 ]; then
          record "$server" "$project" "$optional" "project not found (bad slug?)"
          continue
        fi
        if [ "$code" != 200 ]; then
          record "$server" "$project" "$optional" "Modrinth API HTTP $code"
          continue
        fi
        if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
          record "$server" "$project" "$optional" "Modrinth API returned non-JSON"
          continue
        fi

        if [ -n "$pinned" ]; then
          # Matched by .id -> itzg skips the compatibility check, so merely
          # existing is enough. Matched by .version_number -> that documented
          # override does not apply, so the build still has to carry our loader
          # and MC version.
          verdict=$(jq -r --arg p "$pinned" --arg l "$loader" --arg v "$version" \
            '([.[] | select(.id == $p or .version_number == $p)] | .[0]) as $m
             | if $m == null then "missing"
               elif $m.id == $p then "ok " + $m.version_number
               elif ($m.loaders | index($l)) and ($m.game_versions | index($v))
                 then "ok " + $m.version_number
               else "incompatible " + $m.version_number
               end' \
            <<<"$body")
          case "$verdict" in
            missing)
              record "$server" "$project" "$optional" "pinned version '$pinned' is not on Modrinth"
              continue
              ;;
            incompatible*)
              record "$server" "$project" "$optional" \
                "pinned version '$pinned' has no $loader build for MC $version (pin the version ID to override)"
              continue
              ;;
          esac
          chosen=''${verdict#ok }
        else
          # Newest-first from the API, so the first match is the one itzg would
          # install. $t is the set of version types the channel admits.
          chosen=$(jq -r --arg c "$channel" \
            '(["release"]
              + (if $c == "beta" or $c == "alpha" then ["beta"] else [] end)
              + (if $c == "alpha" then ["alpha"] else [] end)) as $t
             | [.[] | select(.version_type as $vt | $t | index($vt))]
             | .[0].version_number // empty' \
            <<<"$body")
          if [ -z "$chosen" ]; then
            record "$server" "$project" "$optional" "no $channel-compatible build for MC $version ($loader)"
            continue
          fi
        fi

        printf '  %-12s %-30s %s\n' "$server" "$project" "$chosen"
      done < <(jq -r 'to_entries[] | .key as $s | .value as $v | $v.projects[] | [$s, $v.version, $v.loader, $v.defaultChannel, .] | @tsv' "$SERVERS")

      if [ "$checked" -eq 0 ]; then
        echo "minecraft-mod-check: MODRINTH_PROJECTS is declared but empty — refusing to pass vacuously" >&2
        exit 1
      fi

      if [ -s "$failed" ]; then
        echo "" >&2
        echo "minecraft-mod-check: incompatible Modrinth projects" >&2
        while IFS=$'\t' read -r server project reason; do
          printf '  %-12s %-30s %s\n' "$server" "$project" "$reason" >&2
        done < "$failed"
        exit 1
      fi

      echo "minecraft-mod-check: all $checked entries have a compatible build"
    '';
  };
in
{
  # The runnable script. `nix run .#minecraft-mod-check` is the local entry
  # point, and it needs no sandbox trick because only the *build* is offline.
  inherit modCheck;

  # The check as CI builds it. __noChroot is what permits the network; see the
  # header for why that implies `sandbox = false`.
  check = pkgs.runCommand "minecraft-mods" { __noChroot = true; } ''
    ${modCheck}/bin/minecraft-mod-check
    touch $out
  '';
}
