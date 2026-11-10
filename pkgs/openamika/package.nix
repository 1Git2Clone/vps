{
  pkgs,
  pyproject-nix,
  uv2nix,
  pyproject-build-systems,
}:
let
  inherit (pkgs) lib;
  envs = lib.genAttrs [ "brain" "speech" "embed" "voice" ] (
    name:
    let
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./envs + "/${name}"; };
      pythonSet =
        (pkgs.callPackage pyproject-nix.build.packages { python = pkgs.python311; }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.default
              (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
              (final: prev: {
                crcmod = prev.crcmod.overrideAttrs (old: {
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
                });
                oss2 = prev.oss2.overrideAttrs (old: {
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
                });
                distance = prev.distance.overrideAttrs (old: {
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
                });
                antlr4-python3-runtime = prev.antlr4-python3-runtime.overrideAttrs (old: {
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
                });
                # Nix's immutable corpus files are hardlink-deduplicated.
                # Permit only root-owned, read-only store reads in NLTK.
                nltk = prev.nltk.overrideAttrs (old: {
                  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.patch ];
                  postInstall = (old.postInstall or "") + ''
                    patch -d $out/${pkgs.python311.sitePackages}/nltk -p1 < ${./nltk-readonly-store.patch}
                  '';
                });
                # The universal wheel uses ctypes discovery, which cannot find
                # libsndfile in a Nix closure. Bind it to the packaged library.
                soundfile = prev.soundfile.overrideAttrs (old: {
                  postInstall = (old.postInstall or "") + ''
                    substituteInPlace $out/${pkgs.python311.sitePackages}/soundfile.py \
                      --replace-fail "_find_library('sndfile')" "'${lib.getLib pkgs.libsndfile}/lib/libsndfile.so'"
                  '';
                });
                torchaudio = prev.torchaudio.overrideAttrs (old: {
                  buildInputs = (old.buildInputs or [ ]) ++ [ final.torch ];
                  preFixup = (old.preFixup or "") + ''
                    addAutoPatchelfSearchPath ${final.torch}/${pkgs.python311.sitePackages}/torch/lib
                  '';
                });
                numba = prev.numba.overrideAttrs (old: {
                  buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.tbb ];
                });
                jieba = prev.jieba.overrideAttrs (old: {
                  nativeBuildInputs =
                    (old.nativeBuildInputs or [ ]) ++ final.resolveBuildSystem { setuptools = [ ]; };
                });
              })
            ]
          );
    in
    pythonSet.mkVirtualEnv "openamika-${name}" workspace.deps.default
  );
  source = pkgs.callPackage ./. { };
  assets = import ./assets.nix {
    inherit pkgs;
    inherit (envs) voice;
  };
  settings = pkgs.writeText "openamika-settings.json" (
    builtins.toJSON (import ./settings.nix { inherit lib; })
  );
  defaults = pkgs.runCommand "openamika-defaults" { } ''
    mkdir -p $out/brain
    cp -r ${source}/config $out/config
    cp ${source}/brain/*.txt ${source}/brain/scenes.json $out/brain/
    cp ${settings} $out/settings.json
  '';
  app =
    pkgs.runCommand "openamika-app"
      {
        # The operator accepted the assets' personal-use terms, not cache publication.
        allowSubstitutes = false;
        preferLocalBuild = true;
      }
      ''
        cp -r ${source} $out
        chmod -R u+w $out
        mkdir -p $out/envs $out/avatar/models $out/speech/static
        ${lib.concatStrings (lib.mapAttrsToList (name: env: "ln -s ${env} $out/envs/${name}\n") envs)}
        ln -s ${assets.models}/embed $out/embed
        ln -s ${envs.voice} $out/vendor/tts-engine/.venv
        ln -s ${assets.gpt} $out/vendor/tts-engine/GPT-SoVITS
        ln -s ${assets.nltk} $out/vendor/tts-engine/nltk_data
        ln -s ${assets.models}/vendor/tts-engine/Speakers $out/vendor/tts-engine/Speakers
        rm -rf $out/speech/models
        ln -s ${assets.models}/speech/models $out/speech/models
        ln -s ${assets.models}/avatar/models/Amika $out/avatar/models/Amika
        ln -s ${assets.models}/avatar/models/Host $out/avatar/models/Host
        rm -rf $out/config
        ln -s /data/config $out/config
        ln -s /data/brain/.env $out/brain/.env
        ln -s /data/brain/memories $out/brain/memories
        ln -s /data/memory_f $out/memory_f
        ln -s /data/logs $out/logs
        ln -s /data/settings.json $out/settings.json
      '';
  launcher = pkgs.writeShellApplication {
    name = "openamika";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = builtins.readFile ./launcher.sh;
  };
  # This is the only root whose closure is exposed inside the container.
  # Environment paths carry string context so closureInfo includes all of them.
  runtimeEnvironment = {
    HOME = "/data";
    OPENAMIKA_APP = "${app}";
    OPENAMIKA_DEFAULTS = "${defaults}";
    PATH = lib.makeBinPath [
      pkgs.ffmpeg-headless
      pkgs.python311
      pkgs.coreutils
      pkgs.bash
    ];
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    NLTK_DATA = "${assets.nltk}";
    HF_HUB_OFFLINE = "1";
    TRANSFORMERS_OFFLINE = "1";
    HF_HUB_DISABLE_TELEMETRY = "1";
    NUMBA_CACHE_DIR = "/data/.cache/numba";
    MPLCONFIGDIR = "/data/.cache/matplotlib";
    PYTHONDONTWRITEBYTECODE = "1";
    PYTHONUNBUFFERED = "1";
    TMPDIR = "/data/.tmp";
    AMIKA_IOT_DATA_DIR = "/data/IoT/data";
  };
  runtime = pkgs.writeShellScriptBin "openamika-runtime" ''
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (key: value: "export ${key}=${lib.escapeShellArg value}") runtimeEnvironment
    )}
    exec ${launcher}/bin/openamika "$@"
  '';
  runtimeClosure = pkgs.closureInfo { rootPaths = [ runtime ]; };
  # No store paths in contents or config: even an entrypoint reference would
  # pull its closure into Docker's layers. oci-containers supplies entrypoint.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "openamika-base";
    tag = "1";
    extraCommands = ''
      mkdir -p etc nix/store opt data tmp
      chmod 1777 tmp
    '';
    config = { };
  };

in
{
  inherit
    envs
    source
    assets
    settings
    defaults
    app
    runtime
    runtimeClosure
    runtimeEnvironment
    ;
  smoke = import ./smoke.nix {
    inherit
      pkgs
      envs
      source
      assets
      ;
  };
  inherit image;
}
