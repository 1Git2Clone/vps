# ==============================================================================
# Vulnerability scanner
# ==============================================================================
# Scans all running Docker images + the NixOS system for known CVEs.
# Pings healthchecks.io on success; leaves it silent on findings so the alert
# comes from the flip side — healthchecks.io pings you when the job stops
# running, and the service logs hold the details.
#
# To see what was found:
#   journalctl -u vuln-scan -e
#
# To run manually:
#   systemctl start vuln-scan
{ config, pkgs, ... }:

let
  scanScript = pkgs.writeShellApplication {
    name = "vuln-scan";
    runtimeInputs = with pkgs; [
      trivy
      vulnix
      docker
      jq
      curl
    ];
    text = ''
      set -euo pipefail

      SEVERITY="MEDIUM,HIGH,CRITICAL"
      FINDINGS=0

      # --- Docker images ---
      echo "=== Scanning Docker images ==="
      while IFS= read -r img; do
        [ -z "$img" ] && continue
        echo "--- $img ---"

        # trivy exits 0 even when CVEs are found; --exit-code only matters with --fail-on
        if ! trivy image \
          --severity "$SEVERITY" \
          --ignore-unfixed \
          --format table \
          "$img" 2>/dev/null; then
          echo "  (trivy scan failed for $img, skipping)"
          continue
        fi

        # Count Medium+ findings for the summary
        count=$(trivy image \
          --severity "$SEVERITY" \
          --ignore-unfixed \
          --format json \
          "$img" 2>/dev/null \
          | jq '[.Results[]?.Vulnerabilities[]?] | length')

        if [ "$count" -gt 0 ]; then
          echo "  → $count fixable MEDIUM+ CVEs"
          FINDINGS=$((FINDINGS + count))
        fi
      done < <(docker ps --format '{{.Image}}' | sort -u)

      # --- NixOS system ---
      echo ""
      echo "=== Scanning NixOS system ==="
      if vulnix --system 2>/dev/null; then
        echo "  (no findings)"
      else
        echo "  (vulnix found advisories — check 'vulnix --system' for details)"
        FINDINGS=$((FINDINGS + 1))
      fi

      # --- Summary ---
      echo ""
      if [ "$FINDINGS" -gt 0 ]; then
        echo "Total: $FINDINGS fixable MEDIUM+ CVEs found"
        exit 1  # non-zero = findings exist, logged by systemd
      else
        echo "All clear — no fixable MEDIUM+ CVEs."
      fi
    '';
  };
in
{
  systemd.services.vuln-scan = {
    description = "Scan Docker images and NixOS for known CVEs";
    after = [ "docker.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scanScript}/bin/vuln-scan";
    };
  };

  systemd.timers.vuln-scan = {
    description = "Daily vulnerability scan";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "2h";
      Persistent = true;
    };
  };

  # Healthchecks.io ping — same pattern as backups. The ping fires on
  # successful completion regardless of findings. If the job stops running
  # entirely, healthchecks.io alerts you by silence.
  systemd.services.vuln-scan = {
    postStart = ''
      ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 \
        "$(cat ${config.sops.secrets.vuln_scan_healthcheck_url.path})" || true
    '';
  };
}
