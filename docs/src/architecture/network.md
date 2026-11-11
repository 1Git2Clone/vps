# Network and trust boundaries

Traffic reaches the VPS through three doors, and each service sits behind
exactly one of them.

```mermaid
flowchart TB
    net(("Internet"))
    tailnet(("Tailnet"))

    net --> edge["<b>Door 1</b> · Hetzner edge firewall<br/><code>tofu/modules/hetzner-firewall</code>"]
    edge --> nft["<b>Door 2</b> · host nftables<br/><code>modules/firewall.nix</code>"]
    tailnet --> pol["<b>Door 3</b> · tailnet policy file<br/><code>tofu/tailscale-policy.hujson</code>"]
    pol --> ts["tailscale0<br/>accepted wholesale on input"]

    nft --> inp["input hook"]
    nft --> fwd["prerouting DNAT → forward"]
    ts --> inp

    inp --> hostsvc["host namespace<br/>sshd :2222 · grafana :3000<br/>tempo :4317/4318 · pgbouncer :6432<br/>syncthing GUI :8384<br/>tarpit :222/2022/22222"]
    fwd --> dock["docker networks<br/><code>proxy</code> · <code>botnet</code> · <code>mc</code>"]
    dock --> caddy["caddy"]
    caddy --> pub["public vhosts :443"]
    caddy --> priv["tailnet vhosts :8443"]

    classDef door fill:#2d4a7c,stroke:#16233c,color:#fff
    class edge,nft,pol door
```

## The two firewalls

The edge firewall (`tofu/`) and the host firewall (`modules/firewall.nix`) are
kept deliberately similar: **each is what survives a misconfiguration of the
other.** A port opened at one but not the other is still closed. When something
is unreachable, check both.

## Floods below the edge's radar

Hetzner's edge filters volumetric floods. What it lets through is still enough
to hurt a single box, so `modules/firewall.nix` covers the gap:

- **Spoofed SYN floods vs the conntrack table.** Every accepted SYN to an open
  port is tracked until it times out. With the kernel defaults (262,144
  entries, 120 s per unanswered SYN), about 2,200 spoofed SYNs a second, roughly
  1 Mbit/s, fill the table. After that every new connection is dropped,
  including the tailnet's SSH. The table is now 1,048,576 and the SYN timeouts
  20 s, which puts the threshold at roughly 50,000 a second (~25 Mbit/s). Above
  that, filtering is the edge's job. Check headroom with
  `sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max`.
- **One address, at most 128 open connections** (`conn_per_source`), on both
  hooks. Caddy's zones count requests, not sockets, so nothing else stopped one
  client from parking thousands of slow connections (slowloris). Closed
  connections free their slot at once. `nft list set inet nixos-fw
  conn_per_source` shows who is counted.
- **Drop logging is sampled** at 10 lines a second. Junk to a closed port is the
  cheapest flood there is, and an unlimited `log` rule turned each packet into
  a journald write. The counters still count everything. `ct state invalid`
  packets are dropped before the log rule.

Bandwidth spent on large downloads is capped one layer up, in caddy, by one
bucket shared by every client; see
[Access control](access-control.md#rate-limiting-every-site-by-default).

## input vs forward — the single most load-bearing fact

A published container port is **DNAT'd in prerouting and then forwarded** — it
never touches the input hook. Docker writes its own accepts into the
`ip filter` table; in nftables _every_ table's chain runs, and an accept in
docker's table cannot rescue a packet that `table inet nixos-fw` drops. So:

- A service's **published port belongs in the forward allow-list**, not input.
  Getting it backwards yields a port the internet can reach that the firewall
  never authorised.
- **Host-namespace services** (sshd on 2222, grafana, tempo, pgbouncer,
  syncthing, the SSH tarpit, prometheus) are on the **input** hook.
- `networking.nftables.flushRuleset` **must stay false**. The default flushes
  the entire ruleset — including the tables docker owns — on every reload, and
  docker only rebuilds them when `dockerd` starts. The symptom is latent:
  running containers keep working, the _next_ container start fails with
  `iptables: No chain/target/match by that name`, and recovery is
  `systemctl restart docker`.

This boundary is also why fail2ban jails for containerised services set
`chain_hook = forward`, which carries a sharp edge of its own — see
[Failure modes](../operations/recovery.md#the-fail2ban-blast-radius).

## Docker networks

| Network  | Subnet                   | Purpose                                                                                                                                                                                                                                                                                |
| -------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `proxy`  | `172.18.0.0/16` (pinned) | caddy resolves its upstreams here by container name over docker's embedded DNS — no IP addresses in the Caddyfile                                                                                                                                                                      |
| `botnet` | `172.30.0.0/24` (pinned) | the discord bot + its redis, isolated from the proxy. Pinned because `infra.botGateway` (172.30.0.1) is a literal in the bot's `DATABASE_URL`, its OTLP endpoint, and the firewall's input rule                                                                                        |
| `mc`     | `172.31.0.0/24` (pinned) | mc-router (pinned at 172.31.0.2) and the Minecraft worlds behind it, which get addresses from `172.31.0.128/25` so they can never take mc-router's. Pinned because the firewall's input rule and `minecraft-scaler` (on the gateway, 172.31.0.1:25580) admit mc-router's address alone |

`proxy` is pinned so caddy can sit at a fixed `172.18.0.2` (`infra.caddyIPv4`),
the address the tailnet DNAT below sends to. Docker gives every other container
an address from `172.18.128.0/17` (`infra.proxyIpRange`), so none of them can
take caddy's while it is down. The subnet is the one docker's pool had already
assigned, so the `172.16.0.0/12` trust settings still cover it.

`modules/containers/default.nix` creates each network as a oneshot systemd unit
that every container on it `requires`, so a container can never start onto a
network that does not exist yet.

`infra.dockerBridgeGateway` (172.17.0.1) is a third address that matters: it is
how a container reaches a service in the **host's** network namespace, which is
what caddy does for grafana:3000 and syncthing's GUI:8384. It is **observed,
not enforced** — deliberately not pinned with the daemon's `bip` setting, even
though pinning is what `botSubnet`/`botGateway` do for a network this repo
creates itself. `bip` is daemon config, so setting it restarts `docker.service`,
which stops every container. A wrong value here costs one failed container
start and a rollback; pinning it costs a full container restart on every deploy
that touches the line.

The input rule that makes that route work is

```nft
iifname "br-*" ip saddr != { 172.30.0.0/24, 172.31.0.0/24 } tcp dport { 3000, 8384, 8443 }
```

and the exclusion is the point. The rule above it grants the bot exactly two ports
(4317, 6432) from exactly `botSubnet`; without the `!=`, this one immediately
handed the same bridge three more, so a narrow grant was followed by a broad one
and only the broad one meant anything. The bot is the right container to
subtract first — it is the only one here whose input is arbitrary text from
strangers that it then ships to a third-party model. The `mc` network is
subtracted too: the worlds run mods off Modrinth, third-party code with the
world's privileges.

What remains matched is **deliberate and worth knowing**: searxng, kuma,
forgejo, navidrome, dozzle, cloudflared, mailserver, webmail and pages-hook
share the proxy bridge with caddy, so they are still admitted to those three
ports. Both services behind them are credential-protected (grafana has a real
admin login with sign-up off; syncthing's GUI password is declared by
`modules/syncthing.nix` through `guiPasswordFile` and re-applied on every
deploy), so this is defence in depth, not a hole being closed.

That syncthing half used to be an **assertion about the live box** rather than
something the deploy enforced. The config directory came across from the old
host with a password already set by hand, and nothing in the repo would have
noticed its absence: on fresh state syncthing comes up with a generated API key
and **no password at all**, bound to `0.0.0.0` and reachable from every bridge
in the list above. That mattered more than a login form normally does, because
syncthing's REST API is not a viewer — `/rest/config/folders` takes a
versioning block of type `external` with a `params.command` that syncthing
execs, and a folder rooted at `~/.ssh` writes `authorized_keys` as `hutao`, who
has passwordless sudo. The credential is now declarative, so it fails closed.

Subtracting the rest needs a **positive** source match. That used to need a
pinned subnet on `proxy`, and so a network recreation; the subnet is pinned now
(#43), so it is a rule change that has not been made yet.

One silent consequence of adding `ip saddr`: the rule is now **IPv4-only**,
where the bare version matched both families. That is free today because
docker's bridges here carry no IPv6, but turning on docker IPv6 would need an
`ip6 saddr !=` sibling or those three ports go dark over v6 with every other
check still passing.

## Tailscale

The tailnet interface is accepted **wholesale** on the input hook, which is how
the tailnet-only services (grafana, tempo, dozzle, pgbouncer, syncthing GUI)
are kept private — by the _absence_ of an internet rule, not by their bind
address. Several bind `0.0.0.0` and rely entirely on this.

That is also why door 3 is a policy file and not an nftables rule. **nftables
cannot tell tailnet peers apart**: every packet off `tailscale0` looks the same
to it, so "which peers may reach what" is a question this layer is structurally
unable to answer. `tofu/tailscale-policy.hujson` is the layer that can, and it
narrows the VPS to eleven ports for the owner account — 6432 and 4317/4318 are
no longer tailnet-reachable at all. See
[The tailnet policy](tailnet.md).

Tailscale SSH is **off** (`tailscale set --ssh=false`). With it on, tailscaled
owned port 22 on the tailnet address, and once split DNS sent `git.` there on
tailnet devices, git over ssh landed on Tailscale SSH instead of forgejo.
Administration, deploys and the runner's jump hop all use sshd on 2222 with an
ordinary key.

**sshd is on the tailnet address only.** It listens on `<tailnet address>:2222`
and nowhere else; on the public address, 2222 belongs to the tarpit, which
binds the public IPv4 alone. So off the tailnet 2222 trickles an endless
banner, and on it, it logs you in. Nothing filters this: each address simply
has one listener, and no firewall mistake can put sshd on the internet. Both
binds survive a boot where tailscaled is slow, because
`net.ipv4.ip_nonlocal_bind` lets them bind an address the box does not hold
yet. Off the tailnet the way in is the Hetzner console, where root and hutao
have passwords.

Three of those services also answer by name — `dozzle.`, `grafana.` and
`syncthing.` — and that is the same mechanism wearing a hat. Caddy runs a
**second listener** on `infra.tailnetHttpsPort` (8443) carrying those three
vhosts, **plus tailnet copies of `git.` and `status.`** with their admin paths
open (see [split DNS](tailnet.md#split-dns-for-the-half-public-names)); like
every other private port it is published on `0.0.0.0` and kept private by being
in neither allow-list.

What makes the URL portless is a `nat` prerouting chain:

```text
type nat hook prerouting priority -110; policy accept;
iifname tailscale0 meta nfproto ipv4 tcp dport 443 dnat ip to 172.18.0.2:8443
iifname tailscale0 meta nfproto ipv4 tcp dport 80  dnat ip to 172.18.0.2:8880
iifname tailscale0 meta nfproto ipv4 udp dport 443 dnat ip to 172.18.0.2:8443
# the same three as `redirect to :8443` / `:8880` for ipv6
```

**DNAT to caddy, not `redirect`, so caddy sees the client.** This chain used to
`redirect` to the host's own 8443. That delivered the connection to
`docker-proxy`, which owns the published port on the host and connects onward
to caddy from the bridge gateway, so every tailnet request reached caddy, its
access log and its rate limits as `172.18.0.1` (#43). A DNAT to caddy's pinned
address is forwarded into the bridge with the client's own source. It needs
caddy's address to be fixed, which is why the `proxy` network has a pinned
subnet. The forward chain's `iifname tailscale0 accept` admits it, and docker's
own filter admits it because 8443 and 8880 are ports caddy publishes.

IPv6 keeps the redirect: the docker networks have no IPv6, so docker-proxy is
the only way a v6 packet reaches caddy, and those requests still read
`172.18.0.1`. The tailnet names are A records, so nothing takes that path
unless someone types the v6 address.

The udp line is HTTP/3. The tailnet listener speaks it too (8443/udp is
published), and its sites advertise `h3=":443"` rather than caddy's default
`h3=":8443"`: udp 8443 sent directly over the tailnet did not get through when
measured, while udp 443 through the old redirect did. A browser that learned the
public listener's `h3=":443"` takes the same path once split DNS points `git.`
or `status.` at the tailnet address. Without the udp rule that traffic hung —
Forgejo's webpack chunk loads failed on it — and with docker's rule it would
reach the public listener, whose copies of those names close the admin paths.

**Known quirk, unexplained:** udp 8443 sent directly over the tailnet does not
reach caddy, while tcp 8443 direct and udp 443 through the redirect both did.
`docker port caddy` and `nft list ruleset | grep 8443` on the box are where to
start. **It matters again since #43:** udp 8443 direct is forwarded to the
container by docker's DNAT, and udp 443 is now forwarded the same way by ours,
where the redirect used to hand it to docker-proxy on the host. If whatever
drops the first also drops the second, HTTP/3 over the tailnet stops working.
Browsers fall back to TCP when QUIC fails, but the hang described above is the
symptom to watch for. One untested guess is the MTU: tailscale0 is 1280, and a
forwarded QUIC packet cannot be fragmented, where docker-proxy's own socket
could. The check after the migration is in
[Deploying](../operations/deploying.md#recreating-the-proxy-network-43).

Two details in those lines do all the work, and they are independent:

- **`iifname tailscale0`** is what keeps this off public traffic. A request
  arriving on the public interface never matches, so it falls through to
  docker's own prerouting and reaches caddy's ordinary `:443` listener exactly
  as it always did. This chain cannot affect a public vhost.
- **priority `-110`** is ten ahead of docker's `dstnat` at `-100`, and that
  ordering is the entire control. Both chains run on the same hook; the lower
  number runs first.

```mermaid
flowchart TB
    pkt["tcp dport 443"] --> iif{"which interface?"}

    iif -- "public" --> dn["docker dstnat -100<br/>ours never matched"]
    dn --> pub443["caddy :443<br/>public vhosts"] --> ok1(["200"])

    iif -- "tailscale0" --> prio{"our chain's<br/>priority?"}

    prio -- "-110, ahead ✓" --> rw["DNAT 443 → caddy:8443"]
    rw --> priv["caddy :8443<br/>tailnet vhosts"] --> ok2(["200"])

    prio -- "after -100 ✗" --> dn2["docker dstnat first"]
    dn2 --> pub443b["caddy :443<br/>public vhosts"] --> nf(["404<br/>no such site"])

    classDef bad fill:#8c2f2f,stroke:#4d1a1a,color:#fff
    classDef good fill:#1f6f43,stroke:#0d3a23,color:#fff
    class nf,dn2,pub443b bad
    class ok1,ok2,rw good
```

The right-hand branch is the **misconfiguration, not a second real path** —
there is no case in which a tailnet request legitimately lands on the public
listener. It is drawn because getting the priority wrong fails silently: the
packet is still delivered, caddy still answers, and the only symptom is a 404
on a name that resolves, from a box that is up, over a link that works.

The names are plain A records to the box's `100.x` address
(`tofu/modules/cloudflare-dns`). A CNAME to the node's MagicDNS name would
avoid that literal — the trap `modules/containers/tempo.nix` documents — but
Tailscale does not publish `<node>.<tailnet>.ts.net` in public DNS (verified
2026-09-17: empty answers from 1.1.1.1, 9.9.9.9 and 8.8.8.8), so it resolves
only on a device whose MagicDNS is active and fails silently on one where it is
not. The literal is the lesser failure: it goes stale only when the machine is
replaced, and it goes stale loudly. The certificate covers the names as
ordinary SANs, because DNS-01 never asks whether a name resolves publicly.

## Why there is no private network

The two machines had a Hetzner private network. It was deleted on 2026-09-19,
and the reasoning is worth keeping because the shape recurs:

- It had **one member**. A private network with a single host is a subnet, not
  a topology.
- **hcloud firewalls do not filter private traffic.** Door 1 simply does not
  exist on that interface.
- The VPS input chain accepts nine ports **with no `iifname` qualifier**, so
  every one of them was reachable from the private interface as readily as from
  the internet.

Together that is a standing bypass of two of the three doors, waiting for a
second member to make it exploitable. The runner reaches the VPS over ordinary
public HTTPS instead, where all three doors apply and Caddy can read the
request. See [CI runner isolation](runner.md).
