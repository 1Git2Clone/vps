# ==============================================================================
# Vulnerability scanner
# ==============================================================================
# Two scanners, because the two targets need different tools:
#   * trivy — every DECLARED container image, running or not.
#   * syft + grype — the NixOS system closure (tailscale, sshd, docker, the
#     kernel). NOT vulnix: it resolves each store path to its .drv, and
#     deploy-rs copies build outputs rather than derivations, so on a deployed
#     host it fails outright. syft reads the store paths themselves.
#
# Reports to Discord as AT MOST TWO messages:
#
#   1. Summary + the critical/high findings, each CVE linked to its registry,
#      with the complete report attached as a single markdown file.
#   2. Only when the critical/high list does not fit in one message.
#
# Everything else — medium/low, unfixable, and the full package inventory —
# lives in that one attachment rather than in the channel.
#
# Interactive button pagination is deliberately absent: Discord accepts only
# NON-interactive components from a webhook that no application owns, and
# answering a button press requires a running bot to reply to the interaction
# within three seconds. A oneshot systemd unit cannot. The attached file is the
# honest substitute.
#
# A scan that cannot run (Trivy DB download failure, docker down, image pull
# error) is reported as a FAILURE — it never silently degrades into "0 CVEs".
#
# Runs weekly, Saturday 06:00 UTC. To run manually:
#   systemctl start vuln-scan && journalctl -u vuln-scan -f
{ config, lib, pkgs, ... }:

let
  # Every image this host declares, straight from the container config. This is
  # the difference between scanning what is RUNNING and scanning what is
  # DEPLOYED: `docker ps` misses a container that is stopped, crashed, or
  # waiting on a dependency, and those images are still on disk and still get
  # started again later. A scan that quietly skips them is the failure mode this
  # whole module exists to avoid.
  declaredImages = lib.unique (
    lib.mapAttrsToList (_n: c: c.image) config.virtualisation.oci-containers.containers
  );

  # Include every package scanned, with its version and its CVEs, as a section
  # of the attached report. This is what makes an all-clear verifiable rather
  # than merely asserted — and it now costs file size, not Discord messages.
  fullInventory = true;

  reportJq = pkgs.writeText "vuln-report.jq" ''
    # ---------------------------------------------------------------------------
    # Input : { meta: {...}, results: [ target, ... ] }
    #   target = { source, kind, ok, error, running, packages:[{name,version}],
    #              cves: [{id,severity,pkg,installed,fixed}] }
    #
    # meta.mode = "payload"  -> ONE Discord webhook payload (embeds only)
    #             "markdown" -> the complete report, as a file to attach
    #
    # Discord's 6000-character budget is shared across ALL embeds in a message, and
    # a non-application webhook cannot send interactive components (no buttons, so
    # no click-through pagination). Hence: one message carrying the summary and the
    # findings you can act on, with everything else in the attached file.
    # ---------------------------------------------------------------------------

    def sev_rank:      {"CRITICAL":0,"HIGH":1,"MEDIUM":2,"LOW":3,"UNKNOWN":4}[.] // 5;
    def sev_emoji:     {"CRITICAL":"🔴","HIGH":"🟠","MEDIUM":"🟡","LOW":"🔵","UNKNOWN":"⚪"}[.] // "⚪";

    def target_icon:
      if .kind == "system" then "❄️"
      elif .running == false then "💤"
      else "🐳" end;

    def cve_url:
      if   startswith("CVE-")     then "https://nvd.nist.gov/vuln/detail/" + .
      elif startswith("GHSA-")    then "https://github.com/advisories/" + .
      elif startswith("RUSTSEC-") then "https://rustsec.org/advisories/" + . + ".html"
      else "https://osv.dev/vulnerability/" + . end;

    def link: "[`" + . + "`](" + cve_url + ")";

    # EPSS is a probability in [0,1]; render it the way a human reads risk.
    def pct_str: if . == null then "n/a" else ((. * 1000 | round) / 10 | tostring) + "%" end;

    # EPSS thresholds SCALED BY SEVERITY. A critical worth 0.5% exploit probability
    # deserves a look; a low needs to be near-certain before it does. This is what
    # silences the perpetual noise — Debian "affected, will not fix" entries from
    # 2005, and CPE collisions like util-linux `flock` matching the 2006 Flock
    # browser — without hiding anything: everything still appears in the report file.
    # Gating on the PERCENTILE rather than the raw probability: percentiles are
    # self-normalising, so the bar does not drift as EPSS is recalibrated, and
    # "top 10% most likely to be exploited" is a claim that survives restating.
    # CVE-2025-68121 — CVSS 10.0, EPSS 0.0077 — sits at the 52nd percentile and is
    # excluded by every row of this table, which is the correct answer.
    def gate:
      {"CRITICAL": 0.90, "HIGH": 0.95, "MEDIUM": 0.98, "LOW": 0.99, "UNKNOWN": 0.99}[.] // 0.99;

    # A finding earns a place in the channel if it is known-exploited, or if its
    # exploit percentile clears the bar for its severity.
    def matched: .kev or ((.pct // 0) >= (.severity | gate));
    def trunc($n): if (length > $n) then (.[0:$n - 1] + "…") else . end;
    def short: (. | split("/") | .[-1] | trunc(28));

    def chunk_lines($max):
      reduce .[] as $l ([];
        if length == 0 then [[$l]]
        else . as $acc | ($acc[-1]) as $cur
        | if ((($cur | join("\n") | length) + 1 + ($l | length)) > $max)
             or (($cur | length) >= 15)
          then $acc + [[$l]]
          else $acc[0:-1] + [$cur + [$l]] end
        end);

    . as $in
    | $in.results as $R
    | ($R | map(.cves | length) | add // 0)     as $total
    | ($R | map(.packages | length) | add // 0) as $pkgtotal
    | ($R | map(select(.ok | not)))             as $failures
    | ($failures | length)                      as $failed
    | ($R | map([.cves[] | select(.severity == "CRITICAL")] | length) | add // 0) as $crit
    | ($R | map([.cves[] | select(.severity == "HIGH")]     | length) | add // 0) as $high
    | ($R | map([.cves[] | select(.severity == "MEDIUM")]   | length) | add // 0) as $med
    | ($R | map([.cves[] | select(.severity == "LOW")]      | length) | add // 0) as $low
    | ($R | map([.cves[] | select(.severity == "UNKNOWN")]  | length) | add // 0) as $unk
    | ($R | map([.cves[] | select(.fixed != "")] | length) | add // 0) as $fixable
    | ($total - $fixable) as $nofix
    | ($R | map([.cves[] | select(.fixed != "" and (.severity == "CRITICAL" or .severity == "HIGH"))]
                | length) | add // 0) as $urgent

    # The axes that actually predict trouble. CVSS says how bad it would be if
    # exploited; these say whether it is being exploited.
    | ($R | map([.cves[] | select(.kev)] | length) | add // 0)                       as $kevn
    | ($R | map([.cves[] | select((.epss // 0) >= 0.10)] | length) | add // 0)       as $epss10
    | ($R | map([.cves[] | select((.epss // 0) >= 0.01)] | length) | add // 0)       as $epss1
    | ($R | map([.cves[] | select(matched)] | length) | add // 0)                    as $hits
    | ($R | map([.cves[] | select(.epss == null)] | length) | add // 0)              as $unscored

    # Every fixable finding, worst first, tagged with the target it came from.
    | ([$R[] | . as $t | $t.cves[] | select(.fixed != "") | . + {tgt: $t.source}]
       | sort_by([(.severity | sev_rank), .tgt, .pkg, .id])) as $act

    | (if   $failed > 0 then { c: 10038562, t: ("⚠️ Vulnerability Scan — " + ($failed | tostring) + " target(s) FAILED to scan") }
       elif $kevn > 0   then { c: 15158332, t: ("🚨 Vulnerability Scan — " + ($kevn | tostring) + " ACTIVELY EXPLOITED (CISA KEV)") }
       elif $hits > 0   then { c: 15105570, t: ("🟠 Vulnerability Scan — " + ($hits | tostring) + " worth attention") }
       elif $total > 0  then { c: 3066993,  t: ("✅ Vulnerability Scan — nothing above threshold") }
       else                  { c: 3066993,  t: "✅ Vulnerability Scan — All Clear" } end) as $hdr

    | if $in.meta.mode == "markdown" then
    # =============================================================================
    # The complete report — every target, every package, every CVE.
    # =============================================================================
      ( [ "# Vulnerability scan — " + $in.meta.host,
          "",
          "Scanned " + $in.meta.started + " · took " + $in.meta.duration,
          "",
          "## Summary",
          "",
          "| | |",
          "|---|---|",
          "| Targets | " + ($R | length | tostring) + " ("
            + ($R | map(select(.kind == "image")) | length | tostring) + " images, "
            + ($R | map(select(.running == false)) | length | tostring) + " not running) |",
          "| Packages inspected | " + ($pkgtotal | tostring) + " |",
          "| Findings | " + ($total | tostring) + " |",
          "| **Actively exploited (CISA KEV)** | **" + ($kevn | tostring) + "** |",
          "| **Exploit probability >10%** | **" + ($epss10 | tostring) + "** |",
          "| Exploit probability >1% | " + ($epss1 | tostring) + " |",
          "| Fixable now | " + ($fixable | tostring) + " (" + ($urgent | tostring) + " critical/high) |",
          "| No fix available | " + ($nofix | tostring) + " |",
          "| Critical / High / Medium / Low / Unknown | " + ($crit | tostring) + " / "
            + ($high | tostring) + " / " + ($med | tostring) + " / " + ($low | tostring)
            + " / " + ($unk | tostring) + " |",
          "" ]
        + (if $in.meta.db_warning != "" then ["> ⚠️ " + $in.meta.db_warning, ""] else [] end)
        + (if $failed > 0 then
             ["## ⚠️ Targets that failed to scan", "",
              "These contribute NO data to the counts above.", ""]
             + ($failures | map(["### " + .source, "", "```", (.error | trunc(2000)), "```", ""]) | flatten)
           else [] end)
        + ["## Findings by target", ""]
        + ($R | map(
            . as $t
            | ["### " + ($t | target_icon) + " " + $t.source,
               "",
               ($t.packages | length | tostring) + " packages inspected · "
                 + ($t.cves | length | tostring) + " findings · "
                 + ([$t.cves[] | select(.fixed != "")] | length | tostring) + " fixable"
                 + (if $t.running == false then " · _declared but not running_" else "" end),
               ""]
            + (if ($t.cves | length) == 0 then ["_No known vulnerabilities._", ""]
               else
                 ([$t.cves[] | select(.fixed != "")]
                  | sort_by([(if .kev then 0 else 1 end), ((.epss // 0) * -1), (.severity | sev_rank), .pkg, .id])) as $f
                 | ([$t.cves[] | select(.fixed == "")]
                    | sort_by([(if .kev then 0 else 1 end), ((.epss // 0) * -1), (.severity | sev_rank), .pkg, .id])) as $n
                 | (if ($f | length) > 0 then
                      ["#### 🛠️ Fixable (" + ($f | length | tostring) + ")", "",
                       "| EPSS | KEV | Severity | CVE | Package | Installed | Fixed in |",
                       "|---|---|---|---|---|---|---|"]
                      + ($f | map("| " + (.epss | pct_str)
                                  + " | " + (if .kev then "🚨 yes" else "" end)
                                  + " | " + (.severity | sev_emoji) + " " + .severity
                                  + " | " + (.id | link) + " | `" + .pkg + "` | `" + .installed
                                  + "` | **" + .fixed + "** |"))
                      + [""]
                    else [] end)
                 + (if ($n | length) > 0 then
                      ["#### ⏳ No fix available (" + ($n | length | tostring) + ")", "",
                       "| EPSS | KEV | Severity | CVE | Package | Installed |",
                       "|---|---|---|---|---|---|"]
                      + ($n | map("| " + (.epss | pct_str)
                                  + " | " + (if .kev then "🚨 yes" else "" end)
                                  + " | " + (.severity | sev_emoji) + " " + .severity
                                  + " | " + (.id | link) + " | `" + .pkg + "` | `" + .installed + "` |"))
                      + [""]
                    else [] end)
               end)) | flatten)
        + (if $in.meta.inventory == "1" then
             ["## Full package inventory", ""]
             + ($R | map(
                 . as $t
                 | ($t.cves | group_by(.pkg) | map({key: .[0].pkg, value: .}) | from_entries) as $bypkg
                 | ["### " + $t.source, "", "| Package | Version | CVEs |", "|---|---|---|"]
                 + ($t.packages | sort_by(.name) | map(
                     . as $p
                     | ($bypkg[$p.name] // []) as $h
                     | "| `" + $p.name + "` | `" + $p.version + "` | "
                       + (if ($h | length) == 0 then "✅ none"
                          else ($h | sort_by(.severity | sev_rank)
                                | map((.severity | sev_emoji) + (.id | link)) | join(", ")) end)
                       + " |"))
                 + [""]) | flatten)
           else [] end)
        | join("\n") )

    else
    # =============================================================================
    # Discord: AT MOST TWO messages. Critical and high only — with 187 criticals in
    # one mailserver image, listing everything is what produced the 28-message
    # flood. Everything else, and the complete package inventory, is in the single
    # markdown file attached to the first message.
    # =============================================================================
      ( ("**" + ($R | length | tostring) + " targets** · "
         + ($pkgtotal | tostring) + " packages · "
         + ($total | tostring) + " findings"
         + (if ($R | map(select(.running == false)) | length) > 0
            then " · " + ($R | map(select(.running == false)) | length | tostring) + " not running"
            else "" end)
         + "\n\n"
         + "### 🎯 Worth attention: **" + ($hits | tostring) + "**\n"
         + "🚨 KEV **" + ($kevn | tostring) + "**"
         + "  ·  ⚡ EPSS ≥10% **" + ($epss10 | tostring) + "**"
         + "  ·  ≥1% **" + ($epss1 | tostring) + "**\n"
         + "🛠️ " + ($fixable | tostring) + " fixable  ·  ⏳ " + ($nofix | tostring) + " no fix"
         + (if $unscored > 0 then "  ·  ❔ " + ($unscored | tostring) + " unscored" else "" end)
         + "\n\n"
         + "-# Gate: in KEV, or above the EPSS percentile for its severity "
         + "(critical p90 · high p95 · medium p98 · low p99). "
         + "The remaining " + (($total - $hits) | tostring)
         + " are below threshold — mostly unfixable distro entries and stale CPE matches. "
         + "All of them are in the attached report.\n"
         + (if ($failures | length) > 0
            then "\n⚠️ **Failed to scan:** " + ($failures | map(.source | short) | join(", ")) + "\n"
            else "" end)
         + (if ($in.meta.epss_available | not)
            then "\n⚠️ **EPSS feed unavailable — this run is NOT ranked by exploitability.**"
            else "" end)
         + (if ($in.meta.kev_available | not)
            then "\n⚠️ **CISA KEV feed unavailable — actively-exploited CVEs are not flagged.**"
            else "" end)
         + (if $in.meta.db_warning != "" then "\n\n⚠️ **" + $in.meta.db_warning + "**" else "" end)
        ) as $desc

      | { title: $hdr.t, description: $desc, color: $hdr.c,
          footer: { text: "full report attached · " + $in.meta.host + " · " + $in.meta.duration } }
        as $overview

      # Worst offenders, grouped by dependency. Gated entries first; if nothing is
      # gated we still show the highest-scoring few, because "here is the worst we
      # found and it is still negligible" is the reassuring version of an all-clear.
      | ([$R[] | . as $t | $t.cves[] | . + {tgt: $t.source}]
         | group_by([.tgt, .pkg])
         | map({
             tgt: .[0].tgt,
             pkg: .[0].pkg,
             installed: .[0].installed,
             n: length,
             hits: ([.[] | select(matched)] | length),
             kev: ([.[] | select(.kev)] | length),
             maxepss: ([.[] | (.epss // 0)] | max),
             maxpct: ([.[] | (.pct // 0)] | max),
             top: (sort_by([((.epss // 0) * -1)]) | .[0]),
             fix: ([.[] | .fixed | select(. != "")] | sort | last // "")
           })
         | sort_by([(if .kev > 0 then 0 else 1 end), (.hits * -1), (.maxepss * -1)])) as $allg
      | (($allg | map(select(.hits > 0))) as $g
         | if ($g | length) > 0 then $g else ($allg[0:3]) end) as $groups
      | (($allg | map(select(.hits > 0)) | length) == 0) as $below

      | ($groups | map(
          (if .kev > 0 then "🚨" else (.top.severity | sev_emoji) end)
          + " **" + (.pkg | trunc(30)) + "** `" + (.installed | trunc(16)) + "` — "
          + (if .kev > 0 then "**KEV** · " else "" end)
          + "EPSS " + (.maxepss | pct_str)
          + " (p" + ((.maxpct * 100) | floor | tostring) + ")"
          + (if .hits > 0 then " · **" + (.hits | tostring) + "** of " + (.n | tostring)
             else " · " + (.n | tostring) + " CVEs" end)
          + (if .fix == "" then " · *no fix*" else " → **" + (.fix | trunc(16)) + "**" end)
          + "  ·  " + (.tgt | short))) as $lines

      | ($lines | chunk_lines(1000)) as $blocks
      # The summary is now description-only — no field grid to account for.
      | ($overview | [.title, .description, .footer.text] | join("") | length) as $ovc

      # How many whole blocks fit in a budget, stopping at the first that does not.
      | ($blocks | length) as $nb
      | (reduce range(0; $nb) as $i ({n: 0, used: 0};
           (($blocks[$i] | join("\n") | length) + 30) as $l
           | if (.n == $i) and ((.used + $l) <= (5700 - $ovc)) and (.n < 8)
             then {n: (.n + 1), used: (.used + $l)} else . end) | .n) as $n1
      | ($blocks[$n1:]) as $rest
      | (reduce range(0; ($rest | length)) as $i ({n: 0, used: 0};
           (($rest[$i] | join("\n") | length) + 30) as $l
           | if (.n == $i) and ((.used + $l) <= 5700) and (.n < 9)
             then {n: (.n + 1), used: (.used + $l)} else . end) | .n) as $n2

      | (($n1 + $n2) * 15) as $approx_shown
      | ([$approx_shown, ($lines | length)] | min) as $shown
      | (($lines | length) - $shown) as $unshown

      | def block_embed($sel; $title; $note):
          { title: $title, color: 3447003,
            fields: ($sel | to_entries
                     | map({ name: (if .key == 0 then "worst first" else "…continued" end),
                             value: (.value | join("\n")), inline: false })),
            footer: { text: $note } };

        ( { embeds: ([$overview]
            + (if $n1 > 0 then
                [block_embed($blocks[0:$n1];
                  (if $below then "🔍 Highest scoring (all below threshold)"
                   else "⚡ Worth attention — " + ($shown | tostring) + " of " + ($groups | length | tostring) end);
                  "KEV first, then EPSS · every CVE id and link is in the attached report")]
               else [] end)) },
          ( if $n2 > 0 then
              { embeds: [block_embed($rest[0:$n2];
                  "⚡ Exploitable dependencies (continued)";
                  (if $unshown > 0
                   then ($unshown | tostring) + " more exploitable packages not shown — see the attached report"
                   else "end of the exploitable set" end))] }
            else empty end ) ) )
      end
  '';

  scanScript = pkgs.writeShellApplication {
    name = "vuln-scan";
    runtimeInputs = with pkgs; [
      trivy
      # syft + grype replace vulnix for the host system: see the comment at the
      # NixOS system closure step for why vulnix cannot work here.
      syft
      grype
      docker
      jq
      curl
      coreutils
      gzip
      gnused
      # Declared, not inherited: `awk` resolved from the ambient PATH on a
      # workstation and was simply absent under the unit, silently zeroing the
      # EPSS join. Same failure mode as `hostname` before it.
      gawk
      # nix-store, for enumerating the system closure
      nix
      # Declared explicitly rather than inherited from the ambient system PATH:
      # a missing `hostname` already broke a run this way, and a scanner that
      # depends on what happens to be in PATH is a scanner that fails silently.
      gnugrep
    ];
    text = ''
      set -euo pipefail

      DISCORD_WEBHOOK="$(cat ${config.sops.secrets.vuln_scan_discord_webhook_url.path})"
      WORK="$(mktemp -d)"
      REPORT_POSTED=0

      # A scan that dies silently is indistinguishable from a scan that found
      # nothing — which is precisely the false reassurance this module exists to
      # avoid. If we exit non-zero before the report goes out, say so in Discord.
      on_exit() {
        rc=$?
        if [ "$rc" -ne 0 ] && [ "$REPORT_POSTED" -eq 0 ]; then
          tail -c 1500 "$WORK/abort.log" 2>/dev/null > "$WORK/abort.tail" || true
          alert=$(jq -n \
            --arg host "$(uname -n)" \
            --arg rc "$rc" \
            --rawfile log "$WORK/abort.tail" \
            '{embeds:[{
               title: "🚨 Vulnerability scan ABORTED",
               description: ("The scan on **" + $host + "** exited with code " + $rc
                            + " before producing a report. **No CVE data was collected — "
                            + "this is not an all-clear.**\n```" + ($log | .[0:1400]) + "```"),
               color: 10038562,
               footer: { text: "journalctl -u vuln-scan -n 200" }
             }]}' 2>/dev/null) || alert=""
          if [ -n "$alert" ]; then
            curl -fsS -m 20 --retry 2 -H "Content-Type: application/json" \
              -d "$alert" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
          fi
        fi
        rm -rf "$WORK"
      }
      trap on_exit EXIT

      # Keep a copy of our own stderr so the abort alert can quote it.
      exec 2> >(tee -a "$WORK/abort.log" >&2)

      # trivy downloads and unpacks the DB via TMPDIR, which is NOT the cache
      # dir — on a small root filesystem that is a "no space left on device"
      # mid-scan. Keep the scratch space next to the cache.
      export TMPDIR="''${TRIVY_CACHE_DIR:-/var/cache/trivy}/tmp"
      mkdir -p "$TMPDIR"

      STARTED_EPOCH=$(date +%s)
      STARTED=$(date -u '+%Y-%m-%d %H:%M UTC')
      DB_WARNING=""
      : > "$WORK/results.jsonl"

      # --- Refresh the Trivy DB up front -------------------------------------
      # A stale or missing DB is the difference between "no CVEs" and "we did
      # not actually look". Surface it in the report instead of hiding it.
      if ! trivy image --download-db-only --timeout 10m > "$WORK/db.log" 2>&1; then
        DB_WARNING="Trivy vulnerability DB failed to update — results may be stale or incomplete."
        echo "WARNING: trivy db download failed:" >&2
        cat "$WORK/db.log" >&2
      fi

      # --- Docker images ------------------------------------------------------
      # Scan the union of what is declared in the NixOS config and what is
      # actually running. Declared-but-stopped images still get scanned (they
      # come back on the next boot); running-but-undeclared images get scanned
      # too (something started outside the config is exactly what you want to
      # hear about).
      printf '%s\n' ${lib.escapeShellArgs declaredImages} > "$WORK/declared.txt"

      if ! docker ps --format '{{.Image}}' > "$WORK/running.txt" 2> "$WORK/docker.err"; then
        jq -n --rawfile err "$WORK/docker.err" \
          '{source:"docker ps", kind:"image", ok:false, error:$err, running:null, packages:[], cves:[]}' \
          >> "$WORK/results.jsonl"
        : > "$WORK/running.txt"
      fi

      sort -u "$WORK/declared.txt" "$WORK/running.txt" | grep -v '^$' > "$WORK/images.txt" || true

      DECLARED_N=$(grep -c . "$WORK/declared.txt" || true)
      RUNNING_N=$(sort -u "$WORK/running.txt" | grep -c . || true)
      TOTAL_N=$(grep -c . "$WORK/images.txt" || true)
      echo "Images: $TOTAL_N to scan ($DECLARED_N declared, $RUNNING_N running)"

      while IFS= read -r img; do
        [ -z "$img" ] && continue

        if grep -qxF "$img" "$WORK/running.txt"; then
          RUNNING=true
        else
          RUNNING=false
          echo "NOTE: $img is declared but not running"
        fi
        echo "Scanning image: $img (running=$RUNNING)"

        if trivy image \
             --scanners vuln \
             --list-all-pkgs \
             --format json \
             --timeout 15m \
             --quiet \
             "$img" > "$WORK/img.json" 2> "$WORK/img.err"
        then
          jq -c --arg src "$img" --argjson running "$RUNNING" '{
            source: $src,
            kind: "image",
            ok: true,
            error: null,
            running: $running,
            packages: ([.Results[]?.Packages[]? | {
              name: .Name,
              version: (.Version // "?")
            }] | unique_by(.name + "@" + .version)),
            cves: [.Results[]?.Vulnerabilities[]? | {
              id: .VulnerabilityID,
              severity: (.Severity // "UNKNOWN"),
              pkg: .PkgName,
              installed: (.InstalledVersion // "?"),
              fixed: (.FixedVersion // "")
            }]
          }' "$WORK/img.json" >> "$WORK/results.jsonl"
        else
          echo "FAILED to scan $img" >&2
          cat "$WORK/img.err" >&2
          jq -n --arg src "$img" --rawfile err "$WORK/img.err" --argjson running "$RUNNING" \
            '{source:$src, kind:"image", ok:false, error:$err, running:$running, packages:[], cves:[]}' \
            >> "$WORK/results.jsonl"
        fi
      done < <(sort -u "$WORK/images.txt")

      # --- NixOS system closure -----------------------------------------------
      # NOT vulnix: it identifies a package by reading its .drv, and deploy-rs
      # copies build outputs rather than derivations, so on a deployed host
      # nothing has a resolvable deriver and every run died with
      # DeriverLookupError. syft reads the store paths themselves, so it needs
      # no derivations, and grype supplies fix versions that vulnix never did.
      #
      # This is the target covering tailscale, sshd, docker, systemd and the
      # kernel — everything that is not a container.
      echo "Scanning NixOS system closure"

      # syft catalogues /nix/store entries, and we want THIS system's closure
      # rather than every generation still on disk. A farm of symlinks named
      # after the store paths scopes it exactly.
      FARM="$WORK/closure/nix/store"
      mkdir -p "$FARM"
      nix-store -qR /run/current-system 2> "$WORK/sys.err" \
        | grep -v '\.drv$' \
        | while IFS= read -r sp; do
            ln -sfn "$sp" "$FARM/$(basename "$sp")" 2>/dev/null || true
          done

      SYS_OK=1
      if ! syft scan "dir:$WORK/closure" --select-catalogers nix -o json \
             > "$WORK/syft.json" 2>> "$WORK/sys.err"; then
        SYS_OK=0
        echo "FAILED: syft could not catalogue the system closure" >&2
      fi

      if [ "$SYS_OK" -eq 1 ]; then
        if ! grype "sbom:$WORK/syft.json" -o json \
               > "$WORK/grype.json" 2>> "$WORK/sys.err"; then
          SYS_OK=0
          echo "FAILED: grype could not scan the system SBOM" >&2
        fi
      fi

      if [ "$SYS_OK" -eq 1 ] && jq -e . "$WORK/grype.json" >/dev/null 2>&1; then
        jq -c --slurpfile syft "$WORK/syft.json" '
          def sev:
            {"Critical":"CRITICAL","High":"HIGH","Medium":"MEDIUM",
             "Low":"LOW","Negligible":"LOW","Unknown":"UNKNOWN"}[.] // "UNKNOWN";
          {
            source: "NixOS system closure",
            kind: "system",
            ok: true,
            error: null,
            running: null,
            packages: ($syft[0].artifacts
                       | map({name: .name, version: (.version // "?")})
                       | unique_by(.name + "@" + .version)),
            cves: ([.matches[] | {
              id: .vulnerability.id,
              severity: (.vulnerability.severity | sev),
              pkg: .artifact.name,
              installed: (.artifact.version // "?"),
              fixed: (((.vulnerability.fix.versions // [])[0]) // "")
            }] | unique_by(.id + "@" + .pkg))
          }' "$WORK/grype.json" >> "$WORK/results.jsonl"
      else
        echo "FAILED to scan NixOS system closure" >&2
        tail -c 2000 "$WORK/sys.err" >&2 || true
        jq -n --rawfile err "$WORK/sys.err" \
          '{source:"NixOS system closure", kind:"system", ok:false, error:$err, running:null, packages:[], cves:[]}' \
          >> "$WORK/results.jsonl"
      fi

      # --- Exploitability enrichment ------------------------------------------
      # CVSS scores how bad a CVE would be IF exploited and says nothing about
      # whether anyone ever will. CVE-2025-68121 — a Go crypto/tls session
      # resumption bug — is rated 10.0 CRITICAL by NVD and sits at EPSS 0.0077,
      # the 52nd percentile: median. Ranking by CVSS therefore buries the few
      # findings that matter under hundreds that merely score high.
      #
      # EPSS  = probability of exploitation in the next 30 days (FIRST.org).
      # KEV   = CISA's catalogue of CVEs observed exploited in the wild.
      # Both are fetched whole and joined locally; per-CVE API calls against
      # 10k findings would be neither polite nor fast.
      jq -r '.cves[]?.id' "$WORK/results.jsonl" | sort -u > "$WORK/our-cves.txt"

      echo "{}" > "$WORK/epss.json"
      echo "[]" > "$WORK/kev-list.json"

      if curl -fsS -m 180 -L -o "$WORK/epss.csv.gz" \
           "https://epss.empiricalsecurity.com/epss_scores-current.csv.gz" 2>> "$WORK/enrich.err" \
         && gzip -dc "$WORK/epss.csv.gz" 2>/dev/null | tail -n +3 > "$WORK/epss.csv"
      then
        # Join on our CVEs only: the feed carries ~366k rows.
        awk -F, 'NR==FNR { want[$1]; next } ($1 in want) { printf "%s\t%s\t%s\n", $1, $2, $3 }' \
          "$WORK/our-cves.txt" "$WORK/epss.csv" > "$WORK/epss-ours.tsv" || : > "$WORK/epss-ours.tsv"
        jq -R -n '[inputs | split("\t")
                   | select(length >= 3)
                   | {key: .[0], value: {epss: (.[1] | tonumber), pct: (.[2] | tonumber)}}]
                  | from_entries' < "$WORK/epss-ours.tsv" > "$WORK/epss.json" \
          || echo "{}" > "$WORK/epss.json"
        echo "EPSS: scored $(grep -c . "$WORK/epss-ours.tsv" || echo 0) of $(grep -c . "$WORK/our-cves.txt" || echo 0) CVEs"
      else
        echo "WARNING: EPSS feed unavailable — findings will not be ranked by exploit probability" >&2
      fi

      # cisa.gov answers 403 to datacenter IP ranges — verified from this host,
      # with and without a browser User-Agent — so the canonical URL is tried
      # first and CISA's own GitHub mirror (cisagov/kev-data, same catalogue,
      # same entry count) is the fallback that actually works from here.
      if curl -fsS -m 180 -o "$WORK/kev.json" \
             "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json" \
             2>> "$WORK/enrich.err" \
         || curl -fsS -m 180 -L -o "$WORK/kev.json" \
             "https://raw.githubusercontent.com/cisagov/kev-data/develop/known_exploited_vulnerabilities.json" \
             2>> "$WORK/enrich.err"
      then
        jq '[.vulnerabilities[].cveID]' "$WORK/kev.json" > "$WORK/kev-list.json" \
          || echo "[]" > "$WORK/kev-list.json"
        echo "KEV: $(jq 'length' "$WORK/kev-list.json") known-exploited CVEs in the catalogue"
      else
        echo "WARNING: CISA KEV feed unavailable — cannot flag actively exploited CVEs" >&2
      fi

      # --- Build the report ---------------------------------------------------
      DURATION="$(( $(date +%s) - STARTED_EPOCH ))s"

      jq -s \
        --slurpfile epss "$WORK/epss.json" \
        --slurpfile kev "$WORK/kev-list.json" \
        --arg started "$STARTED" \
        --arg duration "$DURATION" \
        --arg host "$(uname -n)" \
        --arg db_warning "$DB_WARNING" \
        --arg inventory "${if fullInventory then "1" else "0"}" \
        '($epss[0] // {}) as $e
         | (($kev[0] // []) | map({key: ., value: true}) | from_entries) as $k
         | { meta: {
               started: $started, duration: $duration, host: $host,
               db_warning: $db_warning, inventory: $inventory,
               epss_available: (($e | length) > 0),
               kev_available: (($k | length) > 0)
             },
             results: [ .[] | .cves |= map(
               . + { epss: ($e[.id].epss // null),
                     pct:  ($e[.id].pct  // null),
                     kev:  ($k[.id] // false) }) ] }' \
        "$WORK/results.jsonl" > "$WORK/report-input.json"

      # One file: every target, every package, every CVE. This is the artefact
      # you scroll when you want detail; Discord gets summary + urgent only.
      REPORT="$WORK/vuln-report-$(uname -n)-$(date -u +%Y%m%d).md"
      jq '.meta.mode = "markdown"' "$WORK/report-input.json" > "$WORK/md-input.json"
      jq -r -f ${reportJq} "$WORK/md-input.json" > "$REPORT"

      jq '.meta.mode = "payload"' "$WORK/report-input.json" > "$WORK/pl-input.json"
      jq -c -f ${reportJq} "$WORK/pl-input.json" > "$WORK/payloads.jsonl"

      # Discord rejects attachments over 10 MB on an unboosted server.
      CTYPE="text/markdown"
      if [ "$(stat -c %s "$REPORT")" -gt 8000000 ]; then
        gzip -9 "$REPORT"
        REPORT="$REPORT.gz"
        CTYPE="application/gzip"
      fi
      echo "Report file: $REPORT ($(stat -c %s "$REPORT") bytes)"

      # --- Post to Discord ----------------------------------------------------
      # Two messages at most, by construction. The first carries the summary,
      # the critical/high findings and the report file; the second exists only
      # when that list does not fit in one message.
      SENT=0
      while IFS= read -r payload; do
        [ -z "$payload" ] && continue
        SENT=$((SENT + 1))
        printf '%s' "$payload" > "$WORK/payload-$SENT.json"

        if [ "$SENT" -eq 1 ]; then
          # multipart: payload_json travels alongside the attachment
          if curl -fsS -m 120 --retry 3 --retry-delay 2 \
               -F "payload_json=<$WORK/payload-1.json" \
               -F "files[0]=@$REPORT;type=$CTYPE" \
               "$DISCORD_WEBHOOK" >/dev/null
          then
            REPORT_POSTED=1
          else
            echo "WARNING: failed to post the report with its attachment" >&2
          fi
        else
          if ! curl -fsS -m 30 --retry 3 --retry-delay 2 \
                 -H "Content-Type: application/json" \
                 -d "@$WORK/payload-$SENT.json" \
                 "$DISCORD_WEBHOOK" >/dev/null
          then
            echo "WARNING: failed to post message $SENT to Discord" >&2
          fi
        fi
        # Discord webhooks rate-limit around 5 requests / 2s.
        sleep 1
      done < "$WORK/payloads.jsonl"

      # --- Console summary ----------------------------------------------------
      jq -r '
        (.results | map(.cves | length) | add // 0) as $t |
        (.results | map(.packages | length) | add // 0) as $p |
        (.results | map(select(.ok | not)) | length) as $f |
        "Scan complete: \($t) CVEs across \($p) packages in \(.results | length) targets, \($f) failed"
      ' "$WORK/report-input.json"

      echo "Posted $SENT Discord message(s)."
    '';
  };
in
{
  systemd.services.vuln-scan = {
    description = "Scan Docker images and NixOS for known CVEs";
    after = [ "docker.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${scanScript}/bin/vuln-scan";
      TimeoutStartSec = "45min";
      # Persist the Trivy DB between runs so a scan is not one download away
      # from silently reporting nothing.
      CacheDirectory = [
        "trivy"
        # grype downloads its vulnerability DB; without a persistent cache it
        # refetches ~200 MB on every run.
        "grype"
      ];
      Environment = [
        "TRIVY_CACHE_DIR=/var/cache/trivy"
        "GRYPE_DB_CACHE_DIR=/var/cache/grype"
      ];
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  systemd.timers.vuln-scan = {
    description = "Weekly vulnerability scan";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Saturday 06:00 UTC. The timezone is stated explicitly rather than
      # inherited from the host, so the report does not silently shift by an
      # hour when the machine's local time crosses a DST boundary.
      OnCalendar = "Sat *-*-* 06:00:00 UTC";
      # Small jitter only: the scan pulls image metadata from several registries
      # and there is no reason for every host to hit them on the exact minute.
      RandomizedDelaySec = "10m";
      # Fires on the next boot if the machine was down on Saturday morning —
      # a skipped week would otherwise pass unnoticed.
      Persistent = true;
    };
  };
}
