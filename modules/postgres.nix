# ==============================================================================
# PostgreSQL — on the host, behind pgbouncer
# ==============================================================================
# The first database on this box, and the first service whose data is NOT a
# named docker volume. That breaks the invariant modules/containers/default.nix
# relies on ("restic backs up /var/lib/docker/volumes wholesale, so a new
# service is covered the moment it declares a volume"), so the backup below is
# not optional — it is the only thing covering this data, and its path is in
# modules/backups.nix. A file-level copy of a live PGDATA would not restore
# cleanly anyway; dumps are the right artifact, not a workaround.
#
# On the host rather than in a container so a second service can share it
# without either one owning the other's volume.
{
  config,
  pkgs,
  ...
}:

let
  db = "serenity_bot";
  # Matches the owner recorded in the pg_dump being restored. A plain-SQL dump
  # emits `ALTER TABLE ... OWNER TO <role>`, which hard-fails under
  # ON_ERROR_STOP if the role is absent — so the dump decides this name, and
  # renaming it means rewriting the dump. See "Restoring a postgres dump into a
  # new service" in docs/deploying.md.
  role = "serenity";

  passwordFile = config.sops.secrets.serenity_db_password.path;
in
{
  # Declared here rather than in modules/secrets.nix because this module owns
  # the database identity; the bot's own token and API key live next to the
  # container that reads them. Nested key to match the layout of secrets.yaml.
  sops.secrets.serenity_db_password = {
    key = "serenity/db_password";
    # owner matters: the setup unit below runs as `postgres` so it can use peer
    # auth, and a sops secret defaults to root:0400 — which made the first
    # deploy of this module fail with
    #   cat: /run/secrets/serenity_db_password: Permission denied
    # The alternative, running the unit as root, does not work: peer auth maps
    # the OS user to a same-named role and there is no `root` role.
    owner = "postgres";
    mode = "0400";
  };

  # pgbouncer authenticates BOTH legs from this file: SCRAM to the client, SCRAM
  # to postgres. A template rather than a fourth secret so the password has one
  # source of truth.
  #
  # It cannot go inline in services.pgbouncer.settings. That module does
  # `environment.etc.<path>.source = configFile`, which puts the whole ini in
  # the WORLD-READABLE Nix store — exactly what modules/options.nix warns about.
  sops.templates."pgbouncer-userlist.txt" = {
    content = ''
      "${role}" "${config.sops.placeholder.serenity_db_password}"
    '';
    owner = "pgbouncer";
    mode = "0400";
  };

  services = {
    postgresql = {
      enable = true;
      # Upstream's compose runs postgres:18.3; this is 18.6. Same major, so the
      # pg_dump being restored loads without a version dance.
      package = pkgs.postgresql_18;

      ensureDatabases = [ db ];

      # No ensureDBOwnership: nixpkgs asserts it is only usable when the role
      # name EQUALS the database name, and these two are independent here
      # because the dump decides both (upstream's .env.example keeps DB_USER and
      # DB_NAME separate). Ownership is set alongside the password below
      # instead, which costs one statement and leaves the names free.
      ensureUsers = [ { name = role; } ];

      # enableTCPIP is left at its default false, which resolves
      # listen_addresses to "localhost". pgbouncer reaches this over the unix
      # socket and is the only thing the bot's network can talk to, so there is
      # one listener to reason about instead of two.

      # Added rules are inserted ABOVE the module's generated defaults, so this
      # lands ahead of `local all all peer` — which would otherwise try to map
      # the pgbouncer OS user onto the `serenity` database role and fail.
      authentication = ''
        local ${db} ${role} scram-sha-256
      '';

      # Postgres 18 already defaults to this. Spelled out because it decides
      # what the ALTER ROLE below actually stores, and it has to agree with
      # pgbouncer's auth_type: a default moving underneath that pair breaks
      # authentication at some later upgrade rather than at the commit that
      # caused it.
      settings.password_encryption = "scram-sha-256";
    };

    # ==========================================================================
    # pgbouncer
    # ==========================================================================
    # openFirewall is deliberately NOT set. It writes to
    # networking.firewall.allowedTCPPorts, which lands in the `nixos-fw` table
    # that modules/firewall.nix deletes and redefines — so it would evaluate
    # cleanly and open nothing. The rule is in that ruleset instead.
    pgbouncer = {
      enable = true;

      settings = {
        pgbouncer = {
          listen_port = 6432;

          # `*`, not the bot network's gateway address.
          #
          # Binding 172.30.0.1 is the trap modules/containers/tempo.nix
          # documents: a specific address that does not exist yet fails with
          # "cannot assign requested address", and the docker bridge is created
          # by a unit this would then have to be ordered against. Kept private
          # by the firewall's input chain — the same posture as tempo's 4317 and
          # grafana's 3000.
          #
          # Consequence, stated rather than discovered: the input chain accepts
          # `iifname tailscale0` wholesale, so 6432 is reachable from the tailnet
          # with a password. That is what makes a dump restore verifiable with
          # psql from a laptop.
          listen_addr = "*";

          pool_mode = "transaction";

          # THE SETTING TRANSACTION MODE DEPENDS ON.
          #
          # sqlx 0.9 keeps a 100-entry prepared-statement cache per connection.
          # Transaction pooling hands the server connection back at commit, so a
          # cached `sqlx_s_N` vanishes from under the client and the next use
          # dies with `prepared statement "sqlx_s_7" does not exist`. pgbouncer
          # tracks named prepared statements and re-prepares them on whichever
          # backend it assigns, which makes that transparent.
          #
          # It has defaulted to 200 since pgbouncer 1.24 (1.25.2 is what nixpkgs
          # 26.05 carries), so this pins a value that currently works. Do not
          # drop it on the grounds that it matches the default: the failure it
          # prevents is intermittent and load-dependent, not a startup error.
          max_prepared_statements = 200;

          auth_type = "scram-sha-256";
          # A path into /run, never an inline value — see the template above.
          auth_file = config.sops.templates."pgbouncer-userlist.txt".path;

          # One bot process with an sqlx pool, so the defaults are already
          # generous against postgres's max_connections of 100.
          max_client_conn = 100;
          default_pool_size = 20;
        };

        # Over the unix socket, so postgres itself never needs a TCP listener
        # beyond loopback. No user= or password= here: pgbouncer connects as the
        # client's own role using the userlist, and anything written here would
        # land in the Nix store.
        databases.${db} = "host=/run/postgresql port=5432 dbname=${db}";
      };
    };

    # ==========================================================================
    # Backups — the declarative answer to "a dump per service"
    # ==========================================================================
    # `databases` left at its default [] flips `backupAll`, which runs
    # pg_dumpall. That is the point: it covers EVERY database on this host,
    # including ones added years from now, so a future service is backed up the
    # moment it declares a database. Same "nothing to remember to add to a path
    # list" invariant that /var/lib/docker/volumes gives the container services.
    #
    # pg_dumpall also emits globals — roles and their SCRAM verifiers — so a
    # restore brings the accounts back with the data. The rest of a service's
    # environment is already in git as encrypted secrets.yaml.
    #
    # Restore: zstd -d < /var/backup/postgresql/all.sql.zst | psql -U postgres
    postgresqlBackup = {
      enable = true;
      compression = "zstd";

      # 23:15 IS LOAD-BEARING, and the failure is silent.
      #
      # services.restic.backups.b2 is OnCalendar=daily with
      # RandomizedDelaySec=1h, so it fires somewhere in 00:00-01:00. The stock
      # startAt of 01:15 is AFTER that window, which would have restic archiving
      # a dump up to 23 hours stale every night while both units report success.
      # Anything in the evening works; moving this past midnight breaks it.
      #
      # An independent timer rather than restic's backupPrepareCommand on
      # purpose: that runs as ExecStartPre, so one transient pg_dumpall failure
      # would abort the entire nightly backup of every other service.
      startAt = "*-*-* 23:15:00";
    };
  };

  systemd.services = {
    # ensureUsers creates the role with NO password, and
    # ensureUsers.*.passwordFile does not exist in nixpkgs 26.05 — it was
    # deprecated and removed. pgbouncer needs a real password to present, so it
    # is set on every activation.
    #
    # services.postgresql.initialScript is not a substitute: it runs only at
    # first initdb, so it would silently not apply to a cluster that already
    # exists — which is the state right after a dump restore.
    postgresql-serenity-setup = {
      description = "Set the ${role} role password and give it ${db}";
      wantedBy = [ "multi-user.target" ];
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      path = [ config.services.postgresql.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
        Group = "postgres";
      };
      # :'pw' is psql's QUOTED variable interpolation — it escapes the value as
      # a SQL literal, so a password containing a quote cannot break the
      # statement or inject into it. Interpolating $pw in shell instead would.
      #
      # THE SQL GOES OVER STDIN, NOT -c. psql does not perform variable
      # interpolation on a -c string: the server receives a literal :'pw' and
      # answers `ERROR: syntax error at or near ":"`, which is exactly how the
      # first deploy of this module failed. Interpolation only happens for
      # input read as a script — stdin or -f. Verified both ways before
      # settling on this.
      #
      # The second statement is here because ensureDBOwnership cannot be used
      # when the role and database names differ. Both are idempotent.
      script = ''
        printf '%s\n' \
          "ALTER ROLE ${role} WITH PASSWORD :'pw';" \
          "ALTER DATABASE ${db} OWNER TO ${role};" \
          | psql -v ON_ERROR_STOP=1 -v pw="$(cat ${passwordFile})"
      '';
    };

    pgbouncer = {
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
    };
  };
}
