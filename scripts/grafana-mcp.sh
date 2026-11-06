#!/usr/bin/env bash
# Starts the Grafana MCP server over stdio, restricted to READ-ONLY Loki + datasource tools.
# All AI clients (.mcp.json, .vscode/mcp.json, .cursor/mcp.json) point here, so the
# connection details live in exactly one place: this script + one env file PER ENVIRONMENT.
#
# Usage: scripts/grafana-mcp.sh [environment]      (default: lab)
#   environment -> .env.mcp.<environment>  (e.g. .env.mcp.lab, .env.mcp.uat)
#   The environment decides WHICH Grafana (and therefore which Loki) the AI client reads.
#   Clients register one MCP server per environment (grafana-lab, grafana-uat), so a triage
#   against UAT can never silently read lab data, and vice versa.
#
# Two run modes (picked automatically):
#   1) Binary  - if MCP_GRAFANA_BIN is set, or an `mcp-grafana` binary is on PATH
#                (go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest, or a GitHub release).
#                No Docker needed; GRAFANA_URL defaults to http://localhost:3000.
#   2) Docker  - otherwise `docker run mcp/grafana`; GRAFANA_URL defaults to http://host.docker.internal:3000.
#                Corporate proxy / custom CA are passed through: HTTPS_PROXY, HTTP_PROXY, NO_PROXY and
#                SSL_CERT_FILE (the CA bundle file is bind-mounted read-only into the container).
#
# Env (from .env.mcp or the caller):
#   GRAFANA_SERVICE_ACCOUNT_TOKEN  required (scripts/create-grafana-sa-token.sh writes it)
#   GRAFANA_URL                    optional, mode-dependent default (see above)
#   MCP_GRAFANA_BIN                optional, path to an mcp-grafana binary -> forces binary mode
#   MCP_GRAFANA_EXTRA_ARGS         optional, extra flags appended to the server command line
#   HTTPS_PROXY / HTTP_PROXY / NO_PROXY / SSL_CERT_FILE   optional, passed through
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_ENV="${1:-lab}"
case "$MCP_ENV" in
  *[!a-z0-9_-]*|"") echo "grafana-mcp.sh: invalid environment name '$MCP_ENV' (use e.g. lab, uat, preprod)" >&2; exit 1 ;;
esac

ENV_FILE="$ROOT/.env.mcp.$MCP_ENV"
# backwards compatibility: the lab used to live in plain .env.mcp
if [ ! -f "$ENV_FILE" ] && [ "$MCP_ENV" = "lab" ] && [ -f "$ROOT/.env.mcp" ]; then
  ENV_FILE="$ROOT/.env.mcp"
fi
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ENV_FILE"
  set +a
else
  echo "grafana-mcp.sh: environment '$MCP_ENV' has no env file ($ENV_FILE)." >&2
  echo "  lab: run scripts/create-grafana-sa-token.sh   other envs: copy .env.mcp.uat.example and fill GRAFANA_URL + token" >&2
  exit 1
fi

: "${GRAFANA_SERVICE_ACCOUNT_TOKEN:?GRAFANA_SERVICE_ACCOUNT_TOKEN is not set in $ENV_FILE}"
echo "grafana-mcp.sh: environment=$MCP_ENV env-file=$(basename "$ENV_FILE")" >&2

# Tool surface: ONLY datasource + loki tool categories, and no write tools even inside those.
# Flag names verified against `docker run --rm mcp/grafana --help` (mcp-grafana image, 2026-11).
# `--enabled-tools` is an allowlist, so every other category (dashboard, alerting, incident, oncall,
# admin, api, search, prometheus, sift, asserts, pyroscope, navigation, annotations, rendering,
# snapshot, plugin, config, provisioning, proxied, folder) is off without naming each one.
# Verified result: 9 tools (list_datasources, get_datasource, check_datasources_health,
# list_loki_label_names, list_loki_label_values, query_loki_logs, query_loki_stats,
# query_loki_patterns, analyze_loki_labels). Verify yourself with scripts/mcp-tools-list.sh.
MCP_ARGS=(-t stdio --enabled-tools datasource,loki --disable-write)
# shellcheck disable=SC2206
[ -n "${MCP_GRAFANA_EXTRA_ARGS:-}" ] && MCP_ARGS+=(${MCP_GRAFANA_EXTRA_ARGS})

# ---------------------------------------------------------------- mode 1: native binary (no Docker)
BIN="${MCP_GRAFANA_BIN:-}"
if [ -z "$BIN" ] && command -v mcp-grafana >/dev/null 2>&1; then
  BIN="$(command -v mcp-grafana)"
fi

if [ -n "$BIN" ]; then
  if [ ! -f "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "grafana-mcp.sh: MCP_GRAFANA_BIN='$BIN' is not an executable file" >&2
    exit 1
  fi
  # Pre-flight: mcp-grafana answers --help with exit 0; anything else is not the server we expect.
  if ! "$BIN" --help >/dev/null 2>&1; then
    echo "grafana-mcp.sh: '$BIN --help' failed - this does not look like an mcp-grafana binary" >&2
    exit 1
  fi
  # A native process talks to Grafana on this host directly, never via host.docker.internal.
  case "${GRAFANA_URL:-}" in
    ""|*host.docker.internal*) GRAFANA_URL="http://localhost:3000" ;;
  esac
  export GRAFANA_URL GRAFANA_SERVICE_ACCOUNT_TOKEN
  echo "grafana-mcp.sh: binary mode ($BIN) -> $GRAFANA_URL" >&2
  exec "$BIN" "${MCP_ARGS[@]}"
fi

# ---------------------------------------------------------------- mode 2: docker image
if ! command -v docker >/dev/null 2>&1; then
  cat >&2 <<'MSG'
grafana-mcp.sh: neither an mcp-grafana binary (MCP_GRAFANA_BIN / PATH) nor `docker` was found.
  Docker-free setup: go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest
  (or download a release binary) and set MCP_GRAFANA_BIN=/path/to/mcp-grafana in .env.mcp.
MSG
  exit 1
fi

: "${GRAFANA_URL:=http://host.docker.internal:3000}"

DOCKER_ARGS=(run --rm -i -e GRAFANA_URL -e GRAFANA_SERVICE_ACCOUNT_TOKEN)
# Corporate proxy passthrough (only the variables that are actually set).
for v in HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy; do
  [ -n "${!v:-}" ] && DOCKER_ARGS+=(-e "$v")
done
# Custom CA bundle (e.g. corporate TLS inspection proxy): mount it and point Go's TLS at it.
if [ -n "${SSL_CERT_FILE:-}" ]; then
  if [ ! -r "$SSL_CERT_FILE" ]; then
    echo "grafana-mcp.sh: SSL_CERT_FILE='$SSL_CERT_FILE' is not readable" >&2
    exit 1
  fi
  DOCKER_ARGS+=(-v "$SSL_CERT_FILE:/etc/ssl/corp-ca.pem:ro" -e SSL_CERT_FILE=/etc/ssl/corp-ca.pem)
fi

export GRAFANA_URL GRAFANA_SERVICE_ACCOUNT_TOKEN
exec docker "${DOCKER_ARGS[@]}" mcp/grafana "${MCP_ARGS[@]}"
