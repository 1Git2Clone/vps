"""Offline checks of the real launcher health gate and non-TTY progress logs."""

import contextlib
import importlib.util
import io
import sys
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("launch", sys.argv[1])
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)

# An HTTP response alone is insufficient: the embedder must report ok=true.
service = launch.Service("embedder", ["unused"], health="http://127.0.0.1:8011/health",
                         expect_ok=True, timeout=61)
launch.http_json = lambda url: {"ok": False}
assert not service.is_up()
launch.http_json = lambda url: {"ok": True}
assert service.is_up()
launch.http_json = lambda url: None

# Advance a fake monotonic clock; the test takes no wall-clock sleep or network.
clock = [1.0]
launch.time = SimpleNamespace(monotonic=lambda: clock[0],
                              sleep=lambda seconds: clock.__setitem__(0, clock[0] + 10))
service.state = "starting"
service.started_at = clock[0]
output = io.StringIO()
with contextlib.redirect_stdout(output):
    assert service.wait_up() is False
assert service.state == "timeout"
assert clock[0] <= 72
text = output.getvalue()
assert "waiting for http://127.0.0.1:8011/health; timeout 61s" in text
assert "still waiting" in text
assert "no answer after 61s" in text
print("launcher health timeout and non-TTY progress OK")
