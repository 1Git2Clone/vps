# Identity model

`modules/ids.nix` assigns uids/gids to services that run under their own
account, as `base (1_000_000) + offset`, from a hand-maintained **append-only**
table.

The base clears every allocator the host uses — system users, nixbld,
`DynamicUser`, subuid blocks — so nothing this repo assigns can ever collide
with something NixOS allocated. The ceiling (2097151) is the largest uid a
ustar/tar header can hold, which matters because these uids end up in restic
snapshots.

The numbers are **assigned, not hashed** from the service name. A hash becomes
immutable the moment the first file is written, and a rename then silently
orphans every file the old name owned.

Read `config.infra.serviceId.<name>`, never a literal — so `grep -rn serviceId`
finds every use.

Today only `caddy` has an id (offset 1). A group per id is created so
`security.acme` can chown the cert directory to `caddy` rather than to `acme`,
which is what lets the container read its certificate by group membership
instead of by a capability it drops.

## The runner's users are separate

`modules/runner/users.nix` is its own file rather than a shared import. The
runner holds no age key, so it has no sops-provisioned accounts; its
`forgejo-runner` user is a plain static system user, deliberately not
`DynamicUser`.

The reason is ordering: the uuid+secret pair has to be written by a unit that
runs **before** the daemon starts, and a dynamic uid does not exist until the
unit it belongs to starts. There would be no stable owner to chown the composed
config to ahead of time. See [CI runner isolation](runner.md#identity-and-why-it-is-not-a-nix-string).
