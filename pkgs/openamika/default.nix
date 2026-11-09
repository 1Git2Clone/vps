# The pinned upstream tree, patched. Nothing is built: the container mounts
# this read-only and pip-installs the Python environments into its volume on
# first setup (modules/containers/openamika.nix).
{ stdenvNoCC, fetchFromGitHub }:
let
  revision = "c3d71694cfb465fe6353a294f3623e010331e361";
in
stdenvNoCC.mkDerivation {
  pname = "openamika-source";
  version = builtins.substring 0 8 revision;
  src = fetchFromGitHub {
    owner = "Kaminoikari";
    repo = "OpenAmika";
    rev = revision;
    hash = "sha256-vyxsw4EQzDPq/vLldk9Zx2okKylrTW4ke7LM2V73WQU=";
  };
  patches = [
    # The transports already use the environment; make the setup UI and
    # preflight recognize the sops key without writing it into brain/.env.
    ./environment-key.patch
    # launch.py pins the web UI to 127.0.0.1, which inside a container is
    # unreachable from the host. Only the UI moves; speech, voice and the
    # embedder stay on the container's loopback.
    ./ui-host.patch
  ];
  dontBuild = true;
  installPhase = ''
    mkdir -p $out
    cp -r . $out/
  '';
}
