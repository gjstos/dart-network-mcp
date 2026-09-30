#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_CLAUDE=false
INSTALL_CURSOR=false
INSTALL_FRESH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claude)
      INSTALL_CLAUDE=true
      shift
      ;;
    --cursor)
      INSTALL_CURSOR=true
      shift
      ;;
    --fresh)
      INSTALL_FRESH=true
      shift
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

if ! $INSTALL_CLAUDE && ! $INSTALL_CURSOR; then
  echo "At least one of --claude or --cursor is required" >&2
  exit 1
fi

home="${HOME:-${USERPROFILE:-}}"
if [[ -z "$home" ]]; then
  echo "HOME or USERPROFILE is required" >&2
  exit 1
fi

resolve_data_dir() {
  if [[ -n "${DART_NETWORK_MCP_DATA:-}" ]]; then
    printf '%s' "$DART_NETWORK_MCP_DATA"
    return
  fi
  if [[ -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s' "${LOCALAPPDATA}/dart-network-mcp"
    return
  fi
  printf '%s' "$home/.local/share/dart-network-mcp"
}

is_windows_msys() {
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

data_dir="$(resolve_data_dir)"

remove_server_data_dir() {
  local dir="$1"
  case "$(basename "$dir")" in
    dart-network-mcp | dart-vm-mcp) rm -rf "$dir" ;;
  esac
}

legacy_data_dir() {
  if [[ -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s' "${LOCALAPPDATA}/dart-vm-mcp"
    return
  fi
  printf '%s' "$home/.local/share/dart-vm-mcp"
}

strip_agent_config() {
  local target="$1"
  if [[ -f "$target" ]]; then
    dart run "$SCRIPT_DIR/tool/merge_mcp_config.dart" --strip "$target"
  fi
}

# The server used to ship as a Docker image; clear what older installs left.
# The profile lives in docker's own config, so it goes even with the daemon
# off; containers and images need the daemon.
fresh_clean_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  docker mcp profile remove dart-network-mcp >/dev/null 2>&1 || true
  if ! docker info >/dev/null 2>&1; then
    echo "Docker is not running: old dart-network-mcp images/containers were left in place." >&2
    return 0
  fi
  local id image
  local ids
  local -a drop=()
  ids="$(docker ps -aq)"
  if [[ -n "$ids" ]]; then
    for id in $ids; do
      image="$(docker inspect -f '{{.Config.Image}}' "$id")"
      case "$image" in
        dart-network-mcp:local | dart-vm-mcp:local) drop+=("$id") ;;
      esac
    done
    if ((${#drop[@]})); then
      docker rm -f "${drop[@]}" >/dev/null
    fi
  fi
  docker rmi dart-network-mcp:local dart-vm-mcp:local >/dev/null 2>&1 || true
}

if $INSTALL_FRESH; then
  strip_agent_config "$home/.claude.json"
  strip_agent_config "$home/.cursor/mcp.json"
  remove_server_data_dir "$data_dir"
  remove_server_data_dir "$(legacy_data_dir)"
  rm -f \
    "$home/.docker/mcp/catalogs/dart-network-mcp.yaml" \
    "$home/.docker/mcp/catalogs/dart-vm-mcp.yaml"
  if [[ -z "${DART_NETWORK_MCP_INSTALL_SKIP_DOCKER:-}" ]]; then
    fresh_clean_docker
  fi
fi

bin_dir="${DART_NETWORK_MCP_BIN_DIR:-$home/.local/bin}"
bin_name="dart_network_mcp"
if is_windows_msys; then
  bin_name="dart_network_mcp.exe"
fi
bin_path="$bin_dir/$bin_name"

mkdir -p "$data_dir" "$bin_dir"

if is_windows_msys; then
  if command -v icacls >/dev/null 2>&1 && [[ -n "${USERNAME:-}" ]]; then
    icacls "$data_dir" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" >/dev/null
  fi
else
  chmod 700 "$data_dir"
fi

if [[ -z "${DART_NETWORK_MCP_INSTALL_SKIP_BUILD:-}" ]]; then
  (
    cd "$SCRIPT_DIR"
    dart compile exe bin/dart_network_mcp.dart -o "$bin_path"
  )
fi

export INSTALL_BIN_PATH="$bin_path"

client_entry_json() {
  python3 - <<'PY'
import json
import os

print(json.dumps({"command": os.environ["INSTALL_BIN_PATH"], "args": []}))
PY
}

merge_client_config() {
  local target="$1"
  local entry
  entry="$(client_entry_json)"
  dart run "$SCRIPT_DIR/tool/merge_mcp_config.dart" "$target" "$entry"
}

if $INSTALL_CLAUDE; then
  merge_client_config "$home/.claude.json"
fi

if $INSTALL_CURSOR; then
  merge_client_config "$home/.cursor/mcp.json"
fi
