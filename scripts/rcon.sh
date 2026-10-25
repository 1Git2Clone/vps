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

# Everything below runs on the VPS, as root. It is one function so bash has
# read all of it before anything runs, and nothing else can eat the script.
main() {
  case $1 in
    mc1) w=minecraft ;;
    mc[0-9]*) w=minecraft${1#mc} ;;
    *) w=$1 ;;
  esac
  shift
  if ! systemctl cat "docker-$w.service" >/dev/null 2>&1; then
    echo "no world called $w" >&2
    exit 2
  fi

  woke=
  if [ "$(systemctl show -P ActiveState "docker-$w")" != active ]; then
    echo "$w is asleep, waking it" >&2
    systemctl start "docker-$w"
    # The cap of two, or a backup in progress, skips the start without failing.
    if [ "$(systemctl show -P ActiveState "docker-$w")" != active ]; then
      echo "$w did not start; journalctl -u docker-$w | grep minecraft-cap says why" >&2
      exit 1
    fi
    woke=1
    for _ in $(seq 90); do
      docker exec "$w" rcon-cli list >/dev/null 2>&1 </dev/null && break
      sleep 2
    done
  fi

  status=0
  docker exec "$w" rcon-cli "$@" </dev/null || status=$?

  if [ -n "$woke" ]; then
    systemctl stop "docker-$w"
    echo "$w is asleep again" >&2
  fi

  if [ "${1:-}" = whitelist ] && { [ "${2:-}" = add ] || [ "${2:-}" = remove ]; }; then
    # A world whose count cannot be read counts as someone online.
    online=0
    for unit in $(systemctl list-units --state=active --plain --no-legend 'docker-minecraft*' | cut -d' ' -f1); do
      world=${unit#docker-}
      # Not grep | head: under pipefail, head closing early fails the pipe.
      if [[ $(docker exec "${world%.service}" rcon-cli list </dev/null) =~ There\ are\ ([0-9]+) ]]; then
        online=$((online + BASH_REMATCH[1]))
      else
        online=$((online + 1))
      fi
    done
    if [ "$online" -gt 0 ]; then
      echo "someone may be online, so mc-router was not restarted; the change reaches it at its next restart" >&2
    else
      systemctl restart docker-mc-router
      journalctl -u docker-mc-router --since -1min --no-pager -o cat | grep allow-deny | tail -1 >&2 || true
    fi
  fi
  exit "$status"
}
shift
main "$@"
