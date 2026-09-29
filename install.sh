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

export INSTALL_HOME="$home"
export INSTALL_DATA_DIR="$data_dir"

client_entry_json() {
  python3 - <<'PY'
import json
import os

home = os.environ["INSTALL_HOME"]
data = os.environ["INSTALL_DATA_DIR"]
uid = os.environ.get("INSTALL_UID", "")
gid = os.environ.get("INSTALL_GID", "")
args = [
    "run",
    "-i",
    "--rm",
    "--add-host=host.docker.internal:host-gateway",
    "-e",
    "HOME=/home/mcp",
    "-e",
    "DART_NETWORK_MCP_DATA=/data",
    "-e",
    "DART_NETWORK_MCP_IN_DOCKER=1",
    "-v",
    f"{home}/.dart-tool:/home/mcp/.dart-tool:ro",
    "-v",
    f"{data}:/data:rw",
]
if uid and gid:
    args.extend(["-u", f"{uid}:{gid}"])
args.append("dart-network-mcp:local")
print(json.dumps({"command": "docker", "args": args}))
PY
}

export INSTALL_UID=""
export INSTALL_GID=""
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    INSTALL_UID="$(id -u)"
    INSTALL_GID="$(id -g)"
    export INSTALL_UID INSTALL_GID
    ;;
esac

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
