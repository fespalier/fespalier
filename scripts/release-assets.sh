#!/usr/bin/env bash
# The plumbing that carries the fsp binaries from the release PR to the release.
#
# Builds are not reproducible, and the checksums pinned in the release PR are the checksums of
# the binaries built THERE. So those very archives must be what ends up on the release, and
# they have to survive from the PR (days, possibly weeks before the merge) to the tag. They are
# kept in a STAGING release: a draft release with the fixed tag name `fsp-staging`. A draft has
# no git tag, is visible only to people with write access, never expires (unlike a workflow
# artifact, 90 days at most), is replaced wholesale by every new build of the release PR, and
# release-please does not see it (it lists releases without a tag commit out).
#
#   stage  DIR            replace the staging draft with the files in DIR:
#                         fsp-*.tar.gz, fsp-*.zip and build-info.json
#   fetch  DIR            download every asset of the staging draft into DIR
#   ensure TAG [WAIT]     print the id of the GitHub Release for TAG (draft or not), waiting up
#                         to WAIT seconds (default 600) for release-please to create it, and
#                         creating a draft only if it never appears (a tag pushed by hand)
#   attach TAG FILE...    upload the files to TAG's release (replacing same-named assets)
#   publish TAG           publish TAG's release (it is a draft until now) and make it the latest
#   drop                  delete the staging draft
#
# Needs curl and jq, GH_TOKEN (a token with contents: write; drafts are invisible without it)
# and GITHUB_REPOSITORY. GITHUB_API_URL and GITHUB_UPLOADS_URL exist so that
# scripts/test_release_assets.py can run all of this against a fake server.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is not set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
API="${GITHUB_API_URL:-https://api.github.com}"
UPLOADS="${GITHUB_UPLOADS_URL:-https://uploads.github.com}"
STAGING_TAG="${STAGING_TAG:-fsp-staging}"
REPO_API="$API/repos/$GITHUB_REPOSITORY"

api() {
  curl --fail-with-body --silent --show-error --location \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# An asset's bytes. Not api() plus a second Accept header: curl sends both, and GitHub then
# answers with the asset's JSON metadata instead of the file.
download() {
  curl --fail-with-body --silent --show-error --location \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/octet-stream" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

# Every release as one JSON array, newest first, drafts included when the token may see them.
all_releases() {
  local tmp page=1 n
  tmp="$(mktemp -d)"
  while :; do
    api "$REPO_API/releases?per_page=100&page=$page" > "$tmp/$page.json"
    n="$(jq 'length' "$tmp/$page.json")"
    [[ "$n" -lt 100 ]] && break
    page=$((page + 1))
  done
  jq -s 'add // []' "$tmp"/*.json
  rm -rf "$tmp"
}

staging_ids() {
  all_releases | jq -r --arg tag "$STAGING_TAG" '.[] | select(.draft and .tag_name == $tag) | .id'
}

drop_staging() {
  local id
  for id in $(staging_ids); do
    echo "deleting the staging draft $id"
    api -X DELETE "$REPO_API/releases/$id" > /dev/null
  done
}

content_type() {
  case "$1" in
    *.tar.gz) echo application/gzip ;;
    *.zip) echo application/zip ;;
    *.json) echo application/json ;;
    *) echo text/plain ;;
  esac
}

upload() {
  local id="$1" file="$2" name attempt
  name="$(basename "$file")"
  for attempt in 1 2 3; do
    if api -X POST -H "Content-Type: $(content_type "$name")" --data-binary "@$file" \
      "$UPLOADS/repos/$GITHUB_REPOSITORY/releases/$id/assets?name=$name" > /dev/null; then
      echo "uploaded $name"
      return 0
    fi
    echo "upload of $name failed (attempt $attempt)" >&2
    sleep $((attempt * 5))
  done
  return 1
}

asset_names() {
  api "$REPO_API/releases/$1" | jq -r '.assets[].name' | sort
}

# release JSON (id and draft) for a tag, or nothing
find_release() {
  all_releases | jq -c --arg tag "$1" '[.[] | select(.tag_name == $tag)] | first // empty | {id, draft}'
}

cmd_stage() {
  local dir="$1" id f expected=()
  shopt -s nullglob
  for f in "$dir"/fsp-*.tar.gz "$dir"/fsp-*.zip "$dir/build-info.json"; do
    [[ -f "$f" ]] && expected+=("$f")
  done
  [[ ${#expected[@]} -ge 6 ]] || { echo "::error::expected 5 archives and build-info.json in $dir, found ${#expected[@]} files" >&2; return 1; }
  drop_staging
  id="$(api -X POST "$REPO_API/releases" \
    -d "$(jq -n --arg tag "$STAGING_TAG" '{tag_name: $tag, name: "fsp staging (never publish)", draft: true, prerelease: false,
      body: "The binaries built on the release-please PR, waiting for their tag. release.yml verifies them against the checksums pinned in the tagged tree and attaches them. Replaced by every build of the release PR; deleted once the release is published. Do not publish this draft."}')" | jq -r '.id')"
  echo "staging draft $id"
  for f in "${expected[@]}"; do upload "$id" "$f"; done
  local have want
  have="$(asset_names "$id")"
  want="$(printf '%s\n' "${expected[@]}" | xargs -n1 basename | sort)"
  [[ "$have" == "$want" ]] || { echo "::error::the staging draft holds [$have], expected [$want]" >&2; return 1; }
}

cmd_fetch() {
  local dir="$1" ids id name aid
  ids="$(staging_ids)"
  [[ -n "$ids" ]] || { echo "::error::no staging draft '$STAGING_TAG': the release PR's binaries were never staged, or were deleted. Re-run the release-pins workflow on the release PR, or start the release over." >&2; return 1; }
  id="$(head -n 1 <<< "$ids")"
  mkdir -p "$dir"
  api "$REPO_API/releases/$id" | jq -r '.assets[] | "\(.id) \(.name) \(.size)"' | while read -r aid name size; do
    download "$REPO_API/releases/assets/$aid" -o "$dir/$name"
    [[ "$(wc -c < "$dir/$name" | tr -d ' ')" == "$size" ]] || { echo "::error::$name downloaded with the wrong size" >&2; exit 1; }
    echo "fetched $name"
  done
}

cmd_ensure() {
  local tag="$1" wait="${2:-600}" found waited=0
  while :; do
    found="$(find_release "$tag")"
    if [[ -n "$found" ]]; then
      jq -r '.id' <<< "$found"
      return 0
    fi
    [[ "$waited" -ge "$wait" ]] && break
    sleep 10
    waited=$((waited + 10))
  done
  echo "::warning::release-please did not create a release for $tag within ${wait}s; creating a draft for this tag" >&2
  api -X POST "$REPO_API/releases" -d "$(jq -n --arg tag "$tag" '{tag_name: $tag, name: $tag, draft: true, generate_release_notes: true}')" | jq -r '.id'
}

cmd_attach() {
  local tag="$1" id f name aid
  shift
  id="$(cmd_ensure "$tag")"
  for f in "$@"; do
    name="$(basename "$f")"
    for aid in $(api "$REPO_API/releases/$id" | jq -r --arg n "$name" '.assets[] | select(.name == $n) | .id'); do
      api -X DELETE "$REPO_API/releases/assets/$aid" > /dev/null
    done
    upload "$id" "$f"
  done
  local have
  have="$(asset_names "$id")"
  for f in "$@"; do
    grep -qxF "$(basename "$f")" <<< "$have" || { echo "::error::$(basename "$f") is not on the release after the upload" >&2; return 1; }
  done
}

cmd_publish() {
  local id
  id="$(find_release "$1" | jq -r '.id // empty')"
  [[ -n "$id" ]] || { echo "::error::there is no release for $1 to publish" >&2; return 1; }
  api -X PATCH "$REPO_API/releases/$id" -d '{"draft": false, "make_latest": "true"}' | jq -r '"published \(.tag_name): \(.html_url)"'
}

case "${1:-}" in
  stage) cmd_stage "${2:?DIR}" ;;
  fetch) cmd_fetch "${2:?DIR}" ;;
  ensure) cmd_ensure "${2:?TAG}" "${3:-600}" ;;
  attach) [[ $# -ge 3 ]] || { echo "usage: $0 attach TAG FILE..." >&2; exit 2; }; shift; cmd_attach "$@" ;;
  publish) cmd_publish "${2:?TAG}" ;;
  drop) drop_staging ;;
  *) sed -n '2,25p' "$0" >&2; exit 2 ;;
esac
