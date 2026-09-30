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

resolve_dart_dtd_dir() {
  if [[ -n "${DART_NETWORK_MCP_DTD_DIR:-}" ]]; then
    printf '%s' "$DART_NETWORK_MCP_DTD_DIR"
    return
  fi
  if is_windows_msys; then
    printf '%s' "${LOCALAPPDATA:-$home/AppData/Local}/Dart/dtd"
    return
  fi
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      printf '%s' "$home/Library/Application Support/Dart/dtd"
      ;;
    *)
      printf '%s' "${XDG_DATA_HOME:-$home/.local/share}/Dart/dtd"
      ;;
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

fresh_clean_docker() {
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
  docker mcp profile remove dart-network-mcp >/dev/null 2>&1 || true
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

dart_tool_dir="$home/.dart-tool"
dart_dtd_dir="$(resolve_dart_dtd_dir)"
catalog_dir="$home/.docker/mcp/catalogs"
catalog_file="$catalog_dir/dart-network-mcp.yaml"

mkdir -p "$data_dir" "$dart_tool_dir" "$dart_dtd_dir" "$catalog_dir"

if is_windows_msys; then
  if command -v icacls >/dev/null 2>&1 && [[ -n "${USERNAME:-}" ]]; then
    icacls "$data_dir" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" >/dev/null
  fi
else
  chmod 700 "$data_dir"
fi

dart_tool_vol="$dart_tool_dir:/home/mcp/.dart-tool:ro"
dart_dtd_vol="$dart_dtd_dir:/home/mcp/Dart/dtd:ro"
data_vol="$data_dir:/data:rw"

write_catalog() {
  local extra_hosts_block=""
  if [[ -z "${DART_NETWORK_MCP_INSTALL_SKIP_DOCKER:-}" ]]; then
    if ! docker run --rm alpine getent hosts host.docker.internal >/dev/null 2>&1; then
      extra_hosts_block=$'extraHosts: ["host.docker.internal:host-gateway"]\n'
    fi
  fi

  local user_block=""
  if ! is_windows_msys; then
    user_block=$'user: "'$(id -u):$(id -g)$'"\n'
  fi

  cat >"$catalog_file" <<EOF
name: dart-network-mcp
title: Dart VM Network
description: HTTP profile of running Dart and Flutter VMs.
type: server
image: dart-network-mcp:local
longLived: true
volumes:
  - $dart_tool_vol
  - $dart_dtd_vol
  - $data_vol
env:
  - name: HOME
    value: /home/mcp
  - name: DART_NETWORK_MCP_DATA
    value: /data
  - name: DART_NETWORK_MCP_IN_DOCKER
    value: "1"
  - name: DART_NETWORK_MCP_DTD_DIR
    value: /home/mcp/Dart/dtd
tools:
  - name: list_sessions
    description: List VM sessions
  - name: get_session
    description: Get one VM session
  - name: attach_vm
    description: Attach to a VM by URI
  - name: list_requests
    description: List HTTP calls for a session
  - name: get_request
    description: Get one HTTP profile request
  - name: export_har
    description: Export session traffic as HAR
  - name: export_devtools_json
    description: Export session traffic as DevTools JSON
  - name: delete_session
    description: Delete a session and its stored requests
  - name: get_retention
    description: Return the session retention period in days
  - name: set_retention
    description: Set the session retention period in days
${user_block}${extra_hosts_block}
EOF
}

write_catalog

ensure_docker_mcp_profile() {
  if docker mcp profile show dart-network-mcp >/dev/null 2>&1; then
    docker mcp profile server add dart-network-mcp --server file://dart-network-mcp.yaml
    return
  fi
  if docker mcp profile create --name dart-network-mcp --id dart-network-mcp --server file://dart-network-mcp.yaml; then
    return
  fi
  if docker mcp profile show dart-network-mcp >/dev/null 2>&1; then
    docker mcp profile server add dart-network-mcp --server file://dart-network-mcp.yaml
    return
  fi
  echo "Failed to create or update docker mcp profile dart-network-mcp" >&2
  exit 1
}

if [[ -z "${DART_NETWORK_MCP_INSTALL_SKIP_DOCKER:-}" ]]; then
  docker build -t dart-network-mcp:local "$SCRIPT_DIR"
  ensure_docker_mcp_profile
fi

export INSTALL_RUN_SCRIPT="$SCRIPT_DIR/tool/run_mcp_container.sh"

client_entry_json() {
  python3 - <<'PY'
import json
import os

print(json.dumps({"command": os.environ["INSTALL_RUN_SCRIPT"], "args": []}))
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
