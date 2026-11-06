#!/usr/bin/env bash
# Prints the tool names the Grafana MCP server exposes, via a JSON-RPC `tools/list` over stdio.
# Use it to verify the read-only / Loki-only restriction in scripts/grafana-mcp.sh.
# Usage: scripts/mcp-tools-list.sh [environment]   (default lab; expected: 9 datasource + loki tools)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"tools-list","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | "$ROOT/scripts/grafana-mcp.sh" "${1:-lab}" 2>/dev/null \
  | jq -r 'select(.id==2) | .result.tools[].name' | sort
