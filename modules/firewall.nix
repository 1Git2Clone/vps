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

          tcp dport {
            22,
            25,
            80,
            443,
            465,
            587,
            993,
            2222,
            25565
          } ct state new accept

          log prefix "DROP_in: " counter drop
        }

        chain output {
          type filter hook output priority filter; policy drop;

          oifname lo accept
          ct state { established, related } accept
          oifname tailscale0 accept

          tcp dport { 53, 80, 443, 25, 7844 } ct state new accept
          udp dport { 53, 123, 7844 } ct state new accept

          log prefix "DROP_out: " counter drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;

          ct state { established, related } accept

          log prefix "DROP_fwd: " counter drop
        }
      }
    '';
  };
}
