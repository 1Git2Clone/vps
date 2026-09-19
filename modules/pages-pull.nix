# ==============================================================================
# Pulling published pages off the runner
# ==============================================================================
# The pages job used to WRITE into the pages_data volume — that is what the old
# forgejo-runner.nix's one-entry valid_volumes allow-list was for. A runner on
# its own box cannot do that and must not: it would be the runner reaching into
# this machine, which is the one thing the split forbids.
#
# So the direction reverses. The job uploads an artifact; this fetches it. Every
# connection is initiated here, and in fact never leaves the host — the artifact
# is in Forgejo's own storage, in a container on this box.
#
# NO CREDENTIAL. The publishing repos are public and Forgejo serves
# /api/v1/repos/<owner>/<repo>/actions/artifacts anonymously (verified
# 2026-09-19 against the live instance: 200, with a bare JSON array body). The day a PRIVATE repo publishes, this needs a sops token
# with read:repository and not before — do not add one speculatively.
#
# NOT a gh-pages branch, which would be the idiomatic shape. That needs
# git-receive-pack, which modules/containers/caddy.nix is DESIGNED to deny to
# runner addresses — not yet built, so treat this as the reason that module
# exists rather than a control already in force. Artifacts ride
# /api/actions_pipeline/*, sidestepping the need for it entirely.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain pagesVolume pagesRepos;

  fqdn = "git.${domain}";
  pagesRoot = "/var/lib/docker/volumes/${pagesVolume}/_data";
in
{
  systemd.services.pages-pull = {
    description = "Fetch published pages artifacts into the pages volume";
    after = [ "docker-forgejo.service" ];
    wants = [ "docker-forgejo.service" ];

    serviceConfig = {
      Type = "oneshot";
      # Writes into a docker volume, which is root-owned.
      User = "root";
    };

    path = with pkgs; [
      curl
      jq
      unzip
      coreutils
    ];

    script = ''
      set -euo pipefail

      # Set, not incremented: one bad repo is enough to fail the unit at the
      # end. Whether it was one repo or all of them, the answer is "look at
      # the journal", not a count.
      failed=0

      for repo in ${lib.escapeShellArgs pagesRepos}; do
        echo "== $repo"

        # Each repo runs in its own subshell so a failure here — repo renamed,
        # deleted, made private, a network blip, a corrupt zip — cannot take
        # down the rest of the loop. A transient failure heals itself on the
        # next tick five minutes later, so isolating it costs nothing. A
        # PERSISTENT one is the failure worth guarding: left unguarded, it
        # would permanently block every repo listed after it in
        # infra.pagesRepos, and it would do so silently, since the unit
        # "succeeding" on the repos before the broken one looks no different
        # from everything being fine. This repo's other modules are full of
        # comments about exactly that failure shape — the outage nobody
        # notices because something upstream still looks healthy — so this
        # loop stays loud instead: log it, keep going, fail the unit at the
        # end. The subshell also gives each iteration its own EXIT trap, so
        # `tmp` is cleaned up on that iteration's exit whether it succeeded,
        # skipped, or failed — no manual reset needed between iterations.
        #
        # The subshell is run as a bare statement, NOT as `if ! ( ... ); then`
        # or `( ... ) || ...`. Bash disables `errexit` inside a compound
        # command that serves as the condition of `if`/`while`/`until`, is
        # negated with `!`, or sits anywhere but last in a `&&`/`||` list —
        # and it does so RECURSIVELY, even for a `set -e` re-declared inside a
        # nested subshell. Written that way, a failing `curl` here would be
        # swallowed rather than caught: the subshell would run to completion
        # printing wrong output instead of stopping at the failed step. `set
        # +e` / bare subshell / capture $? / `set -e` is the form that
        # actually stops the subshell where it should.
        set +e
        (
          set -euo pipefail

          # Newest artifact named `pages` that has not expired. Forgejo
          # returns expired entries with expired=true rather than omitting
          # them, so filtering on it is what stops us unpacking a 404.
          #
          # A BARE ARRAY, not an object with an `artifacts` key. This filter
          # read `.artifacts[]?` on its first deploy and every repo failed with
          # `jq: Cannot index array with string ("artifacts")`. The `?` made it
          # worse than a plain typo would have been: against an OBJECT with no
          # such key it would have yielded empty and logged the benign "no live
          # pages artifact" forever, so a shape mistake would have looked
          # exactly like "nothing published yet". Checked against this
          # instance's own swagger rather than assumed:
          # ActionArtifactList is `{type: array, items: ActionArtifact}`, and
          # ActionArtifact carries id, name, expired, created_at,
          # archive_download_url and run_id. The earlier note claiming this was
          # "verified 2026-09-19: 200" had verified the STATUS CODE, which says
          # nothing about the body.
          id=$(curl -fsS --max-time 30 \
            "https://${fqdn}/api/v1/repos/$repo/actions/artifacts" \
            | jq -r '[.[] | select(.name == "pages") | select(.expired != true)]
                     | sort_by(.created_at) | last | .id // empty')

          if [ -z "$id" ]; then
            # NOT an error, and NOT a reason to delete anything. Artifacts
            # expire; a repo that has not built in 90 days should keep
            # serving its last published build rather than 404.
            echo "no live pages artifact for $repo; leaving the existing tree alone"
            exit 0
          fi

          # Skip an unchanged build rather than churning the volume every 5
          # minutes: the id only moves when a new artifact is uploaded.
          # Checked BEFORE downloading anything — the point of this guard is
          # a true no-op on the common path, not just a skipped rename after
          # paying for a fetch-and-discard.
          stamp="${pagesRoot}/.stamp-$(echo "$repo" | tr / _)"
          if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$id" ]; then
            echo "$repo already at artifact $id"
            exit 0
          fi

          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT

          curl -fsSL --max-time 120 \
            "https://${fqdn}/api/v1/repos/$repo/actions/artifacts/$id/zip" \
            -o "$tmp/pages.zip"
          unzip -q "$tmp/pages.zip" -d "$tmp/out"

          # ATOMIC SWAP. caddy serves this read-only and a half-written tree
          # is a half-broken site, so the new content is staged as a sibling
          # and renamed over the old one — rename(2) within a filesystem is
          # atomic.
          dest="${pagesRoot}/$repo"
          staging="$dest.new"
          install -d -m 0755 "$(dirname "$dest")"
          rm -rf "$staging"
          cp -a "$tmp/out" "$staging"
          rm -rf "$dest.old"
          if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
          mv "$staging" "$dest"
          rm -rf "$dest.old"

          echo "$id" > "$stamp"
          echo "$repo updated to artifact $id"
        )
        rc=$?
        set -e

        if [ "$rc" -ne 0 ]; then
          # curl -S and unzip/jq already put their own reason on stderr; this
          # just ties it to the repo and makes sure it is not mistaken for a
          # clean run.
          echo "pages-pull: $repo FAILED (exit $rc), see above; continuing with the rest of infra.pagesRepos" >&2
          failed=1
        fi
      done

      # A failed oneshot does not disable its timer — only the unit fails,
      # and OnCalendar fires again next tick regardless — so exiting non-zero
      # here costs nothing but makes `systemctl status`/the journal show red
      # instead of quietly reporting success while a repo is stuck stale.
      if [ "$failed" -ne 0 ]; then
        echo "pages-pull: one or more repos failed this run" >&2
        exit 1
      fi
    '';
  };

  systemd.timers.pages-pull = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Five minutes. It was instant when the job wrote the volume directly, and
      # this is the cost of reversing the direction. A Forgejo webhook would make
      # it instant again at the price of an HTTP receiver on the mail server,
      # which is not a trade worth making for a static site.
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };
}
