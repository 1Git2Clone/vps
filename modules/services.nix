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
        # Docker's address pools. Never an internet source, so excluding them
        # costs nothing — and it matters for the caddy-auth jail: traffic that
        # reaches a container through docker-proxy rather than DNAT (hairpin
        # from the host, for one) is logged with a bridge gateway as its
        # remote_ip, and banning a gateway would cut caddy off for everyone.
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

        # search.<domain> is the one public site behind caddy basic_auth, and
        # caddy has no rate limiting of its own. Every wrong password costs a
        # full bcrypt cost-14 verification — the same cost factor that makes
        # the hash useless to crack offline makes each online guess ~1s of CPU
        # for THIS box, so a few dozen requests a second from one address is a
        # denial of service for every site caddy fronts, before it is a
        # credential risk. This jail is what caps that.
        #
        # Same forward-chain arrangement as forgejo-ssh: 80/443 are published
        # container ports, so a ban has to land where forwarded traffic goes.
        # "tcp, udp" because caddy serves HTTP/3 on udp/443 too, and a tcp-only
        # ban would leave QUIC as the way around it.
        #
        # maxretry 5, not 3: a browser's FIRST request to a basic_auth site is
        # always a 401 (that is how it learns to prompt), so every fresh
        # session costs one legitimate hit, and a typo or two on the prompt
        # must not ban the person who owns the box.
        #
        # Verify, never assume:
        #   fail2ban-regex systemd-journal \
        #     /etc/fail2ban/filter.d/caddy-auth.conf \
        #     --journalmatch CONTAINER_TAG=caddy
        caddy-auth = {
          enabled = true;
          filter.Definition =
            let
              # The regex has to name the host: `log` is enabled only on the
              # search site today, but a 401 caddy relays from forgejo would be
              # a legitimate git-credential exchange, and this is what keeps
              # that from ever counting if someone turns on logging for git.
              host = "search\\.${lib.escapeRegex config.infra.domain}(?::\\d+)?";
            in
            {
              _prefix = "^(?:\\S+ )*\\S+\\[\\d+\\]:\\s+";
              # One caddy access-log line is one JSON object. remote_ip is the
              # TCP peer — not client_ip, which honours X-Forwarded-For and is
              # attacker-controlled without trusted_proxies configured.
              failregex = "%(_prefix)s\\{.*\"remote_ip\":\"<HOST>\".*\"host\":\"${host}\".*\"status\":401[,}]";
              ignoreregex = "";
            };
          settings = {
            port = "80,443";
            backend = "systemd";
            journalmatch = "CONTAINER_TAG=caddy";

            action = "nftables-allports[name=caddy-auth, protocol=\"tcp, udp\", chain=\"f2b-forward\", chain_hook=\"forward\"]";

            maxretry = 5;
            findtime = "10m";
            bantime = "1h";
          };
        };
      };
    };
  };
  virtualisation.docker.enable = true;
}
