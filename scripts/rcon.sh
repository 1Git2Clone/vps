#!/usr/bin/env bash
# A world's console from your machine, over ssh:
#
#   scripts/rcon.sh mc4 whitelist add <name>
#   scripts/rcon.sh mc1 list
#
# Worlds are mc1 to mc4, or their container names. ssh uses whatever
# SSH_AUTH_SOCK you have. A sleeping world is woken for the command and put
# back to sleep after it. A whitelist change also restarts mc-router, which
# reads who may wake a world only at start, unless someone is online: the
# restart would drop them, so it says so and leaves it to you.
#
# The script runs itself on the VPS: this side only ships it over ssh.
set -euo pipefail

if [ "${1:-}" != --remote ]; then
  if [ $# -lt 2 ]; then
    echo "usage: $0 <mc1..mc4> <command...>" >&2
    exit 2
  fi
  exec ssh -p 2222 hutao@vps "sudo bash -s -- --remote $(printf '%q ' "$@")" <"$0"
fi

# Everything below runs on the VPS, as root. The functions are all defined
# before main runs, so bash has read the whole script before anything in it
# could read stdin and eat the rest.

# rcon <world> <command...>
rcon() { docker exec "$1" rcon-cli "${@:2}" </dev/null; }
is_up() { [ "$(systemctl show -P ActiveState "docker-$1")" = active ]; }

# mc1 is the container "minecraft", mcN is "minecraftN", anything else is
# taken as a container name.
container_for() {
  case $1 in
    mc1) echo minecraft ;;
    mc[0-9]*) echo "minecraft${1#mc}" ;;
    *) echo "$1" ;;
  esac
}

wake() {
  echo "$world is asleep, waking it" >&2
  systemctl start "docker-$world"
  # The cap of two, or a backup in progress, skips the start without failing.
  if ! is_up "$world"; then
    echo "$world did not start; journalctl -u docker-$world | grep minecraft-cap says why" >&2
    exit 1
  fi
  # RCON answers once the server is ready; up to three minutes.
  for _ in $(seq 90); do
    rcon "$world" list >/dev/null 2>&1 && return
    sleep 2
  done
}

put_back_to_sleep() {
  systemctl stop "docker-$world"
  echo "$world is asleep again" >&2
}

# Players on every world that is up. A world whose count cannot be read
# counts as one, so an unknown never reads as "nobody is on".
players_online() {
  local total=0 unit world
  for unit in $(systemctl list-units --state=active --plain --no-legend 'docker-minecraft*' | cut -d' ' -f1); do
    world=${unit#docker-}
    world=${world%.service}
    # A regex, not grep | head: under pipefail, head closing early fails the pipe.
    if [[ $(rcon "$world" list 2>/dev/null) =~ There\ are\ ([0-9]+) ]]; then
      total=$((total + BASH_REMATCH[1]))
    else
      total=$((total + 1))
    fi
  done
  echo "$total"
}

# mc-router reads who may wake a world only at start. The restart drops
# everyone connected, so it waits for an empty server.
reload_allowlist() {
  if [ "$(players_online)" -gt 0 ]; then
    echo "someone may be online, so mc-router was not restarted; the change reaches it at its next restart" >&2
    return
  fi
  systemctl restart docker-mc-router
  journalctl -u docker-mc-router --since -1min --no-pager -o cat | grep allow-deny | tail -1 >&2 || true
}

main() {
  world=$(container_for "$1")
  shift
  if ! systemctl cat "docker-$world.service" >/dev/null 2>&1; then
    echo "no world called $world" >&2
    exit 2
  fi

  local woke='' status=0
  if ! is_up "$world"; then
    wake
    woke=1
  fi
  rcon "$world" "$@" || status=$?
  if [ -n "$woke" ]; then
    put_back_to_sleep
  fi

  if [ "${1:-}" = whitelist ] && { [ "${2:-}" = add ] || [ "${2:-}" = remove ]; }; then
    reload_allowlist
  fi
  exit "$status"
}

shift # --remote
main "$@"
