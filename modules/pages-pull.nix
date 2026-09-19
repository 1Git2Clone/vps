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
# NOTHING HERE KNOWS WHICH REPOS PUBLISH, AND THAT IS THE POINT. There used to
# be an infra.pagesRepos list, so adding a page meant editing this repo and
# running a deploy of the machine that serves mail — which is the wrong shape by
# the obvious comparison: nobody rebuilds GitHub to turn on a Pages site.
#
# The list existed because of a misread. When the runner moved off this box the
# note here said "the pull side has to be told what to look for". It has to be
# told how to FIND OUT, and the API already answers that: /api/v1/repos/search
# enumerates every repo anonymously, and a repo holding a live artifact named
# `pages` is a repo that publishes. Uploading that artifact IS the opt-in, the
# same way enabling Pages is a repo-level act rather than an infrastructure one.
#
# What this deletes along with the list: the whole class of stale-entry bug the
# old comment documented at length. A repo that is renamed or deleted simply
# stops being discovered, instead of failing this unit every five minutes
# forever until someone edits Nix.
#
# NO CREDENTIAL. The publishing repos are public and Forgejo serves both
# endpoints anonymously (verified 2026-09-19 against the live instance: the
# search returns 200 with a paginated list, the artifacts endpoint 200 with a
# bare JSON array, and 200 with `[]` for a repo that has never run Actions). The
# day a PRIVATE repo publishes, this needs a sops token with read:repository and
# not before — do not add one speculatively.
#
# WHAT DISCOVERY COSTS, STATED PLAINLY: any repo on this instance that uploads
# an artifact called `pages` gets served at pages.<domain>/<owner>/<repo>/.
# Registration is disabled, so the set of people who can create a repo here is
# the set who could already edit modules/options.nix — no new exposure, and
# strictly tighter than before the runner split, when any workflow that mounted
# the volume could write anywhere in it.
#
# NOT a gh-pages branch, which would be the idiomatic shape. That needs
# git-receive-pack, which modules/containers/caddy.nix now DENIES to runner
# addresses: its allow-list carries info/refs and git-upload-pack and nothing
# else, so a runner can clone and cannot push. Artifacts ride the twirp
# ArtifactService instead, sidestepping the need for it entirely.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) domain pagesVolume;

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

      # DISCOVERY. Every repo on the instance, paged through rather than
      # assuming one page holds them all — `limit` is capped server-side, so a
      # single request silently truncates once the instance outgrows it, and a
      # truncated list is a page that stops updating with nothing in the
      # journal to say why.
      repos=""
      page=1
      # The cap is a guard against a server that ignores `page` and keeps
      # answering with batch 1 — which would spin here forever at 30s a
      # request, with the timer's next tick piling in behind it. 20 pages of
      # 50 is 1000 repos; if this instance ever holds that many, the loop
      # stopping early is a far better failure than the unit never returning.
      while [ "$page" -le 20 ]; do
        batch=$(curl -fsS --max-time 30 \
          "https://${fqdn}/api/v1/repos/search?limit=50&page=$page" \
          | jq -r '.data[]?.full_name')
        # An explicit `if`, NOT `[ -z "$batch" ] && break`. Under `set -e` a
        # bare `cond && action` statement evaluates to the failing condition
        # when cond is false, and that is exactly the shape this module
        # already carries a paragraph about further down. Written this way
        # there is nothing to reason about.
        if [ -z "$batch" ]; then
          break
        fi
        repos="$repos $batch"
        page=$((page + 1))
      done

      # AN EMPTY DISCOVERY IS AN ERROR, NOT A QUIET DAY. This instance always
      # has repos, so zero means the search endpoint moved, changed shape, or
      # started refusing us — and the damage is that every published site
      # freezes at its current content while this unit keeps exiting 0. That is
      # the exact failure this repo keeps writing comments about, and the list
      # this replaced could not have it, so it has to be checked for here.
      if [ -z "$(echo "$repos" | tr -d '[:space:]')" ]; then
        echo "pages-pull: repo discovery returned NOTHING; refusing to treat that as 'no repos publish'" >&2
        exit 1
      fi

      for repo in $repos; do

        # Each repo runs in its own subshell so a failure here — repo renamed,
        # deleted, made private, a network blip, a corrupt zip — cannot take
        # down the rest of the loop. A transient failure heals itself on the
        # next tick five minutes later, so isolating it costs nothing. A
        # PERSISTENT one is the failure worth guarding: left unguarded, it
        # would permanently block every repo discovered after it, and it
        # would do so silently, since the unit
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
            # SILENT, and that changed with discovery. Under the old list this
            # branch meant "you named a repo that never published", which was
            # worth a line. Now it is simply most of the instance — a repo
            # without a `pages` artifact is not a pages repo — and logging it
            # would put a paragraph of noise in the journal every five minutes
            # for every repo that was never involved.
            #
            # Still NOT an error and NOT a reason to delete anything. A repo
            # that published once and whose artifacts have since expired hits
            # this branch too, and it keeps serving its last build rather than
            # 404ing. Distinguishing those two cases would need state this
            # deliberately does not keep.
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
          echo "pages-pull: $repo FAILED (exit $rc), see above; continuing with the remaining repos" >&2
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
