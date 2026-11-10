#!/usr/bin/env bash
# Only mutable defaults are initialized here. Code, environments and models
# are already built into the image; starting never installs or downloads.
set -euo pipefail
umask 077
exec 9>"$HOME/.launch.lock"
flock -n 9 || exit 1
mkdir -p "$HOME"/{brain,config,logs,memory_f,.cache,.tmp,avatar/stage,IoT/data}
# cp -n preserves edits; these are tiny editable configuration/persona files.
cp -rn --no-preserve=mode "$OPENAMIKA_DEFAULTS"/. "$HOME/"
export CUDA_VISIBLE_DEVICES=""
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1
export DISABLE_SAFETENSORS_CONVERSION=true
cd "$OPENAMIKA_APP"
case "${1:-run}" in
  check) exec envs/brain/bin/python launch.py --check ;;
  run) exec envs/brain/bin/python launch.py --no-browser ;;
  *) echo 'Usage: launcher.sh [run | check]' >&2; exit 2 ;;
esac
