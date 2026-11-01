#!/usr/bin/env bash
# Publish each pack's .mrpack to Modrinth, so a launcher that installed it from
# there offers "update available" instead of a re-import. Run by
# .forgejo/workflows/modrinth.yml; usage: packs/modrinth.sh mc1 mc2 ...
#
# Upsert with no IDs in the repo:
#   - the project is the world's address as a slug (mc4.hu-tao.dev is
#     mc4-hu-tao-dev): found, or created (unlisted, then
#     sent to Modrinth's review once it has a version);
#   - a version is skipped when Modrinth already has the exact file (by sha1),
#     so only a changed pack gets a new one.
#
# MODRINTH_TOKEN needs the create projects, write projects, create versions,
# read projects and read versions scopes; without the reads, a project still in
# review looks missing and the run tries to create it again. A slug someone else owns fails the upload with 401: nothing is
# published into their project.
set -euo pipefail

api=https://api.modrinth.com/v2
auth=(-H "Authorization: $MODRINTH_TOKEN" -H "User-Agent: hutao/vps (https://git.hu-tao.dev/hutao/vps)")
version="$(git rev-parse --short HEAD)"
changelog="$(git log -1 --format=%s)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for pack in "$@"; do
  file="$(nix build --print-out-paths --no-link ".#$pack-mrpack")"
  name="$(basename "$file" .mrpack | cut -d- -f2-)" # mc4.hu-tao.dev-26.3
  host="${name%-*}"
  slug="${host//./-}" # mc4-hu-tao-dev

  sha1="$(sha1sum "$file" | cut -d' ' -f1)"
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$api/version_file/$sha1?algorithm=sha1")" = 200 ]; then
    echo "$pack: $name is already on Modrinth"
    continue
  fi

  new=
  case "$(curl -s -o "$tmp" -w '%{http_code}' "${auth[@]}" "$api/project/$slug")" in
    200) id="$(jq -r .id "$tmp")" ;;
    404)
      data="$(jq -n --arg slug "$slug" --arg host "$host" '{
        project_type: "modpack", slug: $slug, title: $host,
        description: "The modpack for \($host), a private Minecraft server.",
        body: "The modpack for \($host), a private, whitelisted Minecraft server. Built from https://git.hu-tao.dev/hutao/vps.",
        categories: ["multiplayer"], client_side: "required", server_side: "optional",
        license_id: "MIT", source_url: "https://git.hu-tao.dev/hutao/vps",
        is_draft: true, requested_status: "unlisted", initial_versions: []
      }')"
      id="$(curl -sS --fail-with-body "${auth[@]}" -F "data=$data" "$api/project" | jq -r .id)"
      new=1
      echo "$pack: created project $slug ($id)"
      ;;
    *) cat "$tmp" >&2; exit 1 ;;
  esac

  index="$(unzip -p "$file" modrinth.index.json)"
  data="$(jq -n --arg id "$id" --arg v "$(jq -r .dependencies.minecraft <<<"$index")-$version" \
    --arg log "$changelog" --argjson deps "$(jq .dependencies <<<"$index")" '{
      project_id: $id, name: $v, version_number: $v, changelog: $log,
      game_versions: [$deps.minecraft],
      loaders: [$deps | keys[] | select(. != "minecraft") | sub("-loader$"; "")],
      version_type: "release", featured: true, dependencies: [],
      file_parts: ["file"], primary_file: "file"
    }')"
  curl -sS --fail-with-body -o /dev/null "${auth[@]}" -F "data=$data" -F "file=@$file;filename=$name.mrpack" "$api/version"
  echo "$pack: uploaded $name"

  if [ -n "$new" ]; then
    curl -sS --fail-with-body -o /dev/null -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
      -d '{"status":"processing"}' "$api/project/$id"
    echo "$pack: sent $slug to Modrinth's review"
  fi
done
