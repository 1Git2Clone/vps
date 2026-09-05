# ==============================================================================
# Services
# ==============================================================================
{ config, lib, ... }:

{
  services = {
    openssh = {
      enable = true;
      # 2222, not 22: forgejo publishes the host's port 22 so that git clone
      # URLs need no port — ssh reads no SRV record, so anything else has to be
      # spelled out in every remote. Administrative access is normally over
      # Tailscale SSH; this is the way in when the tailnet is not.
      ports = [ 2222 ];
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PubkeyAuthentication = true;
        X11Forwarding = false;
        UsePAM = true;
      };
    };
    tailscale = {
      enable = true;
      authKeyFile = config.sops.secrets.tailscale_authkey.path;
      extraUpFlags = [
        "--ssh"
      ];
    };
    fail2ban = {
      enable = true;

      bantime = "1h";
      maxretry = 5;
      ignoreIP = [
        "127.0.0.1/8"
        "::1"
        "100.64.0.0/10" # tailscale CGNAT
      ];

      jails = {
        DEFAULT.settings.findtime = "10m";

        sshd = {
          enabled = true;
          settings = {
            port = 2222;
            backend = "systemd";
            maxretry = 3;
            findtime = "15m";
            bantime = "2h";
          };
        };
        # forgejo's container runs OpenSSH on the public port 22, so it absorbs
        # the internet's routine scanning. Two things about this jail are
        # load-bearing and both fail silently when wrong:
        #
        #   * The ban has to land in a chain that FORWARDED traffic traverses.
        #     A published container port is DNAT'd and forwarded — it never
        #     reaches the input hook, which is where fail2ban's nftables action
        #     puts its chain by default. The ansible version of this jail set
        #     `chain = DOCKER-USER`, which is the right answer for iptables and
        #     a trap here: with networking.nftables on, NixOS resolves
        #     banaction-allports to nftables-allports, and `chain` is only the
        #     nftables *chain name* — so DOCKER-USER would name an
        #     input-hooked chain and ban nothing that matters. chain_hook is the
        #     part that actually moves it, hence the explicit action below.
        #
        #   * journalmatch = CONTAINER_TAG=forgejo, which is why the container
        #     sets --log-opt tag=forgejo. Without the tag the journal identifier
        #     is the container ID and changes on every recreate.
        #
        # Verify a change to the regexes, never assume:
        #   fail2ban-regex systemd-journal \
        #     /etc/fail2ban/filter.d/forgejo-ssh.conf \
        #     --journalmatch CONTAINER_TAG=forgejo
        # A subtly wrong prefix matches nothing and the jail looks healthy.
        #
        # Check the ban path itself with: nft list table inet f2b-table
        forgejo-ssh = {
          enabled = true;
          # fail2ban's systemd backend hands the filter a reconstructed line
          # with the timestamp stripped, so the prefix matches the
          # "<host> <identifier>[<pid>]: " shape and tolerates any number of
          # leading tokens.
          #
          # Deliberately omitted: a bare "Connection reset by <HOST> port N".
          # It fires on any client that drops mid-handshake, legitimate git over
          # a flaky link included, and the patterns below already cover scanners.
          filter.Definition = {
            _prefix = "^(?:\\S+ )*\\S+\\[\\d+\\]:\\s+";
            # Joined with an indented newline on purpose: fail2ban parses its
            # config with Python's configparser, where a multi-value continuation
            # line MUST be indented. Unindented lines are read as malformed keys
            # and the jail ends up matching nothing.
            failregex = lib.concatStringsSep "\n  " [
              "%(_prefix)sUser \\S+ from <HOST> not allowed because not listed in AllowUsers\\s*$"
              "%(_prefix)sConnection closed by invalid user \\S+ <HOST> port \\d+ \\[preauth\\]\\s*$"
              "%(_prefix)sConnection closed by authenticating user \\S+ <HOST> port \\d+ \\[preauth\\]\\s*$"
              "%(_prefix)sInvalid user \\S+ from <HOST> port \\d+\\s*$"
              "%(_prefix)serror: maximum authentication attempts exceeded for \\S+ from <HOST> port \\d+ ssh2.*$"
            ];
            ignoreregex = "";
          };
          settings = {
            port = 22;
            backend = "systemd";
            journalmatch = "CONTAINER_TAG=forgejo";

            # Spelled out rather than assembled from banaction: the default
            # action_ template passes port/protocol/chain and nothing else, and
            # chain_hook is the one parameter this jail exists to override.
            # priority -1 puts it ahead of table inet nixos-fw, and the base
            # chain's implicit accept policy lets everything else fall through.
            action = "nftables-allports[name=forgejo-ssh, protocol=\"tcp\", chain=\"f2b-forward\", chain_hook=\"forward\"]";

            maxretry = 3;
            findtime = "15m";
            bantime = "24h";
          };
        };
      };
    };
  };
  virtualisation.docker.enable = true;
}
