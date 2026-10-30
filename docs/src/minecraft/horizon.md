# Horizon trial server

Join **`horizon.hu-tao.dev`** with Minecraft Java 26.3 or the matching Horizon
client. This is a separate vanilla world: the four Fabric worlds and their
modpacks keep their own addresses and data.

The client is installed by `nixos-dotfiles` as **Horizon**. Use its launcher,
sign in with a Microsoft account that owns Java Edition, then add the server
address in Multiplayer. Java/Fabric mod jars do not run in Horizon.

## Version and access

Both sides use the upstream **`nightly-2026-10-30`** game binaries, commit
`587f81f9c69629e999584f30aae0c9edacfc1b1d`. The client's launcher is a separate
package. Nix patches the Linux binaries' loaders; it does not compile Rust.

`packages/horizon-server.nix` pins the server archive by SHA-256. To update,
choose a dated release, verify its checksum against upstream's `SHA256SUMS`,
and update the matching client pin in `nixos-dotfiles`. The running server
does not update itself: rebuild the image and deploy the reviewed change.

The server uses **online mode, a whitelist, and an enforced whitelist**.
Minecraft account authentication happens at Horizon, after mc-router forwards
the connection. **Only the owner's account is allowed and is an operator.**
The private policy files under `/var/lib/horizon/access` are authoritative:
`whitelist.json` and `ops.json` must each contain exactly one entry with the
same account UUID. They are validated and copied into the data volume on
every start. No access list is inherited from another world, including during
recovery. Names, UUIDs and game-derived resources stay out of the public
repository and Nix store.

The server is always on and outside the two-Fabric-world cap. A local native
smoke test on 2026-10-31 settled at roughly 290 MiB engine RSS with no players;
after deployment, Docker reported roughly 252 MiB idle container memory and
the game reached `Done` in three seconds. These are idle measurements, not a
multiplayer capacity benchmark. The
container has a separate **2 GiB memory limit**. Review memory under real play
before increasing the limit or treating this as a production replacement.

## Deployment and private resources

`modules/containers/horizon.nix` builds a Docker image from the pinned native
binaries. It joins the existing Minecraft bridge; it publishes no host ports.
`mc-router` routes `horizon.hu-tao.dev:25565` to `horizon:25565`, so neither a
new public firewall port nor an SRV record is needed. OpenTofu owns its
unproxied A record.

The prepared 26.3 game files live in `/var/lib/horizon/resources`, mounted
read-only at `/resources`. Prepare them with the matching Horizon release
against your owned Minecraft 26.3 installation, then transfer them privately
over SSH. Keep all files together, including `horizon-resources.json`,
`registries.json`, `commands.json`, and the exported world-generation data.
The host directory is owned by root, readable by the `horizon` service group.
A missing preparation fails the service before the game starts.

Build and deploy:

```sh
nix build .#horizon-server .#horizon-image
deploy .#vps
```

The new DNS record must exist before clients can resolve the hostname. Review
the saved OpenTofu plan before applying it; adding this service requires only
the Horizon A record, not a server replacement or a primary-IP change.

## Administration and backups

World data and configuration live in the named Docker volume `horizon_data`.
The module rewrites `server.toml` at each start, so persistent server settings
belong in Nix. The whitelist and operators come from the private owner-only
policy above. CLI access-list changes last until the next restart; permanent
changes require editing the private policy, which is backed up daily:

```sh
ssh -p 2222 hutao@vps 'sudo docker logs --tail 100 horizon'
ssh -p 2222 hutao@vps 'sudo docker exec horizon horizon-server status --json'
ssh -p 2222 hutao@vps 'sudo docker exec horizon horizon-server whitelist list'
ssh -p 2222 hutao@vps 'sudo docker exec horizon horizon-server cmd list'
ssh -p 2222 hutao@vps 'sudo docker stats --no-stream horizon'
```

The container's `PATH` includes the packaged CLI. The management panel binds
only loopback **inside the container**, and is never published. Use the CLI
over SSH for administration.

Upstream takes local backups every six hours and keeps twelve. The existing
weekly Minecraft restic job also stops Horizon, snapshots `horizon_data`, and
restarts it if it was up. The daily job excludes that live volume and backs up
the privately prepared resources under `/var/lib/horizon` instead. This gives
off-box recovery of both the world and the exact resources needed to run it.

The official [hosting guide](https://playhorizon.dev/docs/hosting) and
[source](https://github.com/horizon-rust/horizon) describe the upstream tools.
