# Upstream's server-only binary release: patch its ELF loader for Nix, never
# compile Rust. The matching client is pinned in nixos-dotfiles.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
}:
stdenvNoCC.mkDerivation {
  pname = "horizon-server-bin";
  version = "2026-10-30";

  src = fetchurl {
    url = "https://github.com/horizon-rust/horizon/releases/download/nightly-2026-10-30/horizon-server-linux-x86_64.tar.gz";
    hash = "sha256-o5uZ46X9ETGFiJS/M1/z2ok+egsxm+b/x6gG1whst2w=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 horizon-server "$out/bin/horizon-server"
    install -Dm755 horizon-engine "$out/bin/horizon-engine"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/horizon-server" --help > /dev/null
  '';

  meta = {
    description = "Horizon Minecraft 26.3 server, upstream prebuilt binaries";
    homepage = "https://playhorizon.dev";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "horizon-server";
  };
}
