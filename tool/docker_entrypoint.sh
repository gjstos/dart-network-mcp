#!/bin/sh
set -eu
export HOME=/home/mcp
export DART_NETWORK_MCP_DATA=/data
export DART_NETWORK_MCP_IN_DOCKER=1
exec /usr/local/bin/dart_network_mcp
