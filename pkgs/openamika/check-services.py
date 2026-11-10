"""Start the real services in a non-root, offline, read-only runtime namespace."""

import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback
import urllib.request

os.environ.update(json.loads(Path("/runtime-env.json").read_text()))
os.environ.update(OMP_NUM_THREADS="4", MKL_NUM_THREADS="4", USER="openamika",
                  LOGNAME="openamika", OPENROUTER_API_KEY="offline-test-placeholder")
assert os.getuid() == 1000004
assert not sys.stdout.isatty()
app = Path(os.environ["OPENAMIKA_APP"])
try:
    (app / "must-not-be-writable").write_text("test")
    raise AssertionError("app is writable")
except OSError as exc:
    assert exc.errno in (errno.EROFS, errno.EACCES)
# The tmpfs must be explicitly writable by the service uid, as on the VPS.
with open("/tmp/write-probe", "w") as handle:
    handle.write("test")

# Exercise the real launcher's mutable-state initialization, not a test copy.
subprocess.run([sys.argv[1], "check"], check=True, timeout=180)
assert Path(os.environ["TMPDIR"]).is_dir()
# Avoid background reflection attempts in this offline test; no real key exists.
config_path = Path("/data/config/build_f.json")
config = json.loads(config_path.read_text())
config["idle_reflection"] = False
config_path.write_text(json.dumps(config))

for name in ("model.pt", "config.yaml", "configuration.json", "am.mvn",
             "chn_jpn_yue_eng_ko_spectok.bpe.model", "tokens.json"):
    assert (app / "speech/models" / name).is_file(), name

spec = importlib.util.spec_from_file_location("launch", app / "launch.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)
cfg = json.loads(Path("/data/settings.json").read_text())
for holder in (cfg, cfg.get("embedder", {}), cfg.get("vision", {})):
    for key in ("brain_python", "speech_python", "python"):
        if holder.get(key):
            holder[key] = str(launch.resolve(holder[key]))
cores = launch.core_services(cfg, launch.embedder_settings(cfg), launch.vision_settings(cfg))
services = launch.configured_services(cfg)
tts = next(service for service in services if service.name == "tts")
started = []
try:
    # NLTK's Nix compatibility must not allow hardlinks in mutable storage.
    subprocess.run([str(app / "envs/voice/bin/python"), "-c", """
import os, pathlib
from nltk import pathsec
p = pathlib.Path('/data/.tmp/hardlink-test')
p.write_text('untrusted')
os.link(p, p.with_suffix('.alias'))
try:
    pathsec._hardened_open(str(p), 'r', 'smoke', str(p.parent))
except PermissionError:
    print('Mutable hardlinks still refused', flush=True)
else:
    raise AssertionError('mutable hardlink was trusted')
"""], check=True, timeout=60)
    # Match main(): configured services (TTS) start without waiting, then
    # core services start in order while tick also polls the earlier children.
    started.append(tts)
    tts.start()

    def tick():
        for child in started:
            child.poll()

    for service in cores:
        started.append(service)
        service.start()
        if not service.wait_up(tick=tick) and service.state != "timeout":
            raise RuntimeError(f"{service.name}: {service.state}: {service.detail}")
    if not tts.wait_up(tick=tick) and tts.state != "timeout":
        raise RuntimeError(f"tts: {tts.state}: {tts.detail}")
    # Like main(), continue after a startup timeout and poll late loaders.
    # 9p-backed VM store reads can be slower than native VPS bind mounts.
    deadline = time.monotonic() + 300
    while any(service.state == "timeout" for service in started) and time.monotonic() < deadline:
        tick()
        time.sleep(0.5)
    time.sleep(2)
    for service in started:
        service.poll()
        assert service.state in ("up", "external"), (service.name, service.state, service.detail)
        assert service.is_up(), (service.name, service.health)
        print(f"HEALTHY {service.name}: {service.health}", flush=True)
    # Exercise browser-facing avatar routes, including the resolved-file
    # containment checks. Registry discovery alone misses broken symlinks.
    base = "http://127.0.0.1:53000"
    with urllib.request.urlopen(base + "/api/avatar/models") as response:
        registry = json.load(response)
    models = registry["models"] if isinstance(registry, dict) else registry
    assert {model["id"] for model in models} >= {"Amika", "Host"}, models
    for model in models:
        with urllib.request.urlopen(base + model["model3_url"]) as response:
            doc = json.load(response)
        from urllib.parse import urljoin
        refs = doc["FileReferences"]
        paths = [refs["Moc"], *refs["Textures"]]
        paths += [refs[key] for key in ("Physics", "DisplayInfo") if refs.get(key)]
        paths += [item["File"] for group in refs.get("Motions", {}).values() for item in group]
        paths += [item["File"] for item in refs.get("Expressions", [])]
        for path in paths:
            with urllib.request.urlopen(urljoin(base + model["model3_url"], path)) as response:
                assert response.status == 200 and response.read(1), path
        for key in ("motions_url", "banks_url"):
            with urllib.request.urlopen(base + model[key]) as response:
                assert response.status == 200
        print(f"AVATAR {model['id']}: model, binaries, textures, motions and banks served", flush=True)
    print("All services healthy with read-only runtime closure, uid 1000004, writable /data and /tmp", flush=True)
except BaseException:
    traceback.print_exc()
    for logfile in sorted(Path("/data/logs").glob("*.log")):
        print(f"--- {logfile} (last 16 KiB) ---", flush=True)
        print(logfile.read_text(errors="replace")[-16384:], flush=True)
    raise
finally:
    for service in reversed(started):
        service.stop()
