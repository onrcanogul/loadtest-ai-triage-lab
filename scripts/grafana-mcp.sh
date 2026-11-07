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
# Run modes:
#   binary (DEFAULT, every environment) - runs an `mcp-grafana` executable directly:
#           MCP_GRAFANA_BIN=/path/to/mcp-grafana, or `mcp-grafana` on PATH
#           (go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest, or a GitHub release).
#           No Docker. GRAFANA_URL defaults to http://localhost:3000.
#   docker (LAB ONLY)                   - `docker run mcp/grafana`, used for the lab when no binary is
#           installed, because the lab's Grafana already runs in docker compose on this machine.
#           GRAFANA_URL defaults to http://host.docker.internal:3000.
#   Any other environment (uat, preprod, ...) never falls back to Docker: corporate workstations are not
#   assumed to have it. Set MCP_GRAFANA_MODE=docker explicitly if you really want Docker there.
#   Corporate proxy / custom CA pass through in both modes: HTTPS_PROXY, HTTP_PROXY, NO_PROXY and
#   SSL_CERT_FILE (in docker mode the CA bundle is bind-mounted read-only into the container).
#
# Environment TYPE (first line of triage/environments/<environment>.md: `<!-- triage-env type=ide|script -->`):
#   ide    - the server may be registered in IDE MCP configs and started by any chat (lab only).
#   script - LOCKED: the server starts only as a child of scripts/triage.sh, which passes a lock file in
#            LOADTEST_TRIAGE_LOCK (contains the pid of the running triage.sh). Without a live lock the server
#            refuses to start, so no IDE chat, prompt or injected instruction can ever reach that Grafana.
#            A missing definition file or marker counts as `script` (fail closed).
#
# Env (from .env.mcp.<environment> or the caller):
#   GRAFANA_SERVICE_ACCOUNT_TOKEN      token (scripts/create-grafana-sa-token.sh writes it for the lab), or
#   GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD  a shell command whose stdout is the token (vault, az keyvault, op read, ...);
#                                      evaluated at every start, nothing is written to disk. Wins over the static one.
#   GRAFANA_URL                    optional, mode-dependent default (see above)
#   MCP_GRAFANA_BIN                optional, path to an mcp-grafana binary
#   MCP_GRAFANA_MODE               optional, binary | docker  (default: binary; docker auto-fallback only for lab)
#   MCP_GRAFANA_EXTRA_ARGS         optional, extra flags appended to the server command line
#   MCP_AUDIT_LOG                  optional, path: every tools/call is appended there as JSONL through
#                                  scripts/mcp-audit-proxy.py (triage.sh sets it; proves the report used real queries)
#   HTTPS_PROXY / HTTP_PROXY / NO_PROXY / SSL_CERT_FILE   optional, passed through
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_ENV="${1:-lab}"
case "$MCP_ENV" in
  *[!a-z0-9_-]*|"") echo "grafana-mcp.sh: invalid environment name '$MCP_ENV' (use e.g. lab, uat, preprod)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- environment type + lock
ENV_DEF="$ROOT/triage/environments/$MCP_ENV.md"
ENV_TYPE="script"
if [ -f "$ENV_DEF" ]; then
  ENV_TYPE="$(head -n 1 "$ENV_DEF" | sed -n 's/.*triage-env type=\([a-z]*\).*/\1/p')"
  ENV_TYPE="${ENV_TYPE:-script}"
fi
if [ "$ENV_TYPE" = "script" ]; then
  LOCK="${LOADTEST_TRIAGE_LOCK:-}"
  LOCK_PID=""
  [ -n "$LOCK" ] && [ -f "$LOCK" ] && LOCK_PID="$(head -n 1 "$LOCK" | tr -dc '0-9')"
  if [ -z "$LOCK_PID" ] || ! kill -0 "$LOCK_PID" 2>/dev/null; then
    cat >&2 <<MSG
grafana-mcp.sh: environment '$MCP_ENV' is LOCKED (type=script): only scripts/triage.sh may start this server.
  No live triage lock was found (LOADTEST_TRIAGE_LOCK='${LOCK:-}'). This is by design: a script-type
  environment is never registered in an IDE and cannot be reached from a chat or a prompt.
  Run:  scripts/triage.sh $MCP_ENV <from> <to> [--service <name>]
MSG
    exit 1
  fi
  echo "grafana-mcp.sh: environment=$MCP_ENV type=script lock=$(basename "$LOCK") (triage.sh pid $LOCK_PID)" >&2
else
  echo "grafana-mcp.sh: environment=$MCP_ENV type=$ENV_TYPE" >&2
fi


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

# ---------------------------------------------------------------- token (command wins over static value)
if [ -n "${GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD:-}" ]; then
  if ! GRAFANA_SERVICE_ACCOUNT_TOKEN="$(bash -c "$GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD" </dev/null | tr -d '\r\n')" \
     || [ -z "$GRAFANA_SERVICE_ACCOUNT_TOKEN" ]; then
    echo "grafana-mcp.sh: GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD produced no token (is your key management session active?)" >&2
    exit 1
  fi
  echo "grafana-mcp.sh: token fetched via GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD (not stored)" >&2
fi
: "${GRAFANA_SERVICE_ACCOUNT_TOKEN:?neither GRAFANA_SERVICE_ACCOUNT_TOKEN nor GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD is set in $ENV_FILE}"

# Tool surface: ONLY datasource + loki tool categories, and no write tools even inside those.
# Flag names verified against `mcp-grafana --help` (mcp/grafana image, 2026-11).
# `--enabled-tools` is an allowlist, so every other category (dashboard, alerting, incident, oncall,
# admin, api, search, prometheus, sift, asserts, pyroscope, navigation, annotations, rendering,
# snapshot, plugin, config, provisioning, proxied, folder) is off without naming each one.
# Verified result: 9 tools (list_datasources, get_datasource, check_datasources_health,
# list_loki_label_names, list_loki_label_values, query_loki_logs, query_loki_stats,
# query_loki_patterns, analyze_loki_labels). Verify yourself with scripts/mcp-tools-list.sh.
MCP_ARGS=(-t stdio --enabled-tools datasource,loki --disable-write)
# shellcheck disable=SC2206
[ -n "${MCP_GRAFANA_EXTRA_ARGS:-}" ] && MCP_ARGS+=(${MCP_GRAFANA_EXTRA_ARGS})
# Optional audit proxy in front of the server (stdio passthrough that records tools/call as JSONL).
AUDIT=()
if [ -n "${MCP_AUDIT_LOG:-}" ]; then
  command -v python3 >/dev/null || { echo "grafana-mcp.sh: MCP_AUDIT_LOG needs python3" >&2; exit 1; }
  AUDIT=(python3 "$ROOT/scripts/mcp-audit-proxy.py" "$MCP_AUDIT_LOG" --)
  echo "grafana-mcp.sh: audit log -> $MCP_AUDIT_LOG" >&2
fi

# ---------------------------------------------------------------- mode selection
MODE="${MCP_GRAFANA_MODE:-binary}"
case "$MODE" in
  binary|docker) ;;
  *) echo "grafana-mcp.sh: MCP_GRAFANA_MODE='$MODE' must be 'binary' or 'docker'" >&2; exit 1 ;;
esac

BIN="${MCP_GRAFANA_BIN:-}"
if [ "$MODE" = "binary" ] && [ -z "$BIN" ] && command -v mcp-grafana >/dev/null 2>&1; then
  BIN="$(command -v mcp-grafana)"
fi

if [ "$MODE" = "binary" ] && [ -z "$BIN" ]; then
  if [ "$MCP_ENV" = "lab" ] && command -v docker >/dev/null 2>&1; then
    # Lab convenience only: the lab stack is docker compose anyway, so the MCP server may run there too.
    echo "grafana-mcp.sh: no mcp-grafana binary found; lab falls back to docker (set MCP_GRAFANA_BIN to avoid this)" >&2
    MODE="docker"
  else
    cat >&2 <<MSG
grafana-mcp.sh: environment '$MCP_ENV' needs an mcp-grafana binary and none was found
  (MCP_GRAFANA_BIN is unset and 'mcp-grafana' is not on PATH).
  Docker is used automatically for the lab only; other environments run the native binary so that
  a corporate workstation without Docker works unchanged.
  Install: go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest   (or a GitHub release binary)
  then add  MCP_GRAFANA_BIN=/path/to/mcp-grafana  to $(basename "$ENV_FILE").
  To force Docker anyway: MCP_GRAFANA_MODE=docker in that file.
MSG
    exit 1
  fi
fi

# ---------------------------------------------------------------- binary mode (default)
if [ "$MODE" = "binary" ]; then
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
  exec ${AUDIT[@]+"${AUDIT[@]}"} "$BIN" "${MCP_ARGS[@]}"
fi

# ---------------------------------------------------------------- docker mode (lab, or MCP_GRAFANA_MODE=docker)
if ! command -v docker >/dev/null 2>&1; then
  echo "grafana-mcp.sh: MCP_GRAFANA_MODE=docker but 'docker' is not installed" >&2
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
echo "grafana-mcp.sh: docker mode (mcp/grafana) -> $GRAFANA_URL" >&2
exec ${AUDIT[@]+"${AUDIT[@]}"} docker "${DOCKER_ARGS[@]}" mcp/grafana "${MCP_ARGS[@]}"
