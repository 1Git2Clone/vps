# ==============================================================================
# OpenAmika — AI companion, CPU-only, on demand
# ==============================================================================
# OpenRouter supplies the chat models; speech recognition, voice and
# embeddings run on CPU inside the container. Nobody reaches the container
# directly:
#
#   browser -tailnet-> caddy (Forgejo sign-in) -unix socket-> openamika-gateway
#     -> 172.29.0.2:53000 (the container's web UI, on its own bridge)
#
# The gateway is a host unit, not a container, for the same reason
# minecraft-scaler is: it starts and stops a systemd unit. It wakes the
# container on an authenticated request and stops it twenty minutes after the
# last browser tab closes.
#
# A tiny dockerTools base provides mount points. Only the application
# runtime closure is mounted read-only from the host store. The volume holds
# settings, memories and disposable caches.
# Starting the container never installs packages or fetches models.
#
# Confinement, each layer independent of the others:
#   network   own bridge, nothing published, no host port reachable, TCP 443
#             to public addresses only (modules/firewall.nix)
#   process   its own uid, no capabilities, no-new-privileges, read-only root
#   memory    8g hard, no swap, and the first thing the kernel kills if the
#             host itself runs out (no swap on this box)
#   CPU       4 of 8 cores, and a quarter of the weight, so a world's tick
#             wins any contention
#   admission both high-memory slots; cannot run alongside a capped world
#             (../high-memory.nix)
{
  config,
  lib,
  pkgs,
  openamika,
  ...
}:
let
  inherit (config.infra) openamikaNetwork openamikaAddress openamikaGateway;
  id = toString config.infra.serviceId.openamika;
  volume = "/var/lib/docker/volumes/openamika_data/_data";
  docker = "${config.virtualisation.docker.package}/bin/docker";
  python = pkgs.python3.withPackages (p: [ p.aiohttp ]);

  # The uid needs a name. torch asks getpass.getuser(), which ends in
  # getpwuid(). Keep a named entry for the service uid inside the image.
  passwd = pkgs.writeText "openamika-passwd" ''
    root:x:0:0:root:/root:/usr/sbin/nologin
    nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
    openamika:x:${id}:${id}:OpenAmika:/data:/usr/sbin/nologin
  '';
  group = pkgs.writeText "openamika-group" ''
    root:x:0:
    nogroup:x:65534:
    openamika:x:${id}:
  '';

  container = {
    image = "openamika-base:1";
    imageFile = openamika.image;
    entrypoint = "${openamika.runtime}/bin/openamika-runtime";
    user = "${id}:${id}";
    autoStart = false;
    networks = [ openamikaNetwork ];
    environment = openamika.runtimeEnvironment // {
      HOME = "/data";
      PYTHONUNBUFFERED = "1";
      TMPDIR = "/data/.tmp";
      # Matches --cpus below; more threads than cores only thrash.
      OMP_NUM_THREADS = "4";
      MKL_NUM_THREADS = "4";
      # The web UI listens on the bridge (ui-host.patch); the rest of the
      # stack stays on the container's loopback.
      OPENAMIKA_UI_HOST = "0.0.0.0";
      # uvicorn honours X-Forwarded-Proto from the gateway alone, which is
      # what makes upstream's same-origin check see https.
      FORWARDED_ALLOW_IPS = openamikaGateway;
    };
    environmentFiles = [ config.sops.templates."openamika.env".path ];
    volumes = [
      "openamika_data:/data:nocopy"
      "${openamika.app}:/opt/openamika:ro"
      "${passwd}:/etc/passwd:ro"
      "${group}:/etc/group:ro"
    ];
    extraOptions = [
      "--cap-drop=ALL"
      "--security-opt=no-new-privileges:true"
      "--read-only"
      "--tmpfs=/tmp:rw,nosuid,nodev,size=256m,mode=1777"
      # launch.py supervises several servers; tini reaps what it orphans and
      # passes the stop signal on.
      "--init"
      # launch.py shuts its children down on Ctrl-C, not on SIGTERM.
      "--stop-signal=SIGINT"
      "--stop-timeout=60"
      # Measured ~7 GiB for the whole stack on the desktop. Equal swap limit
      # means none, even if the box ever gets swap.
      "--memory=8g"
      "--memory-swap=8g"
      # Host-wide OOM (not this container's own limit) takes this before mail
      # or a world mid-save. It is the one thing here that loses nothing by
      # dying: the gateway wakes it again.
      "--oom-score-adj=500"
      "--cpus=4"
      "--cpu-shares=256"
      "--pids-limit=4096"
    ];
  };

  # oci-containers shell-quotes every extraOption, so a dynamic mount list
  # cannot be spliced there. Interpose only on this service's Docker command;
  # all generated run flags and pre-start/stop behavior remain upstream's.
  # Read the built closureInfo output at runtime, never during Nix evaluation
  # (builtins.readFile here would introduce IFD into flake check --no-build).
  closureDocker = import ../../pkgs/openamika/docker-wrapper.nix {
    inherit pkgs docker;
    closure = openamika.runtimeClosure;
  };

  # A fresh named volume is root's; the container is not.
  ownVolume = ''
    ${docker} volume create openamika_data > /dev/null
    install -d -m0700 -o ${id} -g ${id} ${volume}
  '';

in
{
  assertions = [
    {
      assertion = config.virtualisation.oci-containers.containers.openamika.preRunExtraOptions == [ ];
      message = "OpenAmika closure mounts require docker run as the first Docker argument";
    }
  ];

  highMemory.programs = {
    docker-openamika.slots = 2;
  };

  sops.templates = {
    "openamika.env".content = ''
      OPENROUTER_API_KEY=${config.sops.placeholder.openamika_openrouter_api_key}
    '';
    "openamika-auth.env".content = ''
      OAUTH2_PROXY_CLIENT_ID=${config.sops.placeholder.openamika_oauth_client_id}
      OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.openamika_oauth_client_secret}
      OAUTH2_PROXY_COOKIE_SECRET=${config.sops.placeholder.openamika_oauth_cookie_secret}
    '';
    # Read by the container's own user (65532), hence world-readable: an
    # email address, kept out of the public repo, not a credential.
    "openamika-allowed-emails" = {
      content = "${config.sops.placeholder.openamika_allowed_email}\n";
      mode = "0444";
    };
  };

  virtualisation.oci-containers.containers = {
    openamika = container // {
      extraOptions = container.extraOptions ++ [ "--ip=${openamikaAddress}" ];
    };
    # THE SIGN-IN. Stock oauth2-proxy with Forgejo as the identity provider:
    # the login form is Forgejo's own (password manager, 2FA), and nothing
    # here is hand-written auth. Caddy asks it about every request
    # (forward_auth, caddy.nix). Only the email in sops gets through: every
    # Forgejo account can complete the OAuth flow, so that list is the gate.
    #
    # Token exchange and keys go to forgejo:4242 on the proxy network, not
    # back out through caddy and Anubis; the issuer is still the public URL,
    # which is what Forgejo puts in the tokens. Discovery is skipped because
    # it would have to fetch that public URL.
    openamika-auth = {
      image = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.5@sha256:8498b0d0ef0a7b29686414000a08aee467f02d0299c9ed1e006a8f33fc017916";
      networks = [ config.infra.proxyNetwork ];
      environment = {
        OAUTH2_PROXY_PROVIDER = "oidc";
        OAUTH2_PROXY_PROVIDER_DISPLAY_NAME = "Forgejo";
        OAUTH2_PROXY_OIDC_ISSUER_URL = "https://git.${config.infra.domain}";
        OAUTH2_PROXY_SKIP_OIDC_DISCOVERY = "true";
        OAUTH2_PROXY_LOGIN_URL = "https://git.${config.infra.domain}/login/oauth/authorize";
        OAUTH2_PROXY_REDEEM_URL = "http://forgejo:4242/login/oauth/access_token";
        OAUTH2_PROXY_OIDC_JWKS_URL = "http://forgejo:4242/login/oauth/keys";
        OAUTH2_PROXY_REDIRECT_URL = "https://openamika.${config.infra.domain}/oauth2/callback";
        OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE = "/etc/oauth2-proxy/emails";
        OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:4180";
        # Auth only: caddy proxies the site itself.
        OAUTH2_PROXY_UPSTREAMS = "static://202";
        OAUTH2_PROXY_REVERSE_PROXY = "true";
        OAUTH2_PROXY_TRUSTED_PROXY_IPS = "${config.infra.caddyIPv4}/32";
        OAUTH2_PROXY_SKIP_PROVIDER_BUTTON = "true";
        OAUTH2_PROXY_APPROVAL_PROMPT = "auto";
        # __Host-: Secure, Path=/, no Domain, so no other subdomain reads it.
        OAUTH2_PROXY_COOKIE_NAME = "__Host-openamika";
        OAUTH2_PROXY_COOKIE_SECURE = "true";
        OAUTH2_PROXY_COOKIE_SAMESITE = "lax";
      };
      environmentFiles = [ config.sops.templates."openamika-auth.env".path ];
      volumes = [
        "${config.sops.templates."openamika-allowed-emails".path}:/etc/oauth2-proxy/emails:ro"
      ];
      extraOptions = [
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges:true"
        "--read-only"
        "--memory=128m"
      ];
    };

  };

  systemd.services = {
    docker-openamika = {
      # Keep the current conversation alive across configuration switches.
      # restartIfChanged=false skips both stop/start and restart activation paths;
      # stopIfChanged only selects between those paths, so keep its default.
      # The new unit takes effect when the gateway next wakes the container.
      restartIfChanged = false;
      preStart = lib.mkBefore ownVolume;
      path = lib.mkBefore [ closureDocker ];
      serviceConfig.RestartPreventExitStatus = 3;
    };

    openamika-gateway = {
      description = "OpenAmika wake proxy and disconnected idle shutdown";
      wantedBy = [ "multi-user.target" ];
      path = [ config.systemd.package ];
      serviceConfig = {
        ExecStart = "${python}/bin/python ${../../scripts/openamika/gateway.py} http://${openamikaAddress}:53000 docker-openamika.service";
        Restart = "always";
        RestartSec = 5;
        RuntimeDirectory = "openamika-gateway";
        RuntimeDirectoryPreserve = "yes";
        RuntimeDirectoryMode = "0750";
        Group = "caddy";
        UMask = "0007";

        # Root because systemd only takes start/stop from root or polkit, and
        # polkit is off on this box — the minecraft-scaler arrangement. Root
        # with no capabilities, which can talk to systemd and to the one
        # address below, and nothing else.
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        IPAddressDeny = "any";
        IPAddressAllow = openamikaAddress;
      };
    };

    docker-caddy = {
      after = [ "openamika-gateway.service" ];
      requires = [ "openamika-gateway.service" ];
    };
  };

  virtualisation.oci-containers.containers.caddy.volumes = [
    "/run/openamika-gateway:/run/openamika-gateway:ro"
  ];

  # Runtime caches are disposable; models and environments live in the store.
  services.restic.backups.b2.exclude = map (p: "${volume}/${p}") [
    ".cache"
    ".tmp"
  ];
}
