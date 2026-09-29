#!/usr/bin/env bash
set -euo pipefail

IMAGE=dart-network-mcp:local
NAME=dart-network-mcp

reap_ours() {
  local id image
  local ids
  local -a drop=()
  ids="$(docker ps -aq)"
  if [[ -z "$ids" ]]; then
    return
  fi
  for id in $ids; do
    image="$(docker inspect -f '{{.Config.Image}}' "$id")"
    case "$image" in
      dart-network-mcp:local | dart-vm-mcp:local) drop+=("$id") ;;
    esac
  done
  if ((${#drop[@]})); then
    docker rm -f "${drop[@]}" >/dev/null
  fi
}

reap_ours
docker rm -f "$NAME" >/dev/null 2>&1 || true

home="${HOME:-${USERPROFILE:-}}"
if [[ -z "$home" ]]; then
  echo "HOME or USERPROFILE is required" >&2
  exit 1
fi

if [[ -n "${DART_NETWORK_MCP_DATA:-}" ]]; then
  data_dir="$DART_NETWORK_MCP_DATA"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  data_dir="${LOCALAPPDATA}/dart-network-mcp"
else
  data_dir="$home/.local/share/dart-network-mcp"
fi

user_args=()
case "$(uname -s 2>/dev/null || true)" in
  MINGW* | MSYS* | CYGWIN*) ;;
  *) user_args=(-u "$(id -u):$(id -g)") ;;
esac

exec docker run \
  -i \
  --rm \
  --name "$NAME" \
  --add-host=host.docker.internal:host-gateway \
  -e HOME=/home/mcp \
  -e DART_NETWORK_MCP_DATA=/data \
  -e DART_NETWORK_MCP_IN_DOCKER=1 \
  -v "$home/.dart-tool:/home/mcp/.dart-tool:ro" \
  -v "$data_dir:/data:rw" \
  "${user_args[@]}" \
  "$IMAGE"
