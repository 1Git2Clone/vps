# ==============================================================================
# Runner identity — a declared uuid+secret out of Hetzner user-data
# ==============================================================================
# THIS REVERSES modules/containers/forgejo-runner.nix's DECLARED-not-registered
# argument, and the reversal is worth stating rather than quietly overwriting.
# That module is right that a uuid+secret pair beats a `register` call for the
# VPS's one permanent runner: no state file, nothing imperative, no first-boot
# ordering to get right. This file was ORIGINALLY built the other way — around a
# reusable *registration token* — because `register` looked like the one
# primitive that could hand N clones of one snapshot N distinct identities
# without Nix ever seeing a per-instance value.
#
# That reasoning had a bug: `forgejo-runner register` is DEPRECATED. Run
# `forgejo-runner register --help` against the exact package this flake builds
# and the first line says so.
#
# The fix keeps the clone story without `register` at all. Forgejo's declared
# mechanism needs the uuid at RUNTIME, not at EVALUATION time — Nix already
# cannot put the secret in a world-readable store path, which is why the VPS
# module reaches for `token_url: file://`, and once the secret has to be
# resolved on the machine at boot, resolving the uuid the same way is free. So:
# a runner record is created by hand in Forgejo per machine, and its uuid+secret
# is handed to that machine as HETZNER USER-DATA at create time.
#
# USER-DATA IS THE WHOLE MECHANISM, and it is the reason this file is short.
# user_data is per-SERVER metadata, not image content: a box built from a
# snapshot of this one is a new server and serves its OWN user-data, so N clones
# of one image come up as N distinct runners with no state, no stamping and no
# provenance checks. An earlier draft of this file carried ~400 lines of exactly
# that machinery — a staged `--extra-files` fallback, an instance-id stamp to
# police it, and a reuse branch to survive it — for one reason only: hcloud
# cannot add user-data to an EXISTING server (`user_data` is
# replace-forces-new), and the first box had been created in the console without
# any. Recreating an empty box is cheaper than maintaining the workaround, so
# tofu now sets user_data on hcloud_server.runner and the workaround is gone.
# Four consecutive review rounds each found a fresh hole in that machinery; none
# of those holes exist in code that is not there.
#
# The endpoint below is NOT the one the earlier draft used. `/hetzner/v1/
# metadata/userdata` — which looks right, sits beside the keys that do work, and
# survived five reviews — 404s on a real Hetzner box. User-data lives at its own
# top-level path, verified against instance 166488672:
#
#     /hetzner/v1/metadata      -> 200, the instance-id/hostname/network doc
#     /hetzner/v1/metadata/userdata -> 404
#     /latest/user-data         -> 404 (no EC2-compatible alias here)
#     /hetzner/v1/userdata      -> 204 with none set, 200 with
#
# 204-with-none-set is why this file distinguishes a transport failure from an
# empty body instead of treating both as "nothing found": with user-data as the
# only source, "the metadata service did not answer" must retry, and "it
# answered and has nothing" must fail loudly as the provisioning error it is.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Shared with modules/runner/default.nix, which sets WorkingDirectory here and
  # points the daemon at the config.yaml this unit composes.
  stateDir = "/var/lib/forgejo-runner";
  runnerUser = "forgejo-runner";
  runnerGroup = "forgejo-runner";

  # Recomposed from scratch on EVERY boot, never read back as state. That is
  # deliberate: every job on this box gets podman's rootful socket by design
  # (container.docker_host in default.nix), so a job that escapes can rewrite
  # anything on disk — including this file. Regenerating it unconditionally
  # means tampering survives exactly until the next reboot, and it is also what
  # lets a changed capacity/labels/docker_host in Nix actually reach the box.
  composedConfig = "${stateDir}/config.yaml";

  # The daemon resolves `token_url: file://` by reading this, so the secret
  # never has to be a literal in a file something else might scrape.
  secretFile = "${stateDir}/token";

  userdataUrl = "http://169.254.169.254/hetzner/v1/userdata";

  # The line this unit looks for in the user-data body, anywhere in it:
  #
  #     forgejo-runner: <uuid> <secret>
  #
  # Both halves come from Site Administration -> Actions -> Runners -> Create
  # new runner, which shows them together exactly once.
  userdataKey = "forgejo-runner";

  instanceUrl = "https://git.${config.infra.domain}/";

  # The display name in Site Administration -> Actions -> Runners. Every clone
  # from the snapshot carries the same one, and that is cosmetic: Forgejo tells
  # runners apart by the uuid in `server.connections`, not by this string.
  connectionName = config.networking.hostName;

  # Unchanged from the VPS runner, so no workflow in any repo needs an edit.
  # `ubuntu-latest` is a lie everyone tells: it is what workflows written for
  # GitHub say, and it must carry node, because every JavaScript action
  # (actions/checkout included) is executed by the node binary inside the JOB
  # container. nixos/nix carries nix, bash, gitMinimal, curl and coreutils and
  # NOTHING else — no node, so a workflow on that label cannot use a JavaScript
  # action; ci.yml does its own `git fetch`.
  labels = [
    "nix:docker://nixos/nix:2.35.2"
    "ubuntu-latest:docker://node:22-bookworm"
    "node-22:docker://node:22-bookworm"
    "alpine:docker://alpine:3.22"
  ];

  # One `echo` per label, indented to match the file this section is prefixed
  # onto: a multi-line interpolation only indents its first line, and YAML is
  # whitespace. Same technique as modules/containers/forgejo-runner.nix.
  labelEchoes = lib.concatMapStringsSep "\n" (l: "  echo \"        - ${l}\"") labels;
in
{
  systemd.services.forgejo-runner-identity = {
    description = "Compose the Forgejo runner's identity from Hetzner user-data";

    # The daemon cannot start without the config.yaml this writes, and must not
    # start with a stale one.
    requiredBy = [ "forgejo-runner.service" ];
    before = [ "forgejo-runner.service" ];

    # 169.254.169.254 is link-local and needs the interface up.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Only the transport failures below exit non-zero in a way a retry can
      # fix; a malformed or absent pair is a provisioning error that retrying
      # cannot help, and it says so in the journal rather than looping quietly.
      Restart = "on-failure";
      RestartSec = 5;
    };

    path = [
      pkgs.curl
      pkgs.gnused
      pkgs.coreutils
    ];

    script = ''
      set -euo pipefail

      # Cleans up the mktemp files below on ANY exit path: a failure between
      # writing the secret and moving it into place must not leave it sitting
      # under its temp name. ${"$"}{var:-} because `set -u` would otherwise
      # reject the trap firing before a variable is assigned.
      tmp=""
      tmpcfg=""
      trap 'rm -f "''${tmp:-}" "''${tmpcfg:-}"' EXIT

      # forgejo-runner is a static system user declared in
      # modules/runner/default.nix, not DynamicUser, so it already exists by the
      # time any unit starts and this can chown to it.
      install -d -m 0750 -o ${runnerUser} -g ${runnerGroup} ${stateDir}

      # The loader REFUSES to start when a legacy `.runner` registration file
      # sits beside a declared connection — "server connection conflict ... only
      # one config file can provide server connections". Nothing here ever calls
      # `register`, but ${stateDir} survives a snapshot, so one dragged in from
      # an older imperative setup has to be emptied rather than ignored.
      rm -f ${stateDir}/.runner

      # Prints the value of a "KEY: value" line found ANYWHERE in the body, not
      # just line 1. The `/^$1:/` address restricts the substitution to a line
      # that actually starts with the key, so a body leading with
      # `#cloud-config` or blank lines still matches; an earlier version ran
      # `s/.../p;q` with no address, whose `q` fired after line 1 regardless of
      # a match, making every clone with a `#cloud-config` header fail as "no
      # line" with the line right there. `q` inside the address stops at the
      # first HIT rather than the first LINE, which is also what keeps this
      # SIGPIPE-safe: sed discards everything ahead of the match itself, so `tr`
      # never exits before sed is ready to stop on its own terms.
      extract() {
        printf '%s\n' "$2" \
          | sed -n "/^$1:/{s/^$1:[[:space:]]*\(.\+\)\$/\1/p;q}" \
          | tr -d '\r'
      }

      # No `-f`: with it, curl reports a non-2xx response IDENTICALLY to a
      # dropped connection, conflating "the metadata service is not answering"
      # with "it answered and has nothing to say" — the two cases this has to
      # tell apart. Without it, curl's exit status reflects transport failures
      # only, and any body still comes back for `extract` to search.
      if ! live=$(curl -sS --max-time 10 ${userdataUrl} 2>/dev/null); then
        # TRANSIENT. network-online.target narrows the window but does not close
        # it, so this exits non-zero and lets Restart=on-failure try again
        # rather than reaching any conclusion about what user-data contains.
        echo "forgejo runner identity: could not reach the Hetzner metadata service at ${userdataUrl} — transient, retrying" >&2
        exit 1
      fi

      line=$(extract "${userdataKey}" "$live")

      if [ -z "$line" ]; then
        echo "no forgejo runner identity: the metadata service answered, but its user-data has no '${userdataKey}: <uuid> <secret>' line" >&2
        echo "this is a provisioning error, not a transient one — user_data is set at CREATE time only (hcloud cannot add it to an existing server), so fix tofu/server.tf's hcloud_server.runner and let it replace the box" >&2
        exit 1
      fi

      # `read` over two `awk` calls: one bash builtin, no subshell, no pipe,
      # nothing to SIGPIPE. The trailing `_` swallows anything past the second
      # field — a trailing comment, stray whitespace.
      read -r uuid secret _ <<<"$line"

      # THE VALIDATION IS THE POINT. Without it a malformed secret reaches the
      # daemon, which rejects it as "token contains invalid characters" and
      # restarts every few seconds — several restarts deep before anyone reads
      # the journal, and indistinguishable at a glance from a revoked
      # credential. That is exactly what happened to the VPS runner on
      # 2026-09-19. Bash's own `[[ =~ ]]` rather than `printf | grep -q`, which
      # exits the instant it matches and can SIGPIPE its writer.
      # NEITHER VALUE IS EVER ECHOED.
      if ! [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        echo "malformed forgejo runner identity: field 1 is not a uuid" >&2
        echo "expected '${userdataKey}: <uuid> <secret>' — a standard 8-4-4-4-12 hex uuid first, the value Forgejo shows above the secret when a runner record is created" >&2
        exit 1
      fi

      if ! [[ "$secret" =~ ^[A-Za-z0-9]{32,}$ ]]; then
        echo "malformed forgejo runner identity: field 2 is not a usable secret" >&2
        echo "expected 32 or more letters/digits — the value Forgejo shows beside the uuid when a runner record is created" >&2
        exit 1
      fi

      # Written to a temp file IN ${stateDir} — the SAME directory as the
      # destination — and moved with `mv`, not `install`. `install` copies into
      # the existing destination inode (open-and-truncate), which is not atomic:
      # a reader holding the old file open can observe a half-written one. `mv`
      # within one directory is a single rename(2). Same directory is
      # load-bearing: `mv` across filesystems degrades to copy-then-unlink,
      # exactly as non-atomic, which is why this stays out of /tmp.
      umask 077
      tmp=$(mktemp ${stateDir}/.token.XXXXXX)
      printf '%s' "$secret" > "$tmp"
      chmod 0400 "$tmp"
      chown ${runnerUser}:${runnerGroup} "$tmp"
      mv -f "$tmp" ${secretFile}

      # NO `runner.file` KEY anywhere in this file, ever. That is the legacy
      # `.runner` registration state, and the loader refuses to start when it
      # finds one beside a declared connection. Do not add a `runner:` block
      # with a `file:` key to "help" — it is not what that key is for.
      tmpcfg=$(mktemp ${stateDir}/.config.yaml.XXXXXX)
      {
        echo "# Composed at runtime by modules/runner/identity.nix — do not edit"
        echo "server:"
        echo "  connections:"
        echo "    ${connectionName}:"
        echo "      url: ${instanceUrl}"
        echo "      uuid: $uuid"
        # token_url, not token: config.yaml is a plain file on disk, and the
        # secret must not be a value some other reader of it (a backup, a debug
        # dump) picks up incidentally. `file:` is the one scheme the runner
        # resolves, and it trims the value.
        echo "      token_url: file://${secretFile}"
        echo "      labels:"
      ${labelEchoes}
        cat ${config.runner.staticConfigFile}
      } > "$tmpcfg"
      chmod 0440 "$tmpcfg"
      chown ${runnerUser}:${runnerGroup} "$tmpcfg"
      mv -f "$tmpcfg" ${composedConfig}

      echo "forgejo runner identity composed from user-data"
    '';
  };
}
