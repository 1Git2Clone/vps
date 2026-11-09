# Upstream's server-only binary release: patch its ELF loader for Nix, never
# compile Rust. Use the stable server tag and verify its release asset digest.
{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
}:
stdenvNoCC.mkDerivation {
  pname = "horizon-server-bin";
  version = "0.2.97";

  src = fetchurl {
    url = "https://github.com/horizon-rust/horizon/releases/download/v0.2.97/horizon-server-linux-x86_64.tar.gz";
    hash = "sha256-V0IttGUz4HcnfvFQXcwDgF1S0V86ITIAVpEYw2xffMk=";
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
