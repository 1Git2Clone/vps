"""Initialize the Linux CPU settings once; preserve subsequent UI edits."""

import json
from pathlib import Path

path = Path("settings.json")
if not path.exists():
    settings = json.loads(Path("settings.example.json").read_text())
    settings["brain_python"] = "envs/brain/bin/python"
    settings["speech_python"] = "envs/speech/bin/python"
    settings["speech_device"] = "cpu"
    settings["embedder"].update(
        python="envs/embed/bin/python", device="cpu", dtype="fp32"
    )
    settings["vision"].update(
        python="envs/vision/bin/python", device="cpu", enabled=False
    )
    settings["services"]["tts"].update(
        command=[
            "vendor/tts-engine/.venv/bin/python",
            "main.py",
            "--host",
            "127.0.0.1",
            "--port",
            "8002",
            "--character",
            "MekaHime_Amika",
            "--device",
            "cpu",
            "--no-half",
        ],
        cwd="vendor/tts-engine",
        timeout_s=900,
    )
    path.write_text(json.dumps(settings, indent=2) + "\n")

# This is already the pinned upstream preset. Explicitly retain CPU-local
# embeddings rather than charging OpenRouter for memory searches.
roles_path = Path("config/llm_roles.json")
roles = json.loads(roles_path.read_text())
roles["embedding_openrouter"] = False
roles["selections"] = {
    "deep": "deep:z-ai/glm-5#no-reasoning",
    "surface": "surface:deepseek/deepseek-v4.1-flash",
    "reflection": "reflection:deepseek/deepseek-v4.1-flash",
    "memory_write": "memory_write:z-ai/glm-5.3",
}
roles_path.write_text(json.dumps(roles, ensure_ascii=False, indent=2) + "\n")
