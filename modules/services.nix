# ==============================================================================
# Services
# ==============================================================================
{ config, lib, ... }:

{
  # ==============================================================================
  # The tailnet auth key, assembled rather than stored
  # ==============================================================================
  # sops holds the OAuth client secret and nothing else; the two query
  # parameters live HERE, in the clear, on purpose. They are not sensitive and
  # one of them is load-bearing in a way that is invisible when it is wrong:
  #
  #   ephemeral=false     MANDATORY. An OAuth-minted key defaults to
  #                       EPHEMERAL=TRUE, and an ephemeral node is REMOVED FROM
  #                       THE TAILNET when it goes offline. Left at the default,
  #                       this VPS would delete itself from the tailnet on every
  #                       reboot and come back as a new node — new tailnet
  #                       address, so the dozzle/grafana/syncthing A records and
  #                       the `vps` host in the policy file would both point at
  #                       nothing. Buried inside the encrypted blob, that is a
  #                       one-character mistake nobody can review.
  #
  #   preauthorized=true  Only matters if device approval is ever turned on for
  #                       the tailnet. Harmless now, and the difference between
  #                       an unattended rebuild and one that hangs waiting for a
  #                       human to click approve.
  #
  # The file is read by tailscaled-autoconnect, which passes it to
  # `tailscale up --auth-key`.
  sops.templates."tailscale-authkey".content =
    "${config.sops.placeholder.tailscale_oauth_client_secret}?ephemeral=false&preauthorized=true";

  # Lets a socket bind an address the box does not hold yet. sshd binds the
  # tailnet address and endlessh-go the public one, and at boot either can start
  # before tailscaled or the uplink brings its address up; without this the
  # bind fails and the unit with it, long after deploy-rs's rollback window.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  # sshd's tailnet-address bind on 22222 fails while the tarpit still holds the
  # wildcard there, which is what it did before this change. Starting sshd after
  # endlessh-go (ordering only, so a failed tarpit cannot hold sshd back) means
  # the switch that moves the tarpit onto the public address frees the port
  # first; sshd keeps 2222 either way, since it carries on past one failed bind.
  systemd.services.sshd.after = [ "endlessh-go.service" ];

  services = {
    openssh = {
      enable = true;
      # 2222, not 22: forgejo publishes the host's port 22 so that git clone
      # URLs need no port — ssh reads no SRV record, so anything else has to be
      # spelled out in every remote. This is THE administrative way in, over
      # the tailnet and otherwise: Tailscale SSH is off (see below), and
      # deploys, the runner's jump hop and interactive logins all come here.
      ports = [ 2222 ];
      # 22222 IS THE TAILNET-ONLY TRIAL. sshd listens there on the tailnet
      # address alone, so on that port the public address has no sshd at all
      # and endlessh-go (modules/tarpit.nix) holds it instead. 2222 keeps its
      # old behaviour, every address, as the safety net until the trial is
      # trusted. An explicit port on every entry, because a ListenAddress
      # without one would follow `ports` for all of them.
      listenAddresses = [
        {
          addr = "0.0.0.0";
          port = 2222;
        }
        {
          addr = "[::]";
          port = 2222;
        }
        {
          addr = config.infra.tailnetIPv4;
          port = 22222;
        }
      ];
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
      authKeyFile = config.sops.templates."tailscale-authkey".path;
      # TAILSCALE SSH IS OFF. With it on, tailscaled owns port 22 on the
      # tailnet address, and since split DNS sends git.<domain> to that address
      # on tailnet devices, `git@git.<domain>` landed on Tailscale SSH instead
      # of forgejo. sshd on 2222 does the job it did, with an ordinary key.
      #
      # extraSetFlags, not merely dropping --ssh from extraUpFlags: `up` only
      # runs on a fresh join (see below), while `tailscale set` runs on every
      # start, so this is what actually turns it off on the running node.
      extraSetFlags = [ "--ssh=false" ];
      extraUpFlags = [
        # MANDATORY WITH AN OAUTH CLIENT SECRET. Tailscale refuses to register a
        # device this way untagged — "you must pass in one or more of those tags
        # to the --advertise-tags flag" — so this is not a hardening option that
        # could be dropped, it is half of the credential.
        #
        # It also closes a gap that tagging by hand left open. tag:vps is what
        # the policy file in tofu/ narrows against, and a VPS rebuilt without it
        # rejoins as an ordinary user-owned device — which `autogroup:self:*`
        # covers on EVERY port. That would be a silent return to the flat
        # tailnet, visible only at the next `tofu plan`, and `deploy .#vps` does
        # not run tofu. Joining tagged makes the narrowing survive a rebuild.
        #
        # SAFE ON A RUNNING NODE. tailscaled-autoconnect only runs `tailscale
        # up` when the backend state is NeedsLogin, NeedsMachineAuth or Stopped;
        # on a node that is already Running it exits without touching anything.
        # So this takes effect on a fresh join and changes nothing today.
        "--advertise-tags=tag:vps"
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

        # Every docker network on this host (the default pool and botSubnet).
        # forgejo-ssh bans into the FORWARD chain, so a banned bridge address
        # cuts off every container at once — the 2026-09-05 outage, when a jail
        # banned 172.18.0.1. And a banned bridge address is never the attacker:
        # a connection that came through docker's userland proxy (see
        # modules/firewall.nix, PUBLISHED CONTAINER PORTS) shows the gateway as
        # its source. Structurally unbannable beats "the regex won't match it".
        "172.16.0.0/12"
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
