#!/usr/bin/env bash
# Import addon JSON descriptors into localStorage.json -> profile -> addons.
# Usage:
#   bash import_addon.sh <url/manifest.json> <url/manifest.json> ...
# Requirements: bash, jq, curl

set -Euo pipefail

# Emit failing command + line on error.
trap 'printf "Error: command failed at line %d: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---- config ----
STORAGE_PATH="localStorage.json"
CURL_MAX_TIME=10

# ---- helpers ----
eprint() { printf "%s\n" "$*" >&2; }

fetch_source() {
  local src="$1"
  eprint "Fetching info for addon at $src..."
  if [[ "$src" =~ ^https?:// ]] || [[ "$src" =~ ^file:// ]]; then
    curl -fSsSL --max-time "$CURL_MAX_TIME" "$src"
  else
    cat -- "$src"
  fi
}

load_storage() {
  [[ -f "$STORAGE_PATH" ]] || { eprint "Warning: storage file is missing: $STORAGE_PATH"; return 1; }

  jq -e 'type=="object"' "$STORAGE_PATH" >/dev/null 2>&1 \
    || { eprint "Warning: storage file was invalid json."; return 1; }

  jq -e '.profile|type=="object"' "$STORAGE_PATH" >/dev/null 2>&1 \
    || { eprint "Warning: storage file missing '\''profile'\'' object."; return 1; }

  jq -e '.profile.addons|type=="array"' "$STORAGE_PATH" >/dev/null 2>&1 \
    || { eprint "Warning: storage file missing '\''addons'\'' array."; return 1; }
}

save_storage() {
  local tmp="${STORAGE_PATH}.tmp"
  jq -S '.' "$STORAGE_PATH" > "$tmp"
  mv -- "$tmp" "$STORAGE_PATH"
}

import_one() {
  local src="$1"
  local payload ADDON_JSON addon_id idx addon_name addon_ver desc_snip action

  # Fetch and parse JSON payload (guarded)
  if ! payload="$(fetch_source "$src")"; then
    eprint "Error importing '$src': failed to fetch."
    return 1
  fi

  # Validate JSON and required fields
  if ! printf '%s' "$payload" | jq -e 'type=="object" and has("id")' >/dev/null 2>&1; then
    eprint "Error importing '$src': invalid JSON or missing .id."
    return 1
  fi

  ADDON_JSON="$(printf '%s' "$payload" | jq -c '.')"
  addon_id="$(printf '%s' "$ADDON_JSON" | jq -r '.id')"

  # Compute index in Bash-friendly way (always success; -1 if not found)
  idx="$(
    jq -r --arg id "$addon_id" '
      [ .profile.addons[]? | (.id // .manifest.id) ] | (index($id) // -1)
    ' "$STORAGE_PATH"
  )"

  # Merge into storage
  if ! jq --argjson addon "$ADDON_JSON" --arg src "$src" --argjson idx "$idx" '
      . as $root
      | ({"flags":{"official":false,"protected":false},"manifest":$addon,"transportUrl":$src}) as $new
      | if ($idx|tonumber) >= 0 then
          .profile.addons[($idx|tonumber)] = $new
        else
          .profile.addons += [ $new ]
        end
    ' "$STORAGE_PATH" > "${STORAGE_PATH}.updated" 2>/dev/null
  then
    eprint "Error importing '$src': failed to merge into storage."
    return 1
  fi
  mv -- "${STORAGE_PATH}.updated" "$STORAGE_PATH"

  # Summary
  addon_name="$(printf '%s' "$ADDON_JSON" | jq -r '.name // "(no name)"')"
  addon_ver="$(printf '%s' "$ADDON_JSON" | jq -r '.version // "(no version)"')"
  desc_snip="$(
    printf '%s' "$ADDON_JSON" \
      | jq -r '(.description|tostring) as $d | ($d[:120] + (if ($d|length)>120 then "…" else "" end))'
  )"
  action=$([[ "$idx" -ge 0 ]] && echo "updated" || echo "inserted")

  printf "Addon '%s' (%s) v%s %s from %s\n" "$addon_name" "$addon_id" "$addon_ver" "$action" "$src"
  printf "  - description: %s\n" "$desc_snip"
  return 0
}

# ---- main ----
if (( $# == 0 )); then
  eprint "No addon URL provided. Provide as CLI args"
  eprint "Example: bash import_addon.sh https://example.com/manifest.json"
  exit 2
fi

if ! load_storage; then
  eprint "No addons were imported due to errors. Cannot load storage"
  exit 1
fi

success_count=0
total="$#"

for src in "$@"; do
  printf "Importing addon from %s...\n" "$src"
  if import_one "$src"; then
    ((success_count++))
  fi
done

if (( success_count > 0 )); then
  save_storage
  printf "\nSaved storage to %s. %d/%d addon(s) processed successfully.\n" "$STORAGE_PATH" "$success_count" "$total"
  exit 0
else
  eprint "No addons were imported due to errors."
  exit 1
fi
