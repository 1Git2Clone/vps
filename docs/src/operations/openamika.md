# OpenAmika and high memory usage programs

OpenAmika runs entirely on the VPS: OpenRouter supplies the chat models;
CPU-only local services provide speech recognition, voice and embeddings.
The browser renders the Amika Live2D avatar and captures microphone input.
Visit **<https://openamika.hu-tao.dev/use>** from the tailnet and sign in with
your Forgejo account. HTTPS permits browser microphone access. There is no
public listener for this site and no published port.

## How a request reaches it

```text
browser -tailnet-> caddy :8443
  -forward_auth-> openamika-auth (oauth2-proxy; signs in through Forgejo)
  -unix socket-> openamika-gateway (host unit)
  -> 172.29.0.2:53000, the openamika container on its own bridge
```

The stack is one container, `docker-openamika.service`, on the stock
`python:3.11-slim-bookworm` image pinned by digest. The pinned upstream source
(`pkgs/openamika`) and our launcher and fixups are mounted read-only from the
Nix store. Venvs, weights, the voice, settings and memories live on the
`openamika_data` volume. The gateway stays on the host because it starts and
stops a systemd unit, the same reason `minecraft-scaler` does.

| Layer   | Limit                                                                                                                                              |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| network | own bridge `openamika`; no host port reachable; TCP 443 to public addresses only ([Confined bridges](../architecture/network.md#confined-bridges)) |
| process | uid `serviceId.openamika`, `--cap-drop=ALL`, `no-new-privileges`, read-only root, 256m `/tmp`, 4096 pids, `--init`                                 |
| memory  | `--memory=8g`, no swap, `--oom-score-adj=500`: a host-wide OOM kills this before mail or a world mid-save                                          |
| CPU     | `--cpus=4` of 8 and `--cpu-shares=256`, so a world's tick wins contention                                                                          |
| gateway | root with no capabilities; `IPAddressAllow` is 172.29.0.2 alone                                                                                    |
| sign-in | stock oauth2-proxy, Forgejo's login form and 2FA; only the email in sops passes. No hand-written auth                                              |

Only the web UI listens on the bridge (`ui-host.patch`); speech, voice and the
embedder stay on the container's loopback. The gateway forwards `Host` and
`X-Forwarded-Proto: https`, and uvicorn trusts them from 172.29.0.1 alone, so
upstream's same-origin check (the memory reset) sees the browser's real origin.

## Shared admission and scale to zero

`modules/high-memory.nix` registers high memory usage programs explicitly;
“a few gigabytes” is a description, not a measured threshold. The four Minecraft
worlds, `docker-openamika` and `docker-openamika-setup` share
`highMemory.maxRunning = 2`. Horizon remains outside this cap. No running
program is evicted to make room. Starting or stopping programs occupy slots
until fully inactive/failed. Admission also applies to manual `systemctl start`.

The gateway starts the container on an authenticated browser request. Browser
WebSockets hold a lease; twenty minutes after the last connection/request ends,
it stops the container. Close its tabs to let it sleep. Health probes to
`/_gateway/health` never wake it. A full cap returns HTTP 503 with a retry hint.
A cold start waits for the web service, up to fifteen minutes.

**Memory, measured 2026-11-10:** 15.6 GiB, no swap, 3.7 GiB used with every
always-on service up and no world awake. OpenAmika (~7 GiB on the desktop) plus
world 1 (6.5 GiB limit) fits beside that only because a world's heap uncommits
when idle and limits are ceilings, not reservations. If the box OOMs, OpenAmika
dies first by design. If it does that in normal use, lower `maxRunning` for it
rather than raising anything.

The Minecraft-only backup hold does not stop OpenAmika or include its volume in
a Minecraft snapshot.

## Secrets and first installation

Edit with `sops secrets.yaml`:

```yaml
openamika:
  openrouter_api_key: "sk-or-v1-..."
  oauth_client_id: "..."
  oauth_client_secret: "..."
  oauth_cookie_secret: "..."
  allowed_email: "you@example.com"
```

The OAuth2 application is registered once in Forgejo: **Settings → Applications
→ Manage OAuth2 applications**, name `openamika`, redirect URI
`https://openamika.hu-tao.dev/oauth2/callback`, confidential client. It shows
the client ID and secret once. Generate the cookie secret with
`openssl rand -base64 32 | tr -- '+/' '-_'`. `allowed_email` is your Forgejo
account's primary email, and it must be verified there: any Forgejo account can
complete the OAuth flow, so this one address is the gate. It lives in sops
because this repo is public.

Only the container receives the OpenRouter key, and only oauth2-proxy the OAuth
values, each through a docker env file. None is in the Nix store.

After adding the secrets, deploy using the repository's normal rollback-safe
path (see [Deploying](deploying.md)), then apply the reviewed OpenTofu DNS
addition from `tofu/` (`openamika` points at the tailnet address). Then
initialize once on the VPS:

```sh
sudo systemctl start docker-openamika-setup.service
sudo journalctl -fu docker-openamika-setup.service
```

Setup stops the stack if it is running, and the stack refuses to start while
setup runs. It downloads CPU environments, recognition/embedding weights, and
Amika's voice/avatar into the volume. The setup container includes the
operator's already-given acceptance of MekaHime's personal-use license. Do not
use it for another person without their acceptance of
[the license](https://huggingface.co/MekaHime/MekaHime_Amika/blob/main/LICENSE).
Restricted assets are not in this repository, container images or Nix sources.

The source revision and model roles are pinned in `pkgs/openamika`:
GLM-5 without reasoning for deep, DeepSeek V4.1 Flash for surface/reflection,
and GLM-5.3 for memory writes. Vision is disabled.

**Bumping the pin** makes the stack exit 3 ("source changed"), which the unit
does not restart on. Back up, move the volume's contents aside, and run setup
again. "Not set up" is exit 3 too, so waking it before setup never loops.

The daily restic job takes the volume with every other one, minus `envs/`, the
voice engine's `.venv`, `.cache` and `.tmp`: many GiB that setup re-downloads.

For a desktop migration, set up the VPS first. Stop the desktop stack before
copying personal settings, memories and configuration into
`/var/lib/docker/volumes/openamika_data/_data` (owned by `serviceId.openamika`),
then update any desktop-specific paths in `settings.json`. Do not copy virtual
environments or `.nix-source`. Verify VPS chat and voice before disabling the
desktop service and its old proxy routes.

## Checks and operations

```sh
sudo systemctl status docker-openamika openamika-gateway
journalctl -u docker-openamika -u openamika-gateway
sudo systemctl stop docker-openamika  # closes active sessions immediately
nix build .#checks.x86_64-linux.openamika-gateway
nix build .#checks.x86_64-linux.minecraft-cap -L  # systemd VM; needs KVM
```

Verify confinement after a deploy, while the stack is awake. `exec`, never a
throwaway `docker run`: every non-zero container exit on this box pages.
Expect `open` for OpenRouter and `blocked` for the rest:

```sh
sudo docker exec openamika python3 -c '
import socket
for host, port in [("openrouter.ai", 443), ("169.254.169.254", 80),
                   ("100.100.100.100", 80), ("172.29.0.1", 3000), ("1.1.1.1", 80)]:
    try:
        socket.create_connection((host, port), timeout=5).close(); print(host, port, "open")
    except OSError:
        print(host, port, "blocked")'
sudo nft list chain inet nixos-fw forward | grep counter
```

A refused start is skipped by `ExecCondition`, rather than failed into a
restart loop. The gateway reports a cap refusal or a startup failure; inspect
the journal to distinguish them. Its Unix socket directory survives gateway
restarts so Caddy's bind mount keeps following newly created sockets.
