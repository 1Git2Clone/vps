{
  pkgs,
  openamika,
  services,
}:
let
  fakeDocker = pkgs.writeShellScript "docker-record-args" ''
    printf '%s\0' "$@" > "$CAPTURE"
  '';
  wrapper = import ../pkgs/openamika/docker-wrapper.nix {
    inherit pkgs;
    docker = fakeDocker;
    closure = openamika.runtimeClosure;
  };
in
# The activator checks restartIfChanged before choosing the stopIfChanged
# stop/start vs restart path. The gateway must still follow normal updates.
assert !services.docker-openamika.restartIfChanged;
assert !services.docker-openamika.reloadIfChanged;
assert services.docker-openamika.stopIfChanged;
assert services.openamika-gateway.restartIfChanged;
pkgs.runCommand "openamika-runtime-mounts" { nativeBuildInputs = [ pkgs.python311 ]; } ''
  export CAPTURE="$TMPDIR/run-args"
  ${wrapper}/bin/docker run --name=openamika --read-only --cap-drop=ALL openamika-base:1
  python - ${openamika.runtimeClosure}/store-paths "$CAPTURE" <<'PY'
  import pathlib, sys
  closure = pathlib.Path(sys.argv[1]).read_text().splitlines()
  args = pathlib.Path(sys.argv[2]).read_bytes().decode().split('\0')[:-1]
  mounts = [arg for flag, arg in zip(args, args[1:]) if flag == '--mount']
  assert mounts == [f'type=bind,src={p},dst={p},readonly' for p in closure]
  assert args[0] == 'run'
  assert args[1+2*len(closure):] == ['--name=openamika', '--read-only', '--cap-drop=ALL', 'openamika-base:1']
  assert all(p.startswith('/nix/store/') and '/' not in p[len('/nix/store/'):] for p in closure)
  PY
  ${wrapper}/bin/docker load -i image.tar.gz
  python - "$CAPTURE" <<'PY'
  import pathlib, sys
  assert pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')[:-1] == [b'load', b'-i', b'image.tar.gz']
  PY
  python - ${openamika.image} <<'PY'
  import json, sys, tarfile
  with tarfile.open(sys.argv[1]) as archive:
      members = archive.getmembers()
      config = json.load(archive.extractfile(json.load(archive.extractfile('manifest.json'))[0]['Config']))
      assert not config['config'].get('Entrypoint')
      for member in members:
          if member.name.endswith('/layer.tar'):
              with tarfile.open(fileobj=archive.extractfile(member)) as layer:
                  assert all(item.isdir() for item in layer), 'base must contain only empty mount points'
  PY
  touch $out
''
