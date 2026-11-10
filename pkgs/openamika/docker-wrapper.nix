# Service-local Docker shim: keep oci-containers' generated flags and lifecycle,
# adding only exact read-only runtime-closure binds to `docker run`.
{
  pkgs,
  docker,
  closure,
}:
pkgs.writeShellScriptBin "docker" ''
  set -euo pipefail
  if [[ "''${1:-}" == run ]]; then
    shift
    mounts=()
    while IFS= read -r storePath; do
      [[ "$storePath" == /nix/store/* && -e "$storePath" ]] || exit 3
      mounts+=(--mount "type=bind,src=$storePath,dst=$storePath,readonly")
    done < ${closure}/store-paths
    exec ${docker} run "''${mounts[@]}" "$@"
  fi
  exec ${docker} "$@"
''
