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

The stack is one container, `docker-openamika.service`, on a tiny
`openamika-base:1` image containing only empty mount-point directories.
Python 3.11, the four locked uv2nix environments, patched source, models and
voice assets run directly from read-only binds of their host Nix store paths.
Every download has a fixed hash. Starting it needs no package installer,
model download or setup unit.

Only the application's runtime closure is mounted, never all of `/nix/store`.
`closureInfo` writes the exact path list at build time. A service-local Docker
wrapper reads that list at start and adds one read-only bind per store path,
preserving oci-containers' generated flags and lifecycle. Nothing reads a built
file during flake evaluation: `nix flake check --no-build` needs no IFD.
`/opt/openamika` is another read-only bind of the same app, for stable model
paths in settings. The entrypoint uses its store Bash interpreter and explicitly
sets PATH and SSL_CERT_FILE from the closure; no base-image binaries are needed.

The base archive loaded on each wake is **703 bytes**. The runtime closure is
about **8.92 GiB** across **702 store paths** (NAR size; measured 2026-11-10).
The previous large image cost a 5.12 GiB Nix archive plus about 19.6 GB in
containerd layer blobs and unpacked snapshots. The large files now exist only
in the host store: bind mounts do not copy them into Docker storage.

After deploying this change, remove the superseded Docker image:

```sh
sudo docker image rm openamika:c3d71694
```

The weekly Docker prune also removes it because the configuration now names
`openamika-base:1`. The old Nix image archive remains while an older system
generation or another GC root retains it; normal Nix garbage collection can
reclaim it after those roots expire. The tiny base can be public, but the
runtime closure and personal-use assets must stay out of public caches.

The `openamika_data` volume holds editable configuration, persona, memories,
optional `brain/.env`, top-level `memory_f` evidence/usage data, logs and
disposable caches. The initial default state is about 568 KB; caches and
memories grow as she is used. The named-volume mount uses `nocopy` so Docker
does not replace its service-user ownership with the empty base image's root
ownership on the first start. The gateway stays on the
host because it starts and stops a systemd unit, as `minecraft-scaler` does.

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

`modules/high-memory.nix` registers high memory usage programs explicitly.
Each program has a positive `slots` weight, defaulting to 1, and admission sums
the occupied weights plus the requested program's weight against
`highMemory.maxRunning = 2`. Each Minecraft world uses one slot;
`docker-openamika` uses both. Two worlds may run together; OpenAmika cannot run
alongside any capped world. Horizon stays outside this cap. Nothing is evicted
to make room. Admitted programs retain their full weight while starting or
stopping, until inactive/failed. The same guard applies to manual starts.

The gateway starts the container on an authenticated browser request. Browser
WebSockets hold a lease; twenty minutes after the last connection/request ends,
it stops the container. Close its tabs to let it sleep. Health probes to
`/_gateway/health` never wake it. A full cap returns HTTP 503 with a retry hint.
A cold start waits for the web service, up to fifteen minutes.

**Memory, measured live after the declarative deployment:** OpenAmika holds
6.73 GB; the host uses 9.3 of 15.3 GB with no world awake. A modded world can
need a 5 GB heap plus overhead, and there is no swap. OpenAmika therefore
reserves both slots; its 8 GB container ceiling is not spare capacity for a
world. `--oom-score-adj=500` still makes her the first victim of host-wide OOM.

Deploys leave a running OpenAmika container alone. Its unit sets
`restartIfChanged = false`, so activation skips both stop/start and restart
paths. `stopIfChanged` keeps its default: it selects between those two paths
only when a restart is allowed. New runtime configuration applies on the next
wake after idle shutdown or an explicit stop. The gateway still restarts on
changes and starts the container on demand.

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

Deploy using the repository's normal rollback-safe path
([Deploying](deploying.md)). Forgejo OAuth and the existing secrets need no
changes for the declarative image. A fresh volume initializes its small,
editable defaults automatically; opening `/use` wakes the stack. There is
no setup command to run on the VPS.

### Migrating the existing imperative volume

Close all OpenAmika tabs first. On the VPS, stop the gateway and both old
containers, then move the old volume directory aside. This preserves the old
venvs, incomplete downloads and settings for rollback without copying them.
Run these commands in an interactive SSH session (`ssh -p 2222 hutao@vps`):

```sh
sudo systemctl stop openamika-gateway docker-openamika-setup docker-openamika
sudo bash <<'SH'
set -euo pipefail
volume=/var/lib/docker/volumes/openamika_data/_data
old="$volume.imperative-$(date +%Y%m%d-%H%M%S)"
owner=$(stat -c '%u' "$volume")
group=$(stat -c '%g' "$volume")
mv "$volume" "$old"
install -d -m0700 -o "$owner" -g "$group" "$volume" "$volume/brain"
# Keep personal configuration and memories; never restore source or venvs.
if test -d "$old/config"; then cp -a "$old/config" "$volume/"; fi
if test -d "$old/memory_f"; then cp -a "$old/memory_f" "$volume/"; fi
for name in memories .env scenes.json 例子.txt 表层.txt 思考.txt; do
  if test -e "$old/brain/$name"; then
    cp -a "$old/brain/$name" "$volume/brain/"
  fi
done
if test -d "$old/avatar/stage"; then
  install -d -m0700 -o "$owner" -g "$group" "$volume/avatar"
  cp -a "$old/avatar/stage" "$volume/avatar/"
fi
printf 'Rollback copy: %s\n' "$old"
SH
```

Keep the old `settings.json` in that rollback copy for comparison. Let the new
image generate settings with Linux interpreter paths, CPU devices, disabled
vision, a local pinned embedder and the longer CPU voice timeout. Reapply any
personal port or other settings deliberately. Copying the old settings wholesale
can retain stale paths to the old venvs or model cache. Do not restore `envs`,
`vendor`, `speech/models`, `.cache`, `.tmp`, `.nix-source`, or upstream code.

On the workstation, deploy the reviewed working tree with the usual command:

```sh
SOPS_AGE_KEY_FILE=/var/lib/sops-nix/vps.txt nix develop -c ssh-agent sh -c 'ssh-add ~/.ssh/id_ed25519 && deploy .#vps'
```

Then on the VPS:

```sh
sudo systemctl start openamika-gateway
sudo systemctl start docker-openamika
sudo journalctl -fu docker-openamika
```

Open **<https://openamika.hu-tao.dev/use>**, sign in through Forgejo and check
chat, microphone recognition, the Live2D avatar and audible voice. The first
CPU model load can take several minutes. No installation or download occurs.
Keep the rollback directory until these work; remove it manually afterwards.
If rolling the system back, stop the gateway/container before swapping `_data`
with the saved directory.

### Pins, licenses and updates

The operator accepted MekaHime's
[personal-use license](https://huggingface.co/MekaHime/MekaHime_Amika/blob/main/LICENSE).
The voice and avatar files are fetched individually against the upstream
manifest's SHA256s, including the Host paper doll at its separate revision.
They belong only in the workstation/VPS store and private backups. **Never
publish this image, its closure, or the restricted fetches to a public cache
or registry.** Local build preference and disabled substitution are not an
upload access control; do not attach a cache upload hook to these outputs.
The repository carries hashes and URLs, not the restricted bytes.

`pkgs/openamika/assets.json` records upstream's model/data pins. GPT-SoVITS is
also checked against upstream's published tree digest before adding weights
and building its dictionaries. bge-m3 is pinned separately because upstream's
core setup downloads an unpinned Hugging Face snapshot. Only its runtime files
are fetched, without duplicate ONNX weights.

After bumping the source, review its setup scripts and refresh asset pins and
`settings.example.json`; regenerate all four environment locks:

```sh
nix build .#openamika-source
nix shell nixpkgs#uv nixpkgs#python311 -c python3 pkgs/openamika/envs/update.py result
nix build .#openamika-image
```

Source and model updates replace the mounted runtime closure; they do not
reinstall anything in the volume or enlarge the base image. The pinned default
roles remain GLM-5 without reasoning for deep,
DeepSeek V4.1 Flash for surface/reflection, and GLM-5.3 for memory writes.
Existing configuration and persona edits survive. The daily restic job keeps
the mutable volume, excluding `.cache` and `.tmp`; environments and assets are
already
reproducible from the runtime's pinned inputs.

## Checks and operations

```sh
sudo systemctl status docker-openamika openamika-gateway
journalctl -u docker-openamika -u openamika-gateway
sudo systemctl stop docker-openamika  # closes active sessions immediately
nix build .#checks.x86_64-linux.openamika-imports  # offline imports
nix build .#checks.x86_64-linux.openamika-runtime  # exact mounts + empty base
nix build .#checks.x86_64-linux.openamika-services -L  # Docker VM; needs KVM
nix build .#checks.x86_64-linux.openamika-gateway
nix build .#checks.x86_64-linux.minecraft-cap -L  # systemd VM; needs KVM
```

The service-start check boots a local NixOS VM and starts TTS (including real
model load/warmup), embedder, brain, speech and messengers together in Docker.
It reuses the production container flags and exact closure mounts, runs as uid
1000004 without a TTY, denies external networking, initializes state through
the real launcher and requires every health endpoint to answer. A VM preserves
root ownership of store paths; an unprivileged Bubblewrap namespace makes root
appear as nobody, which NLTK's data ownership checks correctly refuse.

### Writable paths and startup diagnostics

All application writes land under `/data`: configuration and persona edits,
`brain/memories`, `memory_f` (SQLite usage, evidence profiles, provider receipts
and reset backups), launcher/agent logs, avatar banks/stage edits and TTS caches.
The optional IoT bridge uses `AMIKA_IOT_DATA_DIR=/data/IoT/data`. GPT-SoVITS'
Japanese dictionary and Chinese pronunciation cache are built ahead of time.
NLTK permits Nix-deduplicated corpus hardlinks only for read-only descriptors
on read-only store mounts, owned by root and without group/world write bits.
The other hardlink checks remain enabled; the service test exercises both
corpus loading and refusal of hardlinks in mutable storage.
The model directory explicitly replaces upstream's `speech/models` directory
before linking the six pinned SenseVoice files; keeping the original directory
would nest the models one level too deep and break FunASR's local-model lookup.

`TMPDIR=/data/.tmp` is created by the launcher so model temporary files do not
consume the memory-accounted 256 MB tmpfs. `/tmp` also explicitly has mode 1777
for the service uid. Both `.tmp` and `.cache` are excluded from backups.

`PYTHONUNBUFFERED=1` makes launcher output immediately visible in journald and
Dozzle. Lifecycle events also mirror `logs/launcher.log` to non-TTY stdout:
upstream normally writes those only to the file and shows its live dashboard
only on a TTY. Health waits print the endpoint and timeout immediately, then
progress every 30 seconds. The embedder gate is GET
`http://127.0.0.1:8011/health` with JSON `ok=true`; the generated settings allow
600 seconds for loading. Each probe times out after two seconds. On failure or
timeout, the launcher reports it and proceeds to brain and speech rather than
waiting forever. Check `/data/logs/embedder.log` for the model-loader traceback.

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
