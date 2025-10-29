#!/usr/bin/env python3
"""
Import addon JSON descriptors into localStorage.json -> profile -> addons.

Usage:
  python3 import_addon.py <url/manifest.json> <url/manifest.json> ...
"""

import json
import os
import sys
import urllib.request
import urllib.parse
from typing import Any, Dict, List, Tuple

VALIDATE8ADDONS = True

REQUIRED_FIELDS = ["id", "version", "name", "description", "logo", "resources", "types"]

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def read_bytes_from_source(src: str, timeout: float = 10.0) -> bytes:
    """
    Fetch bytes from HTTP(S) URLs or read from local files (file:// or plain path).
    """
    # Normalize plain paths to file://
    parsed = urllib.parse.urlparse(src)
    if parsed.scheme in ("http", "https", "file"):
        url = src
    else:
        # treat as local filesystem path
        url = urllib.parse.urljoin("file:", urllib.request.pathname2url(os.path.abspath(src)))

    print(f"Fetching info for addon at {src}...")
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.read()
    except Exception as exc:
        raise RuntimeError(f"Failed to fetch '{src}': {exc}") from exc

def parse_json_payload(payload: bytes, src: str) -> Dict[str, Any]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        # Fallback: let json library sniff bytes if possible
        try:
            text = payload.decode()
        except Exception as exc:
            raise ValueError(f"Could not decode JSON from '{src}': {exc}") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON from '{src}': {exc}") from exc

def validate_addon(data: Dict[str, Any], src: str) -> Tuple[bool, str]:
    # Check required fields
    missing = [k for k in REQUIRED_FIELDS if k not in data]
    if missing:
        return False, f"Missing required field(s) in '{src}': {', '.join(missing)}"

    # Light type checks (strings vs collections)
    str_fields = ["id", "version", "name", "description", "logo"]
    for k in str_fields:
        if not isinstance(data[k], str) or not data[k].strip():
            return False, f"Field '{k}' must be a non-empty string in '{src}'"

    # resources and types can be list/dict depending on your schema; accept list but allow dict.
    for k in ["resources", "types"]:
        if not isinstance(data[k], (list, dict)):
            return False, f"Field '{k}' must be a list or object in '{src}'"

    return True, "ok"

def load_storage(path: str) -> Dict[str, Any]:
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError:
        eprint(f"Warning: storage file was invalid json.")
        return None

    # Ensure structure
    if "profile" not in data or not isinstance(data["profile"], dict):
        eprint(f"Warning: storage file missing 'profile' object.")
        return None
    if "addons" not in data["profile"] or not isinstance(data["profile"]["addons"], list):
        eprint(f"Warning: storage file missing 'addons' array.")
        return None
    return data

def save_storage(path: str, data: Dict[str, Any]) -> None:
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)

def merge_addon(storage: Dict[str, Any], addon: Dict[str, Any], src: str) -> str:
    """
    Insert or update by 'id'. Returns 'inserted' or 'updated'.
    """
    data = {
        "flags": {
            "official": False,
            "protected": False
        },
        "manifest": addon,
        "transportUrl": src
    }
    addons: List[Dict[str, Any]] = storage["profile"]["addons"]
    for i, existing in enumerate(addons):
        if isinstance(existing, dict) and  existing.get("id") == addon["id"]:
            addons[i] = data
            return "updated"

    addons.append(data)
    return "inserted"

def import_addon_one(src: str, storage: Dict[str, Any]) -> bool:
    """
    Import a single addon source into storage. Returns True on success.
    """
    try:
        payload = read_bytes_from_source(src)
        data = parse_json_payload(payload, src)
        if VALIDATE8ADDONS:
            ok, msg = validate_addon(data, src)
            if not ok:
                eprint(msg)
                return False
        action = merge_addon(storage, data, src)
        print(f"Addon '{data['name']}' ({data['id']}) v{data['version']} {action} from {src}")
        # Display a tiny summary for visibility
        res_count = len(data["resources"]) if isinstance(data["resources"], list) else len(data["resources"])
        typ_count = len(data["types"]) if isinstance(data["types"], list) else len(data["types"])
        print(f"  - description: {data['description'][:120]}{'…' if len(data['description'])>120 else ''}")
        print(f"  - logo: {data['logo']}")
        print(f"  - resources: {res_count}, types: {typ_count}")
        return True

    except Exception as exc:
        eprint(f"Error importing '{src}': {exc}")
        return False

def main() -> int:
    # Gather inputs: CLI args
    urls = [arg for arg in sys.argv[1:] if arg.strip()]
    # urls are one big string, each url is separated by space
    urls = urls[0].split()

    if not urls:
        eprint("No addon URL provided. Provide as CLI args")
        eprint("Example: python3 import_addon.py https://example.com/manifest.json")
        return 2

    storage_path = "localStorage.json"
    storage = load_storage(storage_path)
    
    if storage is None:
        eprint("No addons were imported due to errors.")
        return 1

    success_count = 0
    for u in urls:
        print(f"Importing addon from {u}...")
        if import_addon_one(u, storage):
            success_count += 1

    if success_count:
        save_storage(storage_path, storage)
        print(f"\nSaved storage to {storage_path}. {success_count}/{len(urls)} addon(s) processed successfully.")
        return 0
    else:
        eprint("No addons were imported due to errors.")
        return 1

if __name__ == "__main__":
    main()
