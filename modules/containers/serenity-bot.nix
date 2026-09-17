# ==============================================================================
# serenity-discord-bot — Rust discord bot
# ==============================================================================
# An OUTBOUND gateway client: it opens a websocket to Discord and serves
# nothing. So unlike every other service here it gets no caddy vhost, no entry
# in infra.certSubdomains, no proxy network and no public port. Three of the
# four things a new service in this repo normally needs do not apply.
#
# It has three edges: postgres (via pgbouncer, see modules/postgres.nix), redis,
# and OTLP traces to tempo. Grafana is NOT an edge — grafana reads tempo, the
# bot only writes to it.
#
# Upstream publishes no image, so it is built here from their own two-stage
# Dockerfile off a hash-pinned checkout. See the builder unit at the bottom.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (config.infra) botNetwork botGateway;

  # ============================================================================
  # THE TWO NUMBERS. Only the first is meant to be touched.
  # ============================================================================
  # Discord-facing shard count. Change it, redeploy, and the bot comes back
  # owning that many shards — the ranges below are computed, so there is no
  # per-instance arithmetic anywhere in this config. Upstream's
  # deploy/supervisor/ hardcodes two instances with literal ranges; that is the
  # part deliberately not copied.
  #
  # Resharding costs one gateway IDENTIFY per shard, rate-limited by the
  # max_concurrency Discord issues (1 for a bot this size). So the blip scales:
  # 8 shards is roughly a 40-second staggered reconnect, not instant.
  shards = 1;

  # How many processes to spread those shards across.
  #
  # DEFAULTS TO 1 ON PURPOSE. serenity's start_shard_range runs multiple shards
  # inside ONE process, sharing one cache and one connection pool — on a single
  # host that beats N processes on memory and on log legibility. This only earns
  # its keep for multi-host or blue-green, which is what upstream uses it for.
  #
  # Above 1, redis stops being optional: the AI locks and rate limits are
  # per-process without it.
  instances = 1;

  # Even split, remainder to the low-numbered instances: 5 shards over 2
  # instances gives 0..=2 and 3..=4. builtins.div rather than `/`, which is the
  # path-separator operator the moment the spaces around it are lost.
  #
  # Both ends INCLUSIVE, matching what the bot asserts (SHARD_END < TOTAL_SHARDS
  # and SHARD_START <= SHARD_END).
  ranges =
    n: k:
    let
      per = builtins.div n k;
      rem = n - per * k;
    in
    lib.genList (
      i:
      let
        start = i * per + (lib.min i rem);
      in
      {
        inherit start;
        end = start + per + (if i < rem then 1 else 0) - 1;
      }
    ) k;

  shardRanges = ranges shards instances;

  # THE CHECK ON THE ARITHMETIC ABOVE, and it earns its keep because the default
  # config (1 shard, 1 instance) never exercises the interesting path. Flattening
  # the ranges must reproduce 0..shards-1 exactly, which fails if they overlap,
  # leave a gap, come out unordered, or are off by one at either end.
  #
  # Evaluated on every `nix eval` / `nix flake check`, so a broken edit to
  # `ranges` cannot reach the host.
  partitions = n: k: lib.concatMap (r: lib.range r.start r.end) (ranges n k) == lib.range 0 (n - 1);

  # Exhaustive over every legal pair up to 16 shards rather than a hand-picked
  # table: it covers the even divisions, every remainder, one-shard-each and
  # all-in-one-process without anyone having to think of them, and it costs 136
  # comparisons at eval time.
  brokenCases = lib.filter (c: !partitions c.n c.k) (
    lib.concatMap (n: map (k: { inherit n k; }) (lib.range 1 n)) (lib.range 1 16)
  );

  # ============================================================================
  # Source and image
  # ============================================================================
  # A full commit SHA, deliberately — never a branch or tag name. `main` would
  # make the build depend on when it ran rather than on what this file says, and
  # fetchgit's hash would then start failing on someone else's push.
  #
  # This is main@HEAD as of 2026-09-17. NOT the newest tag: v0.3.0 is well behind
  # main, and the sharding, redis and ai-deepseek work this module configures all
  # landed after it. Revisit if upstream starts cutting releases that include
  # them.
  #
  # Taken for the trace fields the grafana dashboards group on. Spans record
  # `guild_name` and `author_name` alongside the snowflakes — a leaderboard
  # keyed on an id is a list of numbers nobody can read — plus a `links` count,
  # and `attachments` as an integer rather than a string, which is what makes
  # `sum_over_time()` able to add it up at all.
  #
  # Before that (upstream PR #2): `guild_id` became a snowflake (`0` in DMs)
  # instead of the Debug of `Option<GuildId>`, which was splitting every
  # per-guild figure across two values, and spans stopped carrying the whole
  # serenity `Message` — author object, avatar hashes and the message text were
  # going into tempo on every message.
  #
  # Bump with:
  #   gh api repos/1Git2Clone/serenity-discord-bot/commits/main --jq .sha
  #   nix run nixpkgs#nix-prefetch-git -- \
  #     --url https://github.com/1Git2Clone/serenity-discord-bot --rev <sha> --quiet
  #
  # Both lines change together. A rev without its matching hash fails the fetch
  # at build time, which is the good failure — the bad one would be a stale hash
  # silently reusing the old source, and fetchgit does not allow that.
  rev = "bd6de38e554d6680b99ba3ebefc805a065e3da01";

  src = pkgs.fetchgit {
    url = "https://github.com/1Git2Clone/serenity-discord-bot";
    inherit rev;
    hash = "sha256-syaU3M1gcB5M6V8qIYto2oRNRGVMTqfNCCfkUiwGqd8=";
    # build.rs is only a `cargo:rerun-if-changed=migrations`, so nothing in the
    # build reads git metadata.
    leaveDotGit = false;
  };

  # The rev is IN THE TAG, and that is the mechanism that makes a version bump
  # work: bumping `rev` changes this string, which changes the container units,
  # which is what makes systemd recreate them. Same
  # store-path-changes-recreate-the-container trick default.nix relies on for
  # config files.
  # Build args are part of the identity, not just the rev: the builder unit's
  # `docker image inspect ${tag}` guard short-circuits on an existing tag, so a
  # tag keyed on rev alone silently keeps a binary compiled with the OLD
  # FEATURES. That fails quietly - env vars still update, only the compiled-in
  # provider does not.
  tag = "serenity-discord-bot:${builtins.substring 0 12 rev}-${
    builtins.substring 0 8 (builtins.hashString "sha256" "${features} ${rustflags}")
  }";

  features = "ai-openrouter opentelemetry tokio_console";

  # MUST be passed explicitly, and it is not obvious why.
  #
  # The bot's .cargo/config.toml sets rustflags = ["--cfg" "tokio_unstable"],
  # but its Dockerfile does `ARG RUSTFLAGS=""` then `ENV RUSTFLAGS=${RUSTFLAGS}`
  # — and cargo lets a SET-BUT-EMPTY RUSTFLAGS override build.rustflags from the
  # config file entirely. Taking the default therefore drops --cfg
  # tokio_unstable and the tokio_console feature fails to compile. Upstream's
  # own compose passes this for the same reason.
  rustflags = "--cfg tokio_unstable";

  names = lib.genList (i: "serenity-bot-${toString i}") instances;

  # src/main.rs:18 is `let _ = dotenv::dotenv()?;`. The `?` propagates, so the
  # bot REFUSES TO START unless a dotenv file exists on disk — even though every
  # variable it needs is already in the process environment. It is the FIRST
  # fallible call in main, before tracing is initialised, so the entire failure
  # is one unattributed line followed by exit 1 on a five-second restart loop:
  #
  #   Error: Io(Custom { kind: NotFound, error: "path not found" })
  #
  # Nothing names the file, which is what makes it a bad half hour. Upstream
  # wants `dotenv().ok()`; until then this file is the workaround.
  #
  # Deliberately EMPTY. Configuration still arrives as real environment
  # variables from environmentFiles and `environment` below, and dotenv does not
  # override an already-set variable — so writing the credentials in here too
  # would be redundant, would put them somewhere sops does not manage, and would
  # subject them to dotenv's parsing rules (an unquoted `#` in a password ends
  # the value). An empty file in the world-readable Nix store gives away
  # nothing, which is the point.
  dotenvPlaceholder = pkgs.writeText "serenity-dotenv-placeholder" "";

  docker = "${config.virtualisation.docker.package}/bin/docker";

  # Shared by the activation script and the builder unit, which run it at
  # different points of a switch for different reasons — see the comment above
  # `systemd.services` below.
  #
  # The guard is what keeps a routine redeploy from spending 20 minutes
  # rebuilding Rust: an unchanged rev means an unchanged tag, so this exits 0.
  # It is also what makes running this twice in one switch free.
  #
  # No --pull: upstream's runtime base is debian:bullseye-slim, a MOVING tag.
  # Refreshing it would change the runtime image underneath a rev that is
  # supposed to be pinned.
  buildImage = pkgs.writeShellScript "serenity-bot-build-image" ''
    set -eu

    if ${docker} image inspect ${tag} >/dev/null 2>&1; then
      echo "${tag} already built"
      exit 0
    fi

    ${docker} build \
      --build-arg RUSTFLAGS=${lib.escapeShellArg rustflags} \
      --build-arg FEATURES=${lib.escapeShellArg features} \
      -t ${tag} \
      ${src}
  '';
in
{
  assertions = [
    {
      assertion = shards >= 1 && instances >= 1;
      message = "serenity-bot: shards and instances must both be >= 1 (got ${toString shards} and ${toString instances}).";
    }
    {
      assertion = instances <= shards;
      message = ''
        serenity-bot: instances (${toString instances}) exceeds shards (${toString shards}),
        which would leave an instance owning an empty shard range. The bot
        asserts SHARD_START <= SHARD_END at startup and would panic.
      '';
    }
    {
      assertion = brokenCases == [ ];
      message = ''
        serenity-bot: the shard range arithmetic does not partition 0..n-1 for
        (shards, instances) = ${lib.generators.toPretty { } brokenCases}.
        Shards would be double-covered or dropped entirely, which shows up as
        missing gateway events rather than as an error. Fix `ranges`.
      '';
    }
  ];

  sops.secrets = {
    serenity_bot_token.key = "serenity/bot_token";
    serenity_ai_api_key.key = "serenity/ai_api_key";
  };

  # The password is interpolated into DATABASE_URL rather than passed via
  # DB_PASSWORD: the bot reads DATABASE_URL directly, and the DB_* variables
  # exist only for docker-compose to compose one. Everything here reaches the
  # container as an env FILE at runtime, never as a Nix string.
  sops.templates."serenity-bot.env".content = ''
    BOT_TOKEN=${config.sops.placeholder.serenity_bot_token}
    AI_API_KEY=${config.sops.placeholder.serenity_ai_api_key}
    DATABASE_URL=postgres://serenity:${config.sops.placeholder.serenity_db_password}@${botGateway}:6432/serenity_bot
  '';

  virtualisation.oci-containers.containers =
    lib.listToAttrs (
      lib.genList (
        i:
        lib.nameValuePair "serenity-bot-${toString i}" {
          image = tag;

          # never, not the default "missing". Both find the local tag, but
          # `missing` would fall through to a registry lookup for a tag that
          # exists nowhere and report whatever the registry says — `never`
          # fails with the actual problem, which is that the builder unit
          # did not run.
          pull = "never";

          environment = {
            OTEL_EXPORTER_OTLP_ENDPOINT = "http://${botGateway}:4317";
            OTEL_SERVICE_NAME = "serenity-discord-bot";

            # By container name over docker's embedded DNS on botNetwork, the
            # same way caddy reaches its upstreams.
            REDIS_URL = "redis://serenity-redis:6379";

            AI_MODEL = "deepseek/deepseek-v4-flash-0731";

            # Here rather than in the sops env FILE: docker's --env-file takes
            # everything after `=` literally, so `AI_MAX_TOKENS="1000"` there
            # reaches the bot as the 6-character string `"1000"` and its
            # `parse::<u32>()` fails on the leading quote (it then falls back to
            # 150, which is the cap that produces empty replies). Nix strings in
            # `environment` become real `-e` values with no literal quotes.
            #
            # 1000 is above the ~320-450 reasoning tokens deepseek-v4-flash
            # spends before emitting content at this prompt size; at 150 it
            # returned empty 2/2, at 800 it was clean 2/2.
            AI_MAX_TOKENS = "1000";

            RUST_LOG = "warn,serenity_discord_bot=warn,serenity=warn,poise=warn,tokio::task=off";

            # --read-only leaves nothing writable but the tmpfs below, and a
            # library that caches into $HOME would otherwise try /root and get
            # EROFS. Pointing both at the tmpfs costs nothing and keeps the
            # read-only root honest.
            HOME = "/tmp";
            TMPDIR = "/tmp";

            # Without this the console-subscriber binds CONTAINER loopback,
            # which nothing can reach — a build feature paid for and inert. The
            # publish below is what makes it reachable, host-loopback only.
            TOKIO_CONSOLE_BIND = "0.0.0.0:6669";
          }
          # At shards = 1, instances = 1 this stays EMPTY, so main.rs falls to
          # its `else` branch — client.start(), the single-shard path that has
          # been running in production.
          #
          # Worth keeping: the explicit path leans on a quirk. main.rs passes
          # Rust's exclusive `start..end` to start_shard_range and relies on
          # serenity treating range.end as INCLUSIVE. That is upstream's
          # documented intent and they run it, but there is no reason to route
          # the default deploy through it.
          // lib.optionalAttrs (shards > 1 || instances > 1) (
            let
              r = lib.elemAt shardRanges i;
            in
            {
              TOTAL_SHARDS = toString shards;
              SHARD_START = toString r.start;
              SHARD_END = toString r.end;
            }
          );

          environmentFiles = [ config.sops.templates."serenity-bot.env".path ];

          # Loopback only, and one port per instance — two instances would
          # otherwise collide on the host port and the second container would
          # fail to start. Same pattern as minecraft's RCON.
          ports = [ "127.0.0.1:${toString (6669 + i)}:6669" ];

          networks = [ botNetwork ];

          # The image's WORKDIR is /app, and dotenv searches the working
          # directory upward — so this is where it looks. See the comment on
          # dotenvPlaceholder: the file is empty and exists only so that
          # `dotenv::dotenv()?` returns Ok.
          #
          # This is the ONLY mount. No data volume: everything durable lives in
          # postgres, which is backed up as a dump rather than as a directory
          # (modules/postgres.nix). A bind mount is unaffected by --read-only.
          volumes = [ "${dotenvPlaceholder}:/app/.env:ro" ];

          extraOptions = [
            "--read-only"
            "--security-opt=no-new-privileges:true"
            "--cap-drop=ALL"
            # 16m, the same as every other hardened container here. Nothing
            # known writes anything large: /ai-review is dead upstream (see the
            # chore/remove-ai-review-issue-40 branch), and `tempfile` is only
            # pulled in by util-download, which is not in FEATURES. Enabling
            # util-download would want a bigger tmpfs — it writes media here.
            "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m"
          ];
        }
      ) instances
    )
    // {
      # A cache with a documented fallback to fetching from Discord, so it gets
      # NO volume: persisting it buys nothing and would put an entry under
      # /var/lib/docker/volumes that restic then carries forever.
      serenity-redis = {
        image = "redis:8-alpine";
        networks = [ botNetwork ];
        extraOptions = [
          "--read-only"
          "--security-opt=no-new-privileges:true"
          "--cap-drop=ALL"
          "--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=16m"
          # Redis writes its pidfile and any accidental dump here.
          "--tmpfs=/data:rw,nosuid,nodev,size=64m"
        ];
        cmd = [
          "redis-server"
          # In-memory only, matching the no-volume decision: without this redis
          # periodically forks to write /data/dump.rdb onto the tmpfs above.
          "--save"
          ""
          "--appendonly"
          "no"
          "--maxmemory"
          "256mb"
          "--maxmemory-policy"
          "allkeys-lru"
        ];
      };
    };

  # ============================================================================
  # The build
  # ============================================================================
  # Two steps, as separate units: this one compiles, the container units run.
  #
  # Source arrives hash-pinned through fetchgit while the build itself stays
  # upstream's own two-stage Dockerfile — so their build knowledge is not
  # duplicated in Nix and a bump is one rev plus one hash.
  # THE IMAGE IS BUILT IN ACTIVATION, and the builder unit below is the fallback
  # rather than the usual path. That is the whole trick to deploying without an
  # outage, and it needs the phase order of switch-to-configuration to explain:
  #
  #   1. stop jobs          <- the bot is NOT here; see stopIfChanged below
  #   2. the activate script
  #   3. sysinit-reactivation.target
  #   4. reload jobs
  #   5. restart jobs       <- the bot stops and starts HERE
  #
  # Step 2 is the only hook that runs while the old container is still serving,
  # so it is the only place a five-minute compile is free. By the time the
  # restart in step 5 comes round, the tag exists and the swap is seconds.
  #
  # `stopIfChanged = false` (X-StopIfChanged=false) is what keeps the bot out of
  # step 1 so it survives to step 2. It is necessary and NOT sufficient: a
  # systemd restart job is a stop followed by a start, and ordering is REVERSED
  # for the stop half — the containers' After= on the builder means they stop
  # BEFORE it, so in step 5 the bot goes down, the builder then compiles, and
  # only then does the bot come back. Marking the units alone moved the outage
  # from step 1 to step 5; it did not remove it. Both containers and builder
  # still need the flag, because Requires= propagates a stop.
  #
  # The deploy takes just as long. It is the outage that goes away, not the wait.
  #
  # On BOOT there is no old container to protect and docker is not up yet when
  # activation runs, so the script no-ops and the unit does the build — which is
  # what the unit is for.
  system.activationScripts.serenity-bot-image = {
    deps = [ ];
    text = ''
      if ${docker} info >/dev/null 2>&1; then
        ${buildImage}
      else
        echo "serenity-bot: docker not up, leaving the image to serenity-bot-image.service"
      fi
    '';
  };

  systemd.services =
    lib.genAttrs (map (n: "docker-${n}") names) (_: {
      stopIfChanged = false;
    })
    // {
      serenity-bot-image = {
        stopIfChanged = false;
        description = "Build the serenity-discord-bot image (${builtins.substring 0 12 rev})";
        wantedBy = [ "multi-user.target" ];
        after = [
          "docker.service"
          "docker.socket"
        ];
        requires = [ "docker.service" ];
        before = map (n: "docker-${n}.service") names;
        requiredBy = map (n: "docker-${n}.service") names;
        path = [ config.virtualisation.docker.package ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # MEASURED at 3m28s on this host from a cold cache (2026-09-04), base
          # image pulls included. 10min is ~3x that; systemd's default would kill
          # it partway.
          #
          # Kept BELOW deploy-rs's activationTimeout (900s in flake.nix). The
          # usual build now happens in the activation script, which deploy-rs
          # times out directly; this bound covers the boot path, where nothing
          # else would ever stop a wedged build.
          TimeoutStartSec = "10min";
        };

        # Normally a no-op: activation built the image several steps earlier and
        # the guard inside exits 0. This is the boot path, and the backstop for
        # anything that reaches the unit without having gone through a switch.
        script = "${buildImage}";
      };
    };
}
