#!/bin/sh
set -eu
export HOME=/home/mcp
export DART_VM_MCP_DATA=/data
export DART_VM_MCP_IN_DOCKER=1
exec /usr/local/bin/dart_vm_mcp
