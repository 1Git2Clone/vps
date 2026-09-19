# ==============================================================================
# Runner identity — a registration token out of Hetzner user-data
# ==============================================================================
# The VPS runner's identity is DECLARED: a uuid and secret pair in config, no
# state file, nothing imperative. That is right for one permanent runner and
# impossible for N clones of one snapshot, because a uuid identifies exactly
# one runner record and two daemons claiming the same record is undefined.
#
# A REGISTRATION TOKEN can be reused. Each clone self-registers on first boot
# and gets its own record, and the token arrives in user-data — which is also
# the primitive an ephemeral orchestrator would mint through the API later, if
# that follow-up is ever built.
#
# THE FILE IS AN EnvironmentFile, NOT A TOKEN FILE. This is the one thing about
# this module that is easy to get wrong and fails opaquely. Upstream's
# services.gitea-actions-runner maps `tokenFile` straight onto systemd's
# EnvironmentFile= and its ExecStartPre reads $TOKEN, so the contents must be
# the line `TOKEN=<token>`. A bare token yields an empty $TOKEN and a
# registration that fails without saying why.
#
# TWO SOURCES, in order. user-data is how a clone gets its token and is the
# steady state. But the FIRST box is installed onto a server whose user-data
# was set by the console at creation and is empty, and hcloud treats user_data
# as replace-forces-new — so it cannot be added to an existing server. For that
# one case nixos-anywhere stages the file directly with --extra-files, exactly
# as apps.install stages the VPS's age key, and this unit finds it already
# present and leaves it alone.
#
# It FAILS LOUDLY when neither source has a token. A runner with no token
# cannot register, and a unit that exits 0 into a daemon that then crashloops
# is a worse diagnostic than a unit that says what is missing.
{ pkgs, ... }:

let
  tokenDir = "/var/lib/forgejo-runner-token";
  tokenEnvFile = "${tokenDir}/token.env";

  # Link-local, reachable over the public NIC, and served over plain HTTP —
  # which is why runner-firewall.tf keeps a tcp/80 egress rule. The whole
  # 169.254.169.254 address is exempt from the one-way rules in
  # modules/runner/firewall.nix because it is not the VPS.
  metadataUrl = "http://169.254.169.254/hetzner/v1/metadata/userdata";
in
{
  systemd.services.forgejo-runner-token = {
    description = "Install the Forgejo runner registration token from user-data";

    # The exact unit name upstream generates: gitea-runner-${escapeSystemdPath
    # name} for instances.<name>, and the instance in default.nix is `forgejo`.
    # Getting this wrong costs nothing at build time and means the runner
    # starts before its token exists.
    requiredBy = [ "gitea-runner-forgejo.service" ];
    before = [ "gitea-runner-forgejo.service" ];

    # The metadata service is on a link-local address over the public NIC, so
    # the interface has to be up. Without this the curl fails at boot and only
    # succeeds on a manual restart.
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [
      pkgs.curl
      pkgs.gnused
      pkgs.coreutils
    ];

    script = ''
      set -euo pipefail

      install -d -m 0700 ${tokenDir}

      # --max-time, because a hung metadata service must not hang the boot.
      # || true, because a 404 here is the ordinary case on the first box and
      # is handled below, not by killing the unit under `set -e`.
      userdata=$(curl -fsS --max-time 10 ${metadataUrl} 2>/dev/null || true)

      # The `key: value` shape rather than a bare token, so user-data can carry
      # other things later and so an empty or `#cloud-config` user-data is not
      # mistaken for a token. tr -d '\r' because metadata services emit CRLF.
      token=$(printf '%s\n' "$userdata" \
        | sed -n 's/^forgejo-runner-token:[[:space:]]*\(.\+\)$/\1/p' \
        | head -n1 | tr -d '\r')

      if [ -n "$token" ]; then
        umask 077
        tmp=$(mktemp)
        printf 'TOKEN=%s\n' "$token" > "$tmp"
        install -m 0400 -o root -g root "$tmp" ${tokenEnvFile}
        rm -f "$tmp"
        echo "registration token installed from user-data"
        exit 0
      fi

      if [ -s ${tokenEnvFile} ]; then
        # Non-empty is not enough — it must actually be the EnvironmentFile
        # line upstream's ExecStartPre reads $TOKEN from. A staged file
        # holding a bare token (no TOKEN= prefix) is exactly the "empty
        # $TOKEN, opaque failure" case this module's header exists to
        # prevent, and it would pass a plain [ -s ] check silently.
        if grep -q '^TOKEN=.' ${tokenEnvFile}; then
          # The first box: nixos-anywhere --extra-files put it here before the
          # first activation. Do not overwrite it with nothing.
          echo "no token in user-data; keeping the existing ${tokenEnvFile}"
          exit 0
        fi

        echo "no registration token: user-data has no 'forgejo-runner-token:' line, and the existing ${tokenEnvFile} does not contain a 'TOKEN=<value>' line" >&2
        echo "fix ${tokenEnvFile} to read TOKEN=<token> (a bare token is not enough), or supply forgejo-runner-token: in user-data" >&2
        exit 1
      fi

      echo "no registration token: user-data has no 'forgejo-runner-token:' line and ${tokenEnvFile} is absent or empty" >&2
      echo "set it with: hcloud server create --user-data-from-file, or stage the file with nixos-anywhere --extra-files" >&2
      exit 1
    '';
  };
}
