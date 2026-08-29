# ==============================================================================
# Firewall
# ==============================================================================
# Ported from terraform/modules/hetzner-firewall, which still exists in tofu/
# and remains the outer layer — this is the inner one. The two are kept
# deliberately similar; the edge firewall is what survives a misconfiguration
# here, and this is what survives a misconfiguration there.
#
# THE FORWARD CHAIN IS WHERE CONTAINER TRAFFIC LIVES. A published container port
# is DNAT'd in prerouting and then *forwarded* — it never touches the input
# chain. Docker writes its own accepts into the `ip filter` table, which is a
# different table from this one, and in nftables every table's chain runs: an
# accept over there cannot rescue a packet this table drops. So with a
# policy-drop forward chain and no rules, every container is unreachable and has
# no egress either.
#
# The consequence to keep in mind when adding a service: a published port needs
# to be in the forward allow-list below, not the input one. Getting that backwards
# gives you a container the internet can reach but the firewall never authorised.
{
  networking.nftables = {
    enable = true;
    ruleset = ''
      table inet nixos-fw {
        chain input {
          type filter hook input priority filter; policy drop;

          iifname lo accept
          ct state { established, related } accept
          iifname tailscale0 accept

          # The host's own sshd. On 2222 because forgejo owns 22.
          tcp dport { 2222 } ct state new accept

          # Tailscale's own transport, so peers can find a direct path instead
          # of falling back to a DERP relay over 443.
          udp dport 41641 ct state new accept

          # PUBLISHED CONTAINER PORTS.
          #
          # These are here because the original assumption behind this ruleset —
          # "a published container port is DNAT'd and forwarded, so it never
          # touches input" — is FALSE on this host. Docker 29 manages nftables
          # natively and runs a userland proxy bound to the host port, so a
          # large share of external traffic to a published port arrives here as
          # ordinary input with the host's own address as destination:
          #
          #   IN=enp1s0 SRC=<client> DST=167.233.24.58 DPT=443 SYN  -> dropped
          #
          # The symptom is the nastiest kind: it half works. Some connections
          # take the DNAT path and succeed, others land on input and are dropped,
          # so the service looks up from one client and dead from another, and
          # forgejo's ssh on 22 never worked at all. Check with:
          #   nft list chain inet nixos-fw input | grep DROP_in
          #   journalctl -k | grep DROP_in | grep -oE 'DPT=[0-9]+' | sort | uniq -c
          #
          # This list therefore mirrors the forward chain exactly. Anything
          # published to the internet must appear in BOTH.
          tcp dport {
            22,
            25,
            80,
            443,
            465,
            587,
            993,
            25565
          } ct state new accept

          # HTTP/3, matching caddy's published 443/udp.
          udp dport 443 ct state new accept

          log prefix "DROP_in: " counter drop
        }

        chain output {
          type filter hook output priority filter; policy drop;

          oifname lo accept
          ct state { established, related } accept
          oifname tailscale0 accept

          # The host talking to its OWN containers. Docker's userland proxy
          # accepts a published port on the host and then opens a SECOND,
          # host-originated connection to the container across the bridge —
          # which leaves through this chain, not forward.
          #
          # This is the other half of the bug that made forgejo's ssh look
          # dead: the client's SYN reached the proxy fine, then the proxy's
          # onward connection to the container on port 22 was dropped here, so
          # the TCP handshake completed and the banner never arrived
          # ("timed out during banner exchange"). 443 and 25 worked only
          # because they happen to be in the list below; 993, 465, 587 and
          # 25565 were silently broken the same way.
          oifname { "docker0", "br-*" } accept

          # 443 also carries lego's ACME calls and the tailscale DERP fallback.
          tcp dport { 25, 53, 80, 443, 7844 } ct state new accept
          # 67 is the DHCP client renewing its lease.
          udp dport { 53, 67, 123, 443, 3478, 7844, 41641 } ct state new accept

          # See the input chain: this is IPv6's link layer, not a courtesy.
          icmpv6 type {
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            echo-request
          } accept
          icmp type echo-request accept

          log prefix "DROP_out: " counter drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;

          ct state { established, related } accept

          # Container egress, and container-to-container across the proxy
          # network. Traffic arriving from the internet has iifname eth0 and is
          # NOT matched by these, so they cannot open a published port.
          iifname "docker0" accept
          iifname "br-*" accept

          # The tailnet reaches every published port: dozzle on 8080 is
          # tailnet-only precisely because it is absent from the list below.
          iifname tailscale0 accept

          # From anywhere else, the published ports that are meant to be public.
          # DNAT has already happened, but these services all map host port to
          # the same container port, so the destination port still reads true.
          #   22    forgejo ssh
          #   25    smtp          465  smtps
          #   587   submission    993  imaps
          #   80    http          443  https
          #   25565 minecraft
          tcp dport {
            22,
            25,
            80,
            443,
            465,
            587,
            993,
            25565
          } ct state new accept

          # HTTP/3, which caddy publishes on 443/udp.
          udp dport 443 ct state new accept

          log prefix "DROP_fwd: " counter drop
        }
      }
    '';
  };
}
