# The CI runner as its own host

`forgejo-runner` moves off the VPS onto a dedicated box, stops being a
container, stops using docker, and is rebuilt so that N identical copies can be
cloned from one snapshot.

The immediate cause is dated. At 18:56:48 on 2026-09-18 a `nix eval` step in
task 374 pushed the VPS past 15 GB and the kernel's OOM killer shot minecraft's
JVM — 4.6 GB resident, the fattest thing standing still. The eval itself was not
a hog: measured, the two CI eval steps peak at **668 MB** and **732 MB** RSS.
Nothing was runaway. The box was simply full, and `oom_badness()` scores a
snapshot of `rss + swap + pgtables` with no notion of who caused the spike, so
the biggest idle process loses by construction.

That is a capacity story, and capacity alone would have justified nothing more
than a bigger box. The reason this is a rebuild rather than a rescale is the
second thing the incident surfaced: `modules/containers/forgejo-runner.nix`
mounts `/var/run/docker.sock` and adds itself to the docker group, so the runner
daemon has root-equivalent access to the machine that also serves mail, git and
every sops secret. The module's header argues that trade honestly and the
mitigations hold — `docker_host: "-"`, a one-entry `valid_volumes` allow-list,
`privileged: false`, registration disabled. But every one of them is a lock
placed *around* a primitive that should not have been on that machine.

## Why the shape is what it is

Four decisions, taken deliberately, each reversing something that was correct in
the old context and is not in the new one.

**The runner is not a container.** `services.gitea-actions-runner` runs it as an
ordinary systemd service. On a dedicated host there is nothing to isolate it
*from*, so the containerised daemon buys nothing and costs the socket mount that
started this. No socket is mounted into anything, because there is no "into".

**Jobs get a container engine on purpose.** `container.docker_host` changes from
`"-"` to podman's socket, which is the exact access the old allow-list existed
to deny. This is not a relaxation of the old position; it is the same position
applied to a different blast radius. A workflow that escapes on this box gets
root on a machine holding a nix store, an Actions cache and its own runner
token — no mail, no git, no sops key, no other service — and the box is a
snapshot away from replacement. The isolation boundary moved from the container
to the VM, which is what buying a second VM was for.

**Identity is registered, not declared.** The VPS runner is declared: uuid and
secret in config, no `.runner` state file, nothing imperative. That is right for
one permanent runner and impossible for N clones, because a uuid identifies
exactly one runner record and two daemons claiming one record is undefined.
A *registration token* can be reused, so each clone self-registers on first boot
and gets its own record. The token arrives in Hetzner user-data, which is also
the primitive an ephemeral orchestrator would mint through the API later.

**The runner may not initiate anything toward the VPS.** Stated as a hard
requirement, so the rest of this document is written around it.

## Topology

```
hu-tao          163906050  cx43  fsn1  167.233.24.58   mail, git, everything
forgejo-runner  166488672  cx33  nbg1  46.225.61.172   CI only

  runner ──HTTPS 443──▶ git.hu-tao.dev        the one permitted direction
  runner ──╳── anything else on the VPS
  VPS    ──SSH 22───▶ runner                  admin, and the pages pull
```

`hcloud_network.main` (12666492, `10.0.0.0/16`) and its `10.0.1.0/24` subnet
stay, with the VPS attached at `10.0.1.2` for a future trusted box.
**`hcloud_server_network.runner` is removed.** It was created on 2026-09-18 and
is inert only because neither host has the private interface configured yet.

### Why the private NIC goes rather than gets filtered

Hetzner cloud firewalls filter the public interface only. Private-network
traffic is never inspected, and Hetzner offers no ACLs, security groups or route
policy for it. There is no cloud-level control over that path at all — the only
cloud-level control is binary: attached, or not.

Filtering it host-side was the alternative and it is the weaker one, because
`modules/firewall.nix` currently reads:

```nft
tcp dport { 22, 25, 80, 443, 465, 587, 993, 25565, 25566 } ct state new accept
```

with no `iifname`. The moment a private interface comes up on the VPS, nine
ports on the mail server accept new connections from `10.0.1.3`. Correcting that
rule is worth doing regardless (see VPS-side changes), but "one edit away from
silently reopening" is not the property to build a trust boundary on when
"the NIC does not exist" is available for free.

### What no firewall closes

Two paths survive by construction and are accepted, not mitigated:

1. **The runner must reach Forgejo.** That is its function. The A records are
   `proxied = false`, so it is a direct TCP connection to `167.233.24.58:443`,
   authenticated as a runner, terminating at caddy. It cannot reach sshd,
   postfix or postgres, but "no interaction whatsoever" is not achievable while
   the machine is a runner for that instance.
2. **Per-job tokens.** Forgejo hands every job a token scoped to the repo being
   built. A compromised runner sees every token that passes through it and can
   push to those repos. No network control touches this. The mitigations are
   Forgejo-side: default Actions token permissions to read-only, and accept that
   "runner compromised ⇒ attacker can write to repos it built". If that is
   unacceptable for a repo, the answer is not to build that repo here.

## Identity — `modules/runner/identity.nix`

A oneshot unit, ordered before the runner, reads the Hetzner metadata service
and writes the registration token to a file the runner consumes via `tokenFile`.

The metadata endpoint is reachable on link-local over the public NIC; the
runner's egress allow-list already permits `tcp/80`, which is what it uses.

### The token file must not be world-readable, and must not be in the store

Same constraint as `forgejo-runner.nix`'s existing `tokenFile` dance: a Nix
string is a world-readable store path, so the token is written at runtime with
`install -m 0400` to a path outside the store. It differs from the VPS's case in
that there is no sops involved at all — this host holds no key from this repo
and can decrypt nothing in `secrets.yaml`.

### A clone leaves a record behind

Each registration creates a runner record in Forgejo. Destroying a clone does
not delete it; stale records accumulate in Site Administration → Actions →
Runners and must be pruned by hand, or by the orchestrator if the ephemeral
follow-up is ever built.

## The runner host — `modules/runner/`

### podman, and the DNS trap that is the same trap as before

```nix
virtualisation.podman = {
  enable = true;
  dockerSocket.enable = true;   # /run/docker.sock compat
  dockerCompat = true;          # `docker` as an alias binary
  autoPrune.enable = true;
  defaultNetwork.settings.dns_enabled = true;
};
```

`dns_enabled` is load-bearing and is the podman spelling of the lesson already
written into `forgejo-runner.nix`'s `container.network: ""` comment: a network
without embedded DNS makes a workflow's `services:` unresolvable, and the
failure is not an error but a wait loop burning its full timeout.

`dockerSocket` and `dockerCompat` are what make `docker` work inside a job
without any workflow change — which was the requirement.

### Runner settings

Mirrors the live VPS config except where noted:

| setting | value | note |
| --- | --- | --- |
| labels | `nix`, `ubuntu-latest`, `node-22`, `alpine` | unchanged, so no workflow edits |
| `capacity` | 2 | 4 vCPU at cx33; was going to be 1 at cx23 |
| `timeout` | 30m | unchanged |
| cache | enabled, `/var/lib/.../cache` | the 375s-vs-15s cargo case |
| `container.network` | `""` | per-job network, as today |
| `container.privileged` | false | unchanged |
| `container.valid_volumes` | empty | the pages volume is gone from this box |
| `container.docker_host` | podman's socket | **changed**, deliberately |

## One-way enforcement — `modules/runner/firewall.nix`

Cloud level does the structural half (no private NIC; ingress is one rule,
`tcp/22` from `167.233.24.58/32`, itself removable once admin moves elsewhere).
The host ruleset does the rest:

```nft
ip daddr 167.233.24.58 tcp dport 443 accept
ip daddr 167.233.24.58 drop
```

### This belongs in `forward`, not only `output`

Job containers have their own network namespace. Their packets are **forwarded**
by the host, never emitted by it, so an `output`-only rule is bypassed by every
container on the box — which is precisely the shape of the forward-chain problem
this infrastructure has already been bitten by once. The rule goes in both
chains, and the check for it is a job that tries to reach a non-443 port on the
VPS and fails.

## Disk and GC

80 GB, and still the most likely thing to page someone. A nix store, the job
images, a cargo registry and the Actions cache all grow and nothing prunes them
by default. `nix.gc.automatic`, `nix.optimise.automatic` and
`virtualisation.podman.autoPrune` are part of the host config from the first
boot, not added after the first ENOSPC.

## Snapshot and replication

1. Install with nixos-anywhere, jumped through the VPS
   (`--ssh-option ProxyJump=vps`), which is why the runner's single ingress rule
   is scoped to `167.233.24.58/32` and the VPS gained one scoped `tcp/22` egress
   rule.
2. Power off, snapshot.
3. A new runner is a server created from that snapshot with a registration token
   in user-data. No deploy, no flake change, no commit.

The snapshot carries a warm nix store, which is what keeps a fresh clone from
paying a cold build — and is the reason the ephemeral follow-up stays cheap if
it is ever built.

## VPS-side changes

- Remove `modules/containers/forgejo-runner.nix`, its import, its sops secret,
  its `forgejo-runner-token` and `forgejo-runner-ready` units, and the published
  cache-proxy port.
- Bind the nine port-accepts in `modules/firewall.nix` to the public interface.
  Correct independently of this work.
- Add the pages pull: the pages job uploads its output as an artifact, and a
  timer on the VPS fetches it into the pages volume. Every connection is
  VPS-initiated, so it respects the one-way rule; the runner never writes to the
  VPS.

## Files

| path | change |
| --- | --- |
| `tofu/network.tf` | remove `hcloud_server_network.runner` |
| `flake.nix` | `mkRunner`, `nixosConfigurations.runner-hetzner`, deploy node |
| `runner/configuration.nix` | new; imports the shared four plus runner modules |
| `modules/runner/default.nix` | new; podman + `gitea-actions-runner` |
| `modules/runner/identity.nix` | new; user-data → token file |
| `modules/runner/firewall.nix` | new; one-way rules, forward and output |
| `modules/runner/users.nix` | new; ssh keys only, no sops passwords |
| `modules/firewall.nix` | bind port-accepts to the public interface |
| `modules/containers/forgejo-runner.nix` | deleted |
| `configuration.nix` | drop the runner import |

Shared unchanged: `modules/nix.nix`, `modules/boot.nix`, `modules/hardware.nix`,
`modules/security.nix`, and `disk-config.nix` — the last is already generic
(`device = lib.mkDefault "/dev/vda"`, root at `100%`), so the runner takes it
verbatim with the same `/dev/sda` override `vps-hetzner` uses. No second disko
file is needed and the 80 GB is picked up without a line changing.

### Secrets

The runner host holds **no secret from this repo**. `.sops.yaml` is untouched,
no age key is provisioned there, and `secrets.yaml` does not decrypt on it. Its
only credential is the registration token in user-data, which is visible to
anyone with Hetzner console access and is scoped to registering runners.

## Out of scope

Recorded because they were discussed and deliberately deferred, and because
neither changes anything above:

- **Ephemeral per-run boxes.** Create, run one job, destroy. Strictly additive:
  same image, same user-data identity. Costs an orchestrator polling Forgejo for
  queued tasks and an hcloud token on the VPS that can destroy servers — a
  bigger secret than anything this design puts on the runner.
- **Nightly destroy and recreate.** The cheap 80% of the above: bounds a host
  compromise to 24h for one timer's worth of code, caches surviving in the
  image.
- **Minecraft.** Untouched. Both servers keep their `MEMORY = "6G"`/`"4G"`,
  which commit `Xms = Xmx` up front and are why the box was full. Splitting
  those bounds, or lazymc, remains available and unrelated to this work.
