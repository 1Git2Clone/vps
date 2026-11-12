#!/usr/bin/env bash
# Publish each pack's .mrpack to Modrinth, so a launcher that installed it from
# there offers "update available" instead of a re-import. Run by
# .forgejo/workflows/modrinth.yml; usage: packs/modrinth.sh mc1 mc2 ...
#
# Upsert with no IDs in the repo:
#   - the project is the world's address as a slug (mc4.hu-tao.dev is
#     mc4-hu-tao-dev): found, or created unlisted; while it is still a
#     draft, each run sends it to Modrinth's review;
#   - a version is skipped when Modrinth already has the exact file (by sha512),
#     so only a changed pack gets a new one.
#
# MODRINTH_TOKEN needs the create, read and write scopes for both projects and
# versions. Without the reads, a project still in review looks missing and the
# run tries to create it again; setting the sides edits every version, which
# is a bare 401 without write versions. A slug someone
# else owns fails the upload with 401: nothing is published into their project.
set -euo pipefail

api=https://api.modrinth.com/v2
auth=(-H "Authorization: $MODRINTH_TOKEN" -H "User-Agent: hutao/vps (https://git.hu-tao.dev/hutao/vps)")
version="$(git rev-parse --short HEAD)"
current="$(git rev-parse HEAD)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for pack in "$@"; do
  file="$(nix build --print-out-paths --no-link ".#$pack-mrpack")"
  name="$(basename "$file" .mrpack | cut -d- -f2-)" # mc4.hu-tao.dev-26.3
  host="${name%-*}"
  slug="${host//./-}" # mc4-hu-tao-dev

  # Summary, description and sides, re-sent every run so the project follows
  # the handbook. The description is the world's handbook page with its mod
  # list inlined; the summary is its title, since Modrinth refuses one that
  # holds an address. Sides on a project apply to all its versions.
  page=docs/src/minecraft/worlds
  meta="$(jq -n --rawfile page "$page/$pack.md" --rawfile mods "$page/$pack-mods.md" '
    def clean: gsub("(?s)<!--.*?-->\\s*"; "");
    {
      description: (($page | capture("^# (?<t>[^\\n]+)").t) + ", the modpack for a private, whitelisted Minecraft server."),
      body: ($page | gsub("\\{\\{#include [^}]+\\}\\}"; $mods | clean) | clean
        | gsub("\\]\\((?<p>[a-z0-9-]+)\\.md\\)"; "](https://docs.hu-tao.dev/minecraft/worlds/\(.p).html)")),
      client_side: "required", server_side: "optional"
    }')"

  case "$(curl -s -o "$tmp" -w '%{http_code}' "${auth[@]}" "$api/project/$slug")" in
  200) id="$(jq -r .id "$tmp")" status="$(jq -r .status "$tmp")" ;;
  404)
    data="$(jq --arg slug "$slug" --arg host "$host" '. + {
        project_type: "modpack", slug: $slug, title: $host,
        categories: ["multiplayer"], license_id: "MIT", source_url: "https://git.hu-tao.dev/hutao/vps",
        is_draft: true, requested_status: "unlisted", initial_versions: []
      }' <<<"$meta")"
    id="$(curl -sS --fail-with-body "${auth[@]}" -F "data=$data" "$api/project" | jq -r .id)"
    status=draft
    echo "$pack: created project $slug ($id)"
    ;;
  *)
    cat "$tmp" >&2
    exit 1
    ;;
  esac

  sha512="$(sha512sum "$file" | cut -d' ' -f1)"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$api/version_file/$sha512?algorithm=sha512")" = 200 ]; then
    echo "$pack: $name is already on Modrinth"
  else
    # Compare with this pack's latest published release, not HEAD's parent.
    curl -sS --fail-with-body -o "$tmp" "${auth[@]}" "$api/project/$id/version" ||
      {
        cat "$tmp" >&2
        exit 1
      }
    previous_version="$(jq -r '
      [.[] | select(.version_type == "release")]
      | sort_by(.date_published) | last | .version_number // empty
    ' "$tmp")"
    previous=
    if [ -n "$previous_version" ]; then
      # Forgejo resolves the published hash in the comparison URL; no local
      # history is needed, even when releases skip commits.
      previous="${previous_version##*-}"
      if [[ ! "$previous" =~ ^[0-9a-f]{7,40}$ ]]; then
        echo "$pack: published version $previous_version has no valid commit hash" >&2
        exit 1
      fi
    fi
    changelog="$(
      cat <<EOF
\`\`\`txt
$(git log -1 --format='commit %H%n%n%B' "$current")
\`\`\`
EOF
    )"
    if [ -n "$previous" ]; then
      changelog+="$(printf '\n\n---\n\nDiff since last update: https://git.hu-tao.dev/hutao/vps/compare/%s...%s' "$previous" "$current")"
    fi

    index="$(unzip -p "$file" modrinth.index.json)"
    data="$(jq -n --arg id "$id" --arg v "$(jq -r .dependencies.minecraft <<<"$index")-$version" \
      --arg log "$changelog" --argjson deps "$(jq .dependencies <<<"$index")" '{
        project_id: $id, name: $v, version_number: $v, changelog: $log,
        game_versions: [$deps.minecraft],
        loaders: [$deps | keys[] | select(. != "minecraft") | sub("-loader$"; "")],
        version_type: "release", featured: true, dependencies: [],
        file_parts: ["file"], primary_file: "file"
      }')"
    curl -sS --fail-with-body -o "$tmp" "${auth[@]}" -F "data=$data" -F "file=@$file;filename=$name.mrpack" "$api/version" ||
      {
        cat "$tmp" >&2
        exit 1
      }
    echo "$pack: uploaded $name"
  fi

  curl -sS --fail-with-body -o "$tmp" -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
    -d "$meta" "$api/project/$id" || {
    cat "$tmp" >&2
    exit 1
  }

  # Still a draft (new, or a run that died before this): send it to review.
  # Modrinth answers a project that fails its publishing checklist with a bare
  # 400 and no reason, so a refusal is a warning: the upload above still
  # counts, and the checklist on the project page names what is missing.
  if [ "$status" = draft ]; then
    if curl -sS --fail-with-body -o "$tmp" -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
      -d '{"status":"processing"}' "$api/project/$id"; then
      echo "$pack: sent $slug to Modrinth's review"
    else
      echo "::warning::$pack: Modrinth refused to review $slug; submit it from https://modrinth.com/modpack/$slug"
    fi
  fi
done
