# 2026-09-16 — a dependency window that took the box down for six minutes

**Impact:** ~5m44s, 22:19:55–22:25:39 EEST. Every service except the two
minecraft worlds was down, mail included.
**Trigger:** a `nix flake update` deploy.
**Root cause:** a known, documented, deferred missing ordering dependency on
`docker-forgejo-runner.service`.
**Detected by:** `kuma-check`, correctly, within 13 seconds of its next tick.

---

## 1. What we set out to do

Clear all seven pending items on the Renovate Dependency Dashboard (#12) inside
one 30-minute maintenance window: three container bumps, one container _major_
(docker-mailserver 15.1.0 → 16.0.1), `lockFileMaintenance`, and two tofu
provider bumps.

Six of the seven landed. The seventh took the box down on its way in.

## 2. Timeline

All times EEST. The box logs UTC; subtract three hours.

| Time     | Event                                                                                                                                          |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 22:00:40 | Cold-stop grafana + navidrome. Local tar, then restic `a3534fdf`.                                                                              |
| 22:02:44 | **Deploy 1** (gen 58): dozzle v11.1.0, grafana 13.2.2, navidrome 0.64.0. Clean, 40s.                                                           |
| 22:11:24 | Cold-stop mail. Local tar, then restic `63564755`.                                                                                             |
| 22:12:43 | **Deploy 2** (gen 59): docker-mailserver 16.0.1 + the opendkim gid fix. Clean, 37s.                                                            |
| 22:16:39 | **Deploy 3** starts: `flake.lock` only.                                                                                                        |
| 22:19:28 | New nixpkgs changes every unit → every container restarts at once. Runner stopped.                                                             |
| 22:19:52 | Runner starts, declares against `https://git.hu-tao.dev/`, caddy is not listening yet: `fail to invoke Declare … connection refused`. Exits 1. |
| 22:19:53 | deploy-rs samples unit state, sees one failed unit.                                                                                            |
| 22:19:55 | Deploy 3 aborts. De-activation stops every container. **Outage begins.**                                                                       |
| 22:19:58 | The runner's own `Restart=always` brings it up successfully — **3 seconds after the abort decision.**                                          |
| 22:20:08 | `kuma-check` fails: `Failed to connect to status.hu-tao.dev:443`.                                                                              |
| 22:25:01 | `kuma-check` fails again.                                                                                                                      |
| 22:25:03 | `systemctl restart docker` (§12's documented recovery).                                                                                        |
| 22:25:09 | `switch-to-configuration switch` → `Could not acquire lock`. Fell back to starting units directly.                                             |
| 22:25:39 | Mail answering. **Outage ends.**                                                                                                               |
| 22:30:27 | `kuma-check` green again.                                                                                                                      |
| 22:33:16 | **Deploy 4** (gen 60): `flake.lock` + the readiness gate. Clean, 40s.                                                                          |
| 22:34:54 | Reboot complete on kernel 6.18.52. 38 seconds down.                                                                                            |
| ~22:38   | `tofu apply`: 0 added, 0 changed, 0 destroyed.                                                                                                 |

## 3. Impact, measured

- **Mail** (25/465/587/993) refused connections for 5m44s. No bounces or
  deferrals are attributable to the window. That is expected but only weak
  evidence: while the container was down we logged nothing, because nothing
  reached us. Sending MTAs queue and retry on schedules measured in hours, and
  six minutes is far inside every one of them, so loss is very unlikely —
  but it is unprovable from our side.
- **Everything behind caddy** — forgejo, webmail, kuma, navidrome, searxng,
  pages — refused connections for the same period.
- **Observability** (grafana, tempo, dozzle) down, and **kuma down**, so the
  public status page could not report its own outage. This is the paradox §10
  anticipates, and the mitigation worked: see §6.
- **minecraft / minecraft2** restarted and came back on their own. The other
  fourteen containers did not.

## 4. Root cause

`docker-forgejo-runner.service` has a hard runtime dependency on caddy that is
nowhere expressed to systemd.

The runner's first action on start is declaring itself against `instanceUrl`,
which is the **public** `https://git.<domain>/` — deliberately, because the URL
is handed to job containers that sit on per-job networks where a proxy-network
container name does not resolve. That call therefore leaves the box and comes
back in through caddy. If caddy is not yet listening, the connect is refused and
the runner **exits 1** rather than retrying in-process.

Because the runner declares no `networks`, `modules/containers/default.nix`
gives it no `after`/`requires` at all. Nothing has ever ordered it behind caddy.

This was known. Commit `ddf6f98`, 2026-09-13, closes with:

> Separately, and NOT fixed here: the runner declares no `networks`, so
> modules/containers/default.nix gives it no after/requires at all. Any future
> deploy that does restart docker.service reproduces this same failure. Worth an
> ordering dependency, as its own change.

That change was never written. This is the "future deploy".

## 5. Was the cause "combining a system update with container updates"?

**No — and the timeline is what rules it out.** It is worth writing down
because it was the first hypothesis, and it is a reasonable one.

The four updates were deployed in **four separate deploys**, not one. At the
moment of failure, deploy 3 contained `flake.lock` and the inert tofu lock file
and nothing else. The three container bumps were already live and untouched;
the mailserver major was already live and untouched. Removing them from the
branch entirely would have changed nothing about this failure.

What actually mattered is a property of the system update **on its own**: a new
nixpkgs changes the store path of every systemd unit, so `switch-to-configuration`
restarts _every container simultaneously_. That is the condition the runner
cannot survive, and it needs no container bump to arrive. The same thing
happened in September for an unrelated reason — commit `4caf61b` pinned the
docker daemon's `bip`, which restarted `docker.service`, which stopped every
container — and produced the identical error string.

**But the instinct behind the hypothesis is correct, and it is the real lesson.**
The error was treating a system update as just another row on the same
checklist. The dashboard listed `lock file maintenance` directly beneath
`update amir20/dozzle docker tag to v11.1.0`, as though they were the same kind
of change. They are not, and the difference is blast radius:

|                       | restarts       | reboot                       | rollback                                   |
| --------------------- | -------------- | ---------------------------- | ------------------------------------------ |
| a container tag bump  | 1 unit         | no                           | re-deploy, unless it migrated its own data |
| `lockFileMaintenance` | **every unit** | **yes, if the kernel moves** | re-deploy, cleanly                         |

A window sized and sequenced for the first kind is not a window for the second.
So: not "don't combine them in a PR" — they combine in a PR fine, and did. It
is **"don't deploy them in the same window, and never deploy the system one
last."**

## 6. What went well

- **`kuma-check` caught it.** The out-of-band timer failed at 22:20:08 and
  22:25:01 and was green either side. The self-hosted-status-page paradox
  described in §10 was closed exactly as designed: kuma could not report its
  own outage, and the thing that noticed was the probe that lives outside it.
- **deploy-rs did its job on deploys 1, 2 and 4** — three clean activations
  with magic rollback confirmed, ~40s each.
- **Backups were taken cold and verified before every migrating change.** Two
  local tars and two tagged restic snapshots, all taken with the relevant
  containers stopped. None were needed. That is the correct outcome.
- **The pre-flight on the mailserver major caught a real break** before any
  downtime: opendkim's gid moves 104 → 102 in v16, which would have made the
  box receive mail and silently refuse to send it.
- **§12's documented recovery was correct.** `systemctl restart docker` was the
  right first move and it worked.

## 7. What went badly

- **A known landmine was left armed for three days.** `ddf6f98` diagnosed the
  exact failure, wrote down that it would recur, and deferred the fix. The
  deferral was reasonable in isolation and wrong in aggregate: the cost of the
  fix was a 59-line module addition, and the cost of not doing it was a
  six-minute full outage.
- **The system update was attempted in the last third of the window**, after
  it had already been identified as needing its own. Thirteen minutes was not
  enough for a three-week nixpkgs move plus a reboot plus verification, and the
  window should have been re-scoped rather than squeezed.
- **deploy-rs's abort path leaves the box worse than either config.** This is
  the most surprising finding here and deserves its own line: when activation
  fails, the de-activation stops the containers and the rollback does **not**
  restart them. The box does not return to the old generation's _running state_
  — it returns to the old generation's _configuration_, with nothing running.
  A 3-second transient in one non-critical unit therefore cost fifteen healthy
  services.
- **`switch-to-configuration switch` failed with `Could not acquire lock`**
  during recovery, because deploy-rs still held it. Recovery had to fall back to
  starting units by hand. Worth knowing before the next incident.

## 8. What changed

- `fix(forgejo-runner)`: a `forgejo-runner-ready.service` oneshot, in the same
  shape as `forgejo-runner-token`, that probes `/api/v1/version` and waits
  before the runner starts. Ordering alone would not have been enough — a
  `docker-*` unit counts as started when the container is _created_, not when
  the service inside it answers. It exits 0 on timeout deliberately: its job is
  to close the race, not to become a new way for a deploy to fail.

  It earned its place on the first cold boot after the reboot:

  ```
  curl: (7) Failed to connect to git.hu-tao.dev:443 after 83 ms: Could not connect to server
  forgejo answered after 2 attempt(s)
  ```

  The first probe failed. Without the gate, that is the runner exiting 1.

- `ARCHITECTURE.md` §12 gains a row for the deploy-rs abort behaviour.

## 9. Action items

| #   | Action                                                                                                                                                                                                                                                   | Why                              |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| 1   | Audit every container unit for an unexpressed runtime dependency on another container. The runner was found the hard way; it is unlikely to be the only one.                                                                                             | Same class of bug, same trigger. |
| 2   | Deploy `lockFileMaintenance` **alone**, first in a window, never last.                                                                                                                                                                                   | §5.                              |
| 3   | Decide whether a failed activation should de-activate at all. `magicRollback` protects against losing SSH; it is not obviously the right tool for one crashlooping non-critical unit, and its abort is more destructive than the failure it responds to. | §7.                              |
| 4   | Confirm the healthchecks.io grace period is short enough that two missed pings actually page. The probe failed correctly; whether that produced an alert is configured outside this repo.                                                                | §6 is only half-verified.        |
| 5   | Create `postmaster@hu-tao.dev`. See §10.                                                                                                                                                                                                                 | RFC 5321 §4.5.1.                 |
