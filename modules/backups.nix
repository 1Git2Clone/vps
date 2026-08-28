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

    paths = [ "/var/lib" ];
    exclude = [
      "/var/lib/docker"
      "/var/lib/sops-nix"
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
}
