#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_CLAUDE=false
INSTALL_CURSOR=false

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
dart_tool_dir="$home/.dart-tool"
catalog_dir="$home/.docker/mcp/catalogs"
catalog_file="$catalog_dir/dart-network-mcp.yaml"

mkdir -p "$data_dir" "$dart_tool_dir" "$catalog_dir"

if is_windows_msys; then
  if command -v icacls >/dev/null 2>&1 && [[ -n "${USERNAME:-}" ]]; then
    icacls "$data_dir" /inheritance:r /grant:r "${USERNAME}:(OI)(CI)F" >/dev/null
  fi
else
  chmod 700 "$data_dir"
fi

dart_tool_vol="$dart_tool_dir:/home/mcp/.dart-tool:ro"
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
  - $data_vol
env:
  - name: HOME
    value: /home/mcp
  - name: DART_NETWORK_MCP_DATA
    value: /data
  - name: DART_NETWORK_MCP_IN_DOCKER
    value: "1"
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
