# Exercise the actual locked environments offline, including native libraries
# and the voice server's upstream compatibility shims. No Docker is needed.
{
  pkgs,
  envs,
  source,
  assets,
}:
pkgs.runCommand "openamika-imports"
  {
    nativeBuildInputs = [ pkgs.ffmpeg-headless ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
    export NLTK_DATA=${assets.nltk}
    export NUMBA_CACHE_DIR="$TMPDIR/numba" MPLCONFIGDIR="$TMPDIR/matplotlib"
    export OMP_NUM_THREADS=1 MKL_NUM_THREADS=1
    ${envs.brain}/bin/python -c 'import flask, flask_socketio, google.genai; print("brain OK")'
    ${envs.speech}/bin/python -c 'import torch, torchaudio, funasr; assert torch.version.cuda is None; print("speech OK", torch.__version__)'
    ${envs.embed}/bin/python -c 'import torch, sentence_transformers; assert torch.version.cuda is None; print("embed OK", torch.__version__)'
    ${envs.voice}/bin/python - ${source}/vendor/tts-engine ${assets.gpt} <<'PY'
    import pathlib, sys
    sys.path.insert(0, sys.argv[1])
    import main
    main.prepare_upstream(pathlib.Path(sys.argv[2]))
    import torch
    from GPT_SoVITS.TTS_infer_pack.TTS import TTS
    assert torch.version.cuda is None
    print("GPT-SoVITS TTS OK", torch.__version__)
    PY
    ${envs.brain}/bin/python ${./check-startup.py} ${source}/launch.py
    touch $out
  ''
