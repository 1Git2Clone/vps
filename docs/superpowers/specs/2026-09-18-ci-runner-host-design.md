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

**The runner is not a container.** A plain `systemd.services.forgejo-runner`
unit runs it as an ordinary systemd service. On a dedicated host there is
nothing to isolate it *from*, so the containerised daemon buys nothing and
costs the socket mount that started this. No socket is mounted into anything,
because there is no "into". *(Not `services.gitea-actions-runner` — that
module's `ExecStartPre` calls the now-deprecated `forgejo-runner register`; see
Identity below.)*

**Jobs get a container engine on purpose.** `container.docker_host` changes from
`"-"` to podman's socket, which is the exact access the old allow-list existed
to deny. This is not a relaxation of the old position; it is the same position
applied to a different blast radius. A workflow that escapes on this box gets
root on a machine holding a nix store, an Actions cache and its own runner
token — no mail, no git, no sops key, no other service — and the box is a
snapshot away from replacement. The isolation boundary moved from the container
to the VM, which is what buying a second VM was for.

**Identity is declared, delivered per-instance.** *(Revised — see below.)* The
VPS runner is declared: a uuid+secret pair in config, no `.runner` state file,
nothing imperative. The first draft of this document argued that pattern was
right for exactly one permanent runner and impossible for N clones — a uuid
identifies exactly one runner record, two daemons claiming the same record is
undefined — and reached for a *registration token* instead, because a token
can be reused and each clone could self-register on first boot to get its own
record.

That reasoning is reversed here, because the primitive it leaned on is going
away: `forgejo-runner register` is DEPRECATED upstream (`forgejo-runner
register --help` says so in its first line, against the exact package this
flake builds). Building a new host around a call upstream is already walking
away from is the wrong trade even before it ships. The clone story does not
actually require register — it only requires the uuid to be a RUNTIME value
instead of a Nix one, which Hetzner user-data already had to supply for the
secret half regardless. So both halves of a declared identity now arrive
together, per instance, in user-data: a runner record is created by hand in
Forgejo for each clone (the one-time action `register` used to do on the
daemon's behalf), and `modules/runner/identity.nix` composes them into the
runtime config at boot. N clones still get N distinct identities; creating the
record moves from an automatic side effect of first boot to a manual step, and
nothing else about the clone story changes.

**The runner may not initiate anything toward the VPS.** Stated as a hard
requirement, so the rest of this document is written around it.

## Topology

```
hu-tao          163906050  cx43  fsn1  167.233.24.58   mail, git, everything
                                       2a01:4f8:c015:b138::/64
forgejo-runner  166488672  cx33  nbg1  46.225.61.172   CI only

  runner ──HTTPS 443──▶ 167.233.24.58        the one permitted direction
  runner ──╳── anything else on the VPS, v4 or v6
  VPS    ──SSH 22───▶ runner                 admin, permanently
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

### Why the runner is not on the tailnet either

The same argument, one layer up. `modules/firewall.nix`'s input chain accepts
`iifname tailscale0` unconditionally, so a tailnet member reaches every port on
the VPS — sshd on 2222, pgbouncer, tempo's OTLP receiver, the mail ports — and
no rule keyed on `167.233.24.58` sees that traffic at all. A runner on the
tailnet is a runner with full access to the box this document exists to protect.

Narrowing that accept to exclude one node is host-side filtering of a trust
boundary, which is the option rejected above, and tailscale ACLs are a third
control plane to keep correct. So the runner does not run tailscale.

The cost is that administration has no tailnet path, and the `tcp/22` ingress
rule scoped to `167.233.24.58/32` is therefore **permanent** rather than
bootstrap scaffolding. Admin is `ssh -J vps root@46.225.61.172`. That direction
is VPS→runner, which the one-way rule permits by construction.

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

*(Revised along with the section above — this mechanism replaced a
registration-token design after `forgejo-runner register` turned out to be
deprecated upstream.)*

A oneshot unit, ordered before the runner, reads the Hetzner metadata service
and composes the runner's config.yaml from what it finds — a uuid and secret,
not a token.

`services.gitea-actions-runner` is gone entirely from `modules/runner/
default.nix`: its `ExecStartPre` is what called the deprecated `register`
subcommand, so the module built around it went with it. What runs instead is a
plain `systemd.services.forgejo-runner` that execs `forgejo-runner --config
<path> daemon` directly, no registration step at any point in its lifecycle.

`default.nix` writes the STATIC half of config.yaml to the store — logging,
capacity, cache, the container engine settings, everything identical across
every clone. It deliberately omits `server:` entirely, because that section
holds the one thing that is NOT identical across clones: the uuid Forgejo
issued for this instance's runner record. `identity.nix` composes the real
file the daemon reads by prepending a `server.connections` block — built from
the uuid and secret it just validated — onto that static file, into the
runner's state directory (never the Nix store, which is world-readable and
therefore the one place a secret must never sit).

The user-data line has the shape:

```
forgejo-runner: <uuid> <secret>
```

whitespace-separated, uuid first, matching the order Forgejo displays them in
when a runner record is created. The metadata service is reachable on
link-local over the public NIC; the runner's egress allow-list already permits
`tcp/80`, which is what it uses.

**The endpoint is `/hetzner/v1/userdata`, not `/hetzner/v1/metadata/userdata`.**
The latter looks right, sits beside the keys that do work, and survived five
review rounds in the implementation — and it 404s. Probed against the live
instance 166488672:

| path | result |
|------|--------|
| `/hetzner/v1/metadata` | 200, the instance-id/hostname/network document |
| `/hetzner/v1/metadata/userdata` | **404** |
| `/latest/user-data` | 404 — no EC2-compatible alias on this service |
| `/hetzner/v1/userdata` | 204 with none set, 200 with |

The 204-when-unset is why `identity.nix` distinguishes a transport failure from
an empty body: "the service did not answer" must retry, and "it answered and has
nothing" is a provisioning error that retrying cannot fix.

### The secret must not be world-readable, and must not be in the store

Same constraint the token file faced, applied to one field instead of the
whole value: a Nix string is a world-readable store path, so the secret is
written outside the store, at runtime, and `config.yaml` references it with
`token_url: file://...` rather than embedding it — the same scheme
`modules/containers/forgejo-runner.nix` uses for the VPS's one permanent
runner, and for the same reason. It differs from the VPS's case in that there
is no sops involved at all — this host holds no key from this repo and can
decrypt nothing in `secrets.yaml`.

Not `install -m 0400`, though an earlier draft of this document said so: it is
written to a `mktemp` file in the SAME directory as its destination, `chmod`ed
and `chown`ed, then moved into place with `mv`. `install` copies into the
existing destination inode (open-and-truncate), which a reader that already
has the old file open — or a manual `systemctl restart
forgejo-runner-identity` racing the live daemon — can observe mid-write;
`mv` within one directory is a single `rename(2)`, so any reader sees the
complete old file or the complete new one, never a partial write. Same
directory is load-bearing: `mv` across filesystems falls back to
copy-then-unlink, exactly as non-atomic as `install`, and `/tmp` (where the
secret was briefly staged in an earlier version of this file) is routinely a
different filesystem from `/var/lib`.

### Validate before the daemon ever sees it

A malformed secret reaching the daemon is rejected as "token contains invalid
characters," and `Restart=on-failure` turns that into a crashloop — several
restarts deep before anyone reads the journal, indistinguishable at a glance
from a revoked credential. That is not hypothetical: it is what happened to
the VPS runner's declared identity on 2026-09-19. `identity.nix` checks the
uuid's shape (standard 8-4-4-4-12 hex) and the secret's (32+ alphanumeric
characters) before writing anything, and fails the unit — loudly, with a
message naming which field was wrong — rather than handing the daemon a value
that will fail three layers downstream. Neither value is ever echoed.

### One source: user-data, because user-data is per-server

`user_data` is server metadata, not image content. A box built from a snapshot
of the runner is a NEW server and serves its OWN user-data, so N clones of one
image come up as N distinct runners carrying no identity state between them.
That property is the whole design: it is what makes clone-safety structural
instead of procedural, and it needs no stamping, no provenance checks, and no
scrub step to hold.

An earlier version of this document specified a SECOND source — a file staged
by `nixos-anywhere --extra-files`, read when the metadata service had nothing —
for one reason: hcloud cannot attach `user_data` to a server that already
exists (the provider marks it replace-forces-new), and the first box had been
created in the console without any. That single workaround cost roughly 400
lines in `identity.nix`: the staged path itself, an `instance-id:` line to bind
the file to one machine, a persisted `instance-id` stamp to bind the derived
state the same way, and a reuse branch for the box whose own user-data would be
empty forever. Four consecutive adversarial review rounds each found a fresh
hole in it — a clone inheriting the source box's pair, then a fix that depended
on a manual scrub, then a staged path that laundered a stolen identity into a
self-consistent stamp, then a reuse branch that trusted `config.yaml`'s
contents.

**That entire mechanism is deleted.** `tofu/server.tf` sets `user_data` on
`hcloud_server.runner` from `var.runner_identity`, which replaces the box — an
empty box holding a nix store and an Actions cache, both caches by definition.
Recreating it once is cheaper than carrying the workaround, and none of those
four holes exist in code that is not there.

The cost, stated plainly: rotating the runner's secret now means replacing the
box, and the box's public IPv4 changes with it. Two places pin that address —
the `output`-chain rule in `modules/firewall.nix` and the ingress rule in
`tofu/runner-firewall.tf`.

Each declared record still has to be created in Forgejo by hand. Destroying a
clone does not delete it; stale records accumulate in Site Administration →
Actions → Runners and must be pruned by hand, or by the orchestrator if the
ephemeral follow-up is ever built.

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

1. Set `runner_identity` in `tofu/terraform.tfvars` to the line
   `forgejo-runner: <uuid> <secret>` and apply. `user_data` is
   replace-forces-new, so this destroys and recreates the box — intended, and
   the reason the whole staged-file mechanism above could be deleted. **The
   public IPv4 changes.** Update the `output`-chain rule in
   `modules/firewall.nix` and the ingress rule in `tofu/runner-firewall.tf` to
   the new address, and deploy the VPS, before the next step.
2. Install with nixos-anywhere, jumped through the VPS:
   `nixos-anywhere --flake .#runner-hetzner --ssh-option ProxyJump=vps root@<new ip>`.
   No `--extra-files`: this host holds no age key and stages no identity —
   everything per-instance arrives from the metadata service at boot. The
   private NIC was removed in 5d0ae14, so the target is the public address; the
   jump is what makes the runner's single ingress rule — `tcp/22` from
   `167.233.24.58/32` — sufficient.
3. Before imaging, delete `/var/lib/forgejo-runner/{config.yaml,token}`.

   NOT because it saves a failed boot — it does not. A clone created with its
   own user-data composes cleanly on its first boot whether or not the image
   carries the source box's stale state, because `identity.nix` reads user-data
   unconditionally and overwrites both files every time. The reason is
   credential hygiene: `token` is a LIVE, WORKING credential, valid against
   Forgejo until someone revokes it, and shipping one inside a disk image means
   every place that image is stored, copied or backed up also holds a working
   secret. Don't put a real key in a template, independent of whether the
   template would misuse it if you forgot.
4. Power off, snapshot.
5. A new runner is a server created from that snapshot with its own uuid+secret
   pair in `user_data`. No deploy, no flake change, no commit.

The snapshot carries a warm nix store, which is what keeps a fresh clone from
paying a cold build — and is the reason the ephemeral follow-up stays cheap if
it is ever built.

### config.yaml is derived, every boot — never trusted from a previous run

`container.docker_host` hands every job root-equivalent access to podman on
purpose (see "Jobs get a container engine on purpose" above), so a job that
escapes through it can rewrite anything on disk — `privileged: true`,
`valid_volumes: ["/"]` — including `config.yaml` itself. An adversarial review
round found an earlier draft that reused an existing `config.yaml` when its
identity checks passed, which would have let exactly that edit survive every
reboot and every `nixos-rebuild`, because nothing ever looked at the file again.

`config.yaml` is therefore a RENDER, not state. `identity.nix` recomposes it
unconditionally on every run, from the Nix-built static half
(`modules/runner/default.nix`) plus the uuid it just read out of user-data.
Tampering survives until the next boot and no longer, and a changed `capacity`,
`labels` or `docker_host` in Nix reaches the box the way everything else does.
The only file that persists between boots is `token`.

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
| `modules/runner/default.nix` | new; podman + a plain `systemd.services.forgejo-runner` |
| `modules/runner/identity.nix` | new; user-data → composed config.yaml + secret file |
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
only credential is the secret half of the uuid+secret pair in user-data, which
is visible to anyone with Hetzner console access and is scoped to the one
runner record it belongs to.

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
