{ config, pkgs, ... }:

{
  sops.templates."restic-b2.env".content = ''
    B2_ACCOUNT_ID=${config.sops.placeholder.backups_b2_account_id}
    B2_ACCOUNT_KEY=${config.sops.placeholder.backups_b2_account_key}
  '';

  services.restic.backups.b2 = {
    initialize = true;

    repositoryFile = config.sops.secrets.backups_restic_repository.path;
    passwordFile = config.sops.secrets.backups_restic_password.path;
    environmentFile = config.sops.templates."restic-b2.env".path;

    # Every service's data is a named docker volume, so this one path covers
    # all of them — including a service added later, which is the point. A
    # backup that has to be told about each new service is a backup that
    # eventually stops covering one.
    #
    # The second path is the same trick for databases. postgres runs on the host
    # (modules/postgres.nix), so its data is NOT under docker/volumes and would
    # have silently fallen out of this backup. services.postgresqlBackup writes
    # a pg_dumpall there — every database on the host, globals included — so a
    # future service is covered the moment it declares one. A file-level copy of
    # a live PGDATA would not restore cleanly anyway.
    #
    # ORDERING: this job is OnCalendar=daily with RandomizedDelaySec=1h, so it
    # fires in 00:00-01:00. postgresqlBackup therefore runs at 23:15, BEFORE it.
    # Moving that past midnight would have restic archive a dump up to 23 hours
    # stale every night while both units report success.
    paths = [
      "/var/lib/docker/volumes"
      "/var/backup/postgresql"
    ];

    # The minecraft world is snapshotted separately, with the server stopped —
    # see the `minecraft` backup below. Copying a live world is exactly what
    # that job exists to avoid.
    exclude = [
      "/var/lib/docker/volumes/minecraft_data"
    ];

    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };

    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];

    runCheck = true;

    backupCleanupCommand = ''
      #!${pkgs.runtimeShell}
      [ "$SERVICE_RESULT" = success ] || exit 0
      ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 \
        "$(cat ${config.sops.secrets.backups_healthcheck_url.path})" || true
    '';
  };

  # The weekly quiescent minecraft snapshot, ported from scripts/mc-backup.sh.
  # Same repository, same password — restic deduplicates against the daily
  # snapshots, so the overlap costs almost nothing.
  #
  # Ordinary file copies of a running world are not consistent: the server holds
  # region files open and writes them in place. Stopping it is the only way to
  # get a snapshot that restores cleanly. The container's --stop-timeout is what
  # gives it long enough to finish saving.
  services.restic.backups.minecraft = {
    initialize = false;

    repositoryFile = config.sops.secrets.backups_restic_repository.path;
    passwordFile = config.sops.secrets.backups_restic_password.path;
    environmentFile = config.sops.templates."restic-b2.env".path;

    paths = [ "/var/lib/docker/volumes/minecraft_data" ];

    timerConfig = {
      OnCalendar = "Sun 04:00";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };

    # Pruning belongs to the daily job alone. Two jobs pruning the same
    # repository on their own retention policies fight over each other's
    # snapshots.
    backupPrepareCommand = ''
      ${config.systemd.package}/bin/systemctl stop docker-minecraft.service
    '';

    # Runs from ExecStopPost, so unlike the healthcheck ping in the daily job
    # it is unconditional: the server must come back whether restic succeeded
    # or not.
    backupCleanupCommand = ''
      ${config.systemd.package}/bin/systemctl start docker-minecraft.service
    '';
  };
}
