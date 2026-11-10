# Pins copied from setup_tts.py, download_sensevoice.py and the voice manifest.
# bge-m3's setup uses snapshot_download without a revision; assets.json also
# pins that snapshot, using the Hub's LFS SHA256s and hashes of its small files.
{ pkgs, voice }:
let
  inherit (pkgs) lib;
  pins = lib.importJSON ./assets.json;
  fetch =
    url: hash:
    pkgs.fetchurl {
      inherit url;
      sha256 = hash;
    };
  hf =
    repo: rev: path: hash:
    fetch "https://huggingface.co/${repo}/resolve/${rev}/${lib.escapeURL path}" hash;
  link = path: file: ''
    mkdir -p "$out/$(dirname ${lib.escapeShellArg path})"
    ln -s ${file} "$out/"${lib.escapeShellArg path}
  '';
  # Build locally without substitution: personal-use terms were accepted by
  # the operator. Keep these outputs out of public cache upload jobs.
  private =
    drv:
    drv.overrideAttrs (_: {
      allowSubstitutes = false;
      preferLocalBuild = true;
    });
  voiceFiles =
    rev: files:
    lib.concatStrings (
      lib.mapAttrsToList (
        path: spec:
        let
          dest =
            if lib.hasPrefix "live2d/" path then
              "avatar/models/" + lib.removePrefix "live2d/" path
            else
              "vendor/tts-engine/Speakers/MekaHime_Amika/${path}";
        in
        lib.optionalString (path != ".gitattributes") (
          link dest (private (hf pins.VOICE_REPO rev path (builtins.elemAt spec 1)))
        )
      ) files
    );
  gptSource = pkgs.fetchzip {
    extension = "zip";
    url = "https://codeload.github.com/RVC-Boss/GPT-SoVITS/zip/${pins.GPT_SOVITS_COMMIT}";
    hash = "sha256-MkrI3cNBpT+HxbrHDxHAl7Kr4a50USO4xXzyxjjdxFU=";
  };
  g2pwZip = hf pins.G2PW_REPO pins.G2PW_REV (builtins.elemAt pins.G2PW_ZIP 0) (
    builtins.elemAt pins.G2PW_ZIP 2
  );
  gpt =
    pkgs.runCommand "openamika-gpt-sovits"
      {
        nativeBuildInputs = [
          pkgs.unzip
          pkgs.python311
        ];
      }
      ''
        cp -r ${gptSource} $out
        chmod -R u+w $out
        # Validate upstream's published tree digest, before adding models/patches.
        python - "$out" ${pins.GPT_SOVITS_TREE_SHA256} <<'PY'
        import hashlib, pathlib, sys
        root = pathlib.Path(sys.argv[1])
        lines = "".join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.relative_to(root).as_posix() + '\n'
                        for p in sorted(root.rglob('*')) if p.is_file())
        assert hashlib.sha256(lines.encode()).hexdigest() == sys.argv[2]
        PY
        ${lib.concatMapStrings (
          spec:
          link "GPT_SoVITS/pretrained_models/${builtins.elemAt spec 0}" (
            hf pins.PRETRAINED_REPO pins.PRETRAINED_REV (builtins.elemAt spec 0) (builtins.elemAt spec 2)
          )
        ) pins.PRETRAINED}
        unzip -q ${g2pwZip} -d "$out/GPT_SoVITS/text"
        echo "${builtins.elemAt pins.G2PW_ONNX 2}  $out/GPT_SoVITS/text/G2PWModel/g2pW.onnx" | sha256sum -c
        # The Japanese dictionary and Chinese pronunciation cache are generated at
        # build time; upstream otherwise writes them beside its read-only sources.
        export PYTHONPATH="$out/GPT_SoVITS:$out"
        ${voice}/bin/python - "$out" <<'PY'
        import hashlib, pathlib, sys
        import pyopenjtalk
        root = pathlib.Path(sys.argv[1]) / 'GPT_SoVITS/text/ja_userdic'
        pyopenjtalk.mecab_dict_index(str(root / 'userdict.csv'), str(root / 'user.dict'))
        (root / 'userdict.md5').write_text(hashlib.md5((root / 'userdict.csv').read_bytes()).hexdigest())
        from text.g2pw.g2pw import get_dict
        get_dict()
        PY
        ${link "GPT_SoVITS/pretrained_models/fast_langdetect/lid.176.bin" (
          fetch (builtins.elemAt pins.LANGID 0) (builtins.elemAt pins.LANGID 2)
        )}
      '';
  models = private (
    pkgs.runCommand "openamika-assets" { } ''
      mkdir -p $out
      ${voiceFiles pins.VOICE_REV pins.manifest.files}
      ${voiceFiles pins.PAPER_DOLL_REV pins.manifest.paper_doll.files}
      ${lib.concatStrings (
        lib.mapAttrsToList (
          path: spec:
          link "speech/models/${path}" (
            pkgs.fetchurl {
              urls =
                lib.optional (
                  path != "tokens.json"
                ) "https://huggingface.co/FunAudioLLM/SenseVoiceSmall/resolve/${pins.sensevoice_revision}/${path}"
                ++ [ "https://www.modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/${path}" ];
              sha256 = builtins.elemAt spec 1;
            }
          )
        ) pins.sensevoice
      )}
      ${lib.concatStrings (
        lib.mapAttrsToList (
          path: hash: link "embed/${path}" (hf "BAAI/bge-m3" pins.bge.revision path hash)
        ) pins.bge.files
      )}
    ''
  );
  nltk = pkgs.runCommand "openamika-nltk-data" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    mkdir -p $out
    ${lib.concatMapStrings (
      spec:
      let
        path = builtins.elemAt spec 0;
      in
      ''
        mkdir -p "$out/${builtins.dirOf path}"
        unzip -q ${fetch "https://raw.githubusercontent.com/nltk/nltk_data/${pins.NLTK_COMMIT}/packages/${path}" (builtins.elemAt spec 2)} -d "$out/${builtins.dirOf path}"
      ''
    ) pins.NLTK}
  '';
in
{
  inherit models gpt nltk;
}
