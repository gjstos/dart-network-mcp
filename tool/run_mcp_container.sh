#!/usr/bin/env bash
set -euo pipefail

IMAGE=dart-network-mcp:local

reap_ours() {
  local id image
  local ids
  local -a drop=()
  ids="$(docker ps -aq --filter status=exited)"
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

resolve_dart_dtd_dir() {
  if [[ -n "${DART_NETWORK_MCP_DTD_DIR:-}" ]]; then
    printf '%s' "$DART_NETWORK_MCP_DTD_DIR"
    return
  fi
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      printf '%s' "$home/Library/Application Support/Dart/dtd"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      printf '%s' "${LOCALAPPDATA:-$home/AppData/Local}/Dart/dtd"
      ;;
    *)
      printf '%s' "${XDG_DATA_HOME:-$home/.local/share}/Dart/dtd"
      ;;
  esac
}

dart_dtd_dir="$(resolve_dart_dtd_dir)"
mkdir -p "$home/.dart-tool" "$dart_dtd_dir"

user_args=()
case "$(uname -s 2>/dev/null || true)" in
  MINGW* | MSYS* | CYGWIN*) ;;
  *) user_args=(-u "$(id -u):$(id -g)") ;;
esac

exec docker run \
  -i \
  --rm \
  --add-host=host.docker.internal:host-gateway \
  -e HOME=/home/mcp \
  -e DART_NETWORK_MCP_DATA=/data \
  -e DART_NETWORK_MCP_IN_DOCKER=1 \
  -e DART_NETWORK_MCP_DTD_DIR=/home/mcp/Dart/dtd \
  -v "$home/.dart-tool:/home/mcp/.dart-tool:ro" \
  -v "$dart_dtd_dir:/home/mcp/Dart/dtd:ro" \
  -v "$data_dir:/data:rw" \
  "${user_args[@]}" \
  "$IMAGE"
