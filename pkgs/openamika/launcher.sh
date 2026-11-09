#!/usr/bin/env bash
# Container entrypoint. The image is stock python:3.11-slim; everything this
# needs is mounted read-only from the Nix store, and everything it writes goes
# to the openamika_data volume at $HOME.
set -euo pipefail
umask 077

# Exit 3: the operator has to act. The unit does not restart on it
# (RestartPreventExitStatus in modules/containers/openamika.nix).
needs_operator=3

state="$HOME"
exec 9>"$state/.launch.lock"
flock -n 9 || {
  echo 'OpenAmika is already running or being set up.' >&2
  exit 1
}

# The tree is copied, not run from the store: setup writes venvs, models and
# settings next to the code. A new pinned revision refuses to start rather
# than mixing two upstream trees under one set of venvs.
if [[ ! -e "$state/.nix-source" ]]; then
  if [[ -e "$state/launch.py" ]]; then
    echo "An unmanaged installation exists in the volume; move it aside first." >&2
    exit $needs_operator
  fi
  cp -r --no-preserve=mode "$OPENAMIKA_SOURCE"/. "$state/"
  printf '%s\n' "$OPENAMIKA_SOURCE" >"$state/.nix-source"
elif [[ $(cat "$state/.nix-source") != "$OPENAMIKA_SOURCE" ]]; then
  echo "OpenAmika source changed. Back up the openamika_data volume and move its contents aside before setting up the new version." >&2
  exit $needs_operator
fi

cd "$state"
python3 "$OPENAMIKA_CPU_COMPAT"
export CUDA_VISIBLE_DEVICES=""
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export DISABLE_SAFETENSORS_CONVERSION=true

case "${1:-run}" in
  setup)
    python3 "$OPENAMIKA_CONFIGURE"
    python3 scripts/setup_core.py --cpu --vision off
    # Upstream prompts for license acceptance unless the operator explicitly
    # supplies --accept-voice-license after reading the terms.
    exec python3 scripts/setup_tts.py --cpu --accept-voice-license
    ;;
  check)
    exec envs/brain/bin/python launch.py --check
    ;;
  run)
    if [[ ! -x envs/brain/bin/python ]]; then
      echo 'Not set up: run systemctl start docker-openamika-setup first.' >&2
      exit $needs_operator
    fi
    exec envs/brain/bin/python launch.py --no-browser
    ;;
  *)
    echo 'Usage: launcher.sh [run | setup | check]' >&2
    exit 2
    ;;
esac
