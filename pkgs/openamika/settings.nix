{ lib }:
lib.recursiveUpdate (lib.importJSON ./settings.example.json) {
  brain_python = "envs/brain/bin/python";
  speech_python = "envs/speech/bin/python";
  speech_device = "cpu";
  embedder = {
    python = "envs/embed/bin/python";
    model = "/opt/openamika/embed";
    device = "cpu";
    dtype = "fp32";
  };
  vision = {
    python = "envs/vision/bin/python";
    device = "cpu";
    enabled = false;
  };
  services.tts = {
    command = [
      "vendor/tts-engine/.venv/bin/python"
      "main.py"
      "--host"
      "127.0.0.1"
      "--port"
      "8002"
      "--character"
      "MekaHime_Amika"
      "--device"
      "cpu"
      "--no-half"
      "--cache-dir"
      "/data/.cache/tts"
    ];
    cwd = "vendor/tts-engine";
    timeout_s = 900;
  };
}
