#!/bin/sh
# Import addon JSON descriptors into localStorage.json -> profile -> addons.
#
# Usage:
#   sh import_addon.sh <url/manifest.json> <url/manifest.json> ...
#
# Requirements:
#   - /bin/sh, jq, curl
#
# Behavior:
#   - Accepts HTTP(S) URLs, file:// URLs, or local file paths
#   - Parses each manifest JSON and inserts/updates by matching top-level "id"
#     against existing entries' .id OR .manifest.id inside profile.addons.
#   - Writes back to localStorage.json only if at least one addon succeeds.
#   - Prints a short summary for each processed addon.

set -eu

# ---- config ----
STORAGE_PATH="localStorage.json"
CURL_MAX_TIME=10

# ---- helpers ----

eprint() { printf "%s\n" "$*" >&2; }

# Fetch raw bytes from HTTP(S)/file:// or read local file.
# IMPORTANT: print status to STDERR, JSON to STDOUT.
fetch_source() {
  _src="$1"
  eprint "Fetching info for addon at $_src..."
  case "$_src" in
    http://*|https://*|file://*)
      curl -fSsSL --max-time "$CURL_MAX_TIME" "$_src"
      ;;
    *)
      cat "$_src"
      ;;
  esac
}

# Load and validate storage. Must contain .profile.addons as an array.
load_storage() {
  # If file missing or invalid JSON, initialize a fresh structure.
  if [ ! -f "$STORAGE_PATH" ] || ! jq . "$STORAGE_PATH" >/dev/null 2>&1; then
    eprint "Warning: storage file is missing or invalid: $STORAGE_PATH"
    return 0
  fi
  # Normalize structure: make sure .profile is an object and .profile.addons is an array.
  # This never fails if the file is valid JSON.
  if ! jq -c '
      . as $root
      | (if (.profile | type) == "object" then .profile else {} end) as $p
      | .profile = $p
      | .profile += { addons: (if (.profile.addons | type) == "array" then .profile.addons else [] end) }
    ' "$STORAGE_PATH" > "${STORAGE_PATH}.tmp"
  then
    eprint "Warning: could not normalize $STORAGE_PATH"
    return 1
  fi

  mv "${STORAGE_PATH}.tmp" "$STORAGE_PATH"
  return 0
}


# Save storage atomically: pretty-sort to a temp file, then move into place.
save_storage() {
  _tmp="${STORAGE_PATH}.tmp"
  jq -S '.' "$STORAGE_PATH" > "$_tmp"
  mv "$_tmp" "$STORAGE_PATH"
}

# Import one addon JSON into storage; prints summary; returns 0 on success.
import_one() {
  _src="$1"

  # Fetch and parse JSON payload (guarded)
  if ! _payload="$(fetch_source "$_src")"; then
    eprint "Error importing '$_src': failed to fetch."
    return 1
  fi

  # Validate JSON and required fields
  printf '%s' "$_payload" | jq -e 'type=="object" and has("id")' >/dev/null 2>&1 || {
    eprint "Error importing '$_src': invalid JSON or missing .id."
    return 1
  }

  # Compact JSON of the addon
  _ADDON_JSON="$(printf '%s' "$_payload" | jq -c '.')"

  # Extract id for pre-existence check
  _addon_id="$(printf '%s' "$_ADDON_JSON" | jq -r '.id')"

  # Compute index safely (always outputs a number; -1 if not found)
  _idx="$(
    jq -r --arg id "$_addon_id" '
      [ .profile.addons[]? | (.id // .manifest.id) ] | (index($id) // -1)
    ' "$STORAGE_PATH"
  )"

  # Merge into storage (replace if exists, else append)
  if ! jq --argjson addon "$_ADDON_JSON" --arg src "$_src" --argjson idx "$_idx" '
      ({"flags":{"official":false,"protected":false},"manifest":$addon,"transportUrl":$src}) as $new
      | if ($idx|tonumber) >= 0 then
          .profile.addons[($idx|tonumber)] = $new
        else
          .profile.addons += [ $new ]
        end
    ' "$STORAGE_PATH" > "${STORAGE_PATH}.updated" 2>/dev/null
  then
    eprint "Error importing '$_src': failed to merge into storage."
    return 1
  fi

  mv "${STORAGE_PATH}.updated" "$STORAGE_PATH"

  # Pretty output summary (best-effort if fields are missing)
  _addon_name="$(printf '%s' "$_ADDON_JSON" | jq -r '.name // "(no name)"')"
  _addon_ver="$(printf '%s' "$_ADDON_JSON" | jq -r '.version // "(no version)"')"
  _desc_snip="$(
    printf '%s' "$_ADDON_JSON" \
      | jq -r '(.description|tostring) as $d | ($d[:120] + (if ($d|length)>120 then "…" else "" end))'
  )"

  if [ "$_idx" -ge 0 ]; then
    _action="updated"
  else
    _action="inserted"
  fi

  printf "Addon '%s' (%s) v%s %s from %s\n" "$_addon_name" "$_addon_id" "$_addon_ver" "$_action" "$_src"
  printf "  - description: %s\n" "$_desc_snip"
  return 0
}

# ---- main ----

if [ "$#" -eq 0 ]; then
  eprint "No addon URL provided. Provide as CLI args"
  eprint "Example: sh import_addon.sh https://example.com/manifest.json"
  exit 2
fi

# Validate storage structure
if ! load_storage; then
  eprint "No addons were imported due to errors. Cannot load storage"
  exit 1
fi

_success_count=0
_total="$#"

for _src in "$@"; do
  printf "Importing addon from %s...\n" "$_src"
  if import_one "$_src"; then
    _success_count=$(( _success_count + 1 ))
  fi
done

if [ "$_success_count" -gt 0 ]; then
  save_storage
  printf "\nSaved storage to %s. %d/%d addon(s) processed successfully.\n" "$STORAGE_PATH" "$_success_count" "$_total"
  exit 0
else
  eprint "No addons were imported due to errors."
  exit 1
fi
