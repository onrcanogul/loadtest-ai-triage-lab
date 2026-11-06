#!/usr/bin/env bash
# Creates (or reuses) a Viewer service account in Grafana and writes a fresh token to .env.mcp.<environment>.
# Usage: scripts/create-grafana-sa-token.sh [grafana-url] [admin-user] [admin-password] [environment]
#   environment (default lab) selects the output file .env.mcp.<environment>.
#   For a corporate environment (uat, preprod) you usually get a token from the Grafana admins instead:
#   copy .env.mcp.uat.example to .env.mcp.uat and paste it there.
#   GRAFANA_ORG_ID=<id>  optional: create the SA / token inside that org (see "single datasource" below)
set -euo pipefail

GRAFANA="${1:-http://localhost:3000}"
ADMIN_USER="${2:-admin}"
ADMIN_PASS="${3:-admin}"
SA_NAME="ai-triage"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_ENV="${4:-lab}"
ENV_FILE="$ROOT/.env.mcp.$MCP_ENV"

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

ORG_HDR=()
[ -n "${GRAFANA_ORG_ID:-}" ] && ORG_HDR=(-H "X-Grafana-Org-Id: $GRAFANA_ORG_ID")
# "${ORG_HDR[@]+"${ORG_HDR[@]}"}" keeps bash 3.2 (macOS) happy under `set -u` when the array is empty
api() { curl -sS -u "$ADMIN_USER:$ADMIN_PASS" -H 'Content-Type: application/json' ${ORG_HDR[@]+"${ORG_HDR[@]}"} "$@"; }

# 1) find or create the service account
SA_ID="$(api "$GRAFANA/api/serviceaccounts/search?query=$SA_NAME" | jq -r --arg n "$SA_NAME" '.serviceAccounts[] | select(.name==$n) | .id' | head -n1)"
if [ -z "$SA_ID" ]; then
  SA_ID="$(api -X POST "$GRAFANA/api/serviceaccounts" -d "{\"name\":\"$SA_NAME\",\"role\":\"Viewer\"}" | jq -r '.id')"
  echo "created service account $SA_NAME (id=$SA_ID)"
else
  echo "service account $SA_NAME already exists (id=$SA_ID)"
fi

# 2) create a new token (old ones stay valid; delete them in Grafana UI if you want)
TOKEN="$(api -X POST "$GRAFANA/api/serviceaccounts/$SA_ID/tokens" -d "{\"name\":\"$SA_NAME-$(date +%Y%m%d%H%M%S)\"}" | jq -r '.key')"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "token creation failed"; exit 1; }

# 3) write .env.mcp (the MCP server runs in docker, so Grafana is reached via host.docker.internal)
cat > "$ENV_FILE" <<EOT
GRAFANA_URL=http://host.docker.internal:3000
GRAFANA_SERVICE_ACCOUNT_TOKEN=$TOKEN
EOT
chmod 600 "$ENV_FILE"
echo "token written to $ENV_FILE"

# ------------------------------------------------------------------------------------------------
# Kurumsal ortam: service account'u TEK datasource ile sınırlamak
# A Viewer service account can query EVERY datasource of its org. The MCP server is already started
# read-only / Loki-only (scripts/grafana-mcp.sh: --enabled-tools datasource,loki --disable-write), but
# the token is the last line of defence if someone starts the server with other flags. To restrict it:
#
#  * Grafana Enterprise / Grafana Cloud - data source permissions (RBAC):
#      UI:  Administration -> Data sources -> <Loki> -> Permissions
#           - add the service account "ai-triage" with permission "Query" on the Loki datasource;
#           - on every OTHER datasource remove the built-in "Viewer" role's Query permission
#             (or remove Viewer on all datasources and grant per-datasource, which is cleaner).
#      API (admin basic auth; SA_ID is the id printed above - service accounts are users for this API):
#        curl -u admin:admin -X POST "$GRAFANA/api/access-control/datasources/<LOKI_UID>/users/$SA_ID" \
#             -H 'Content-Type: application/json' -d '{"permission":"Query"}'
#        curl -u admin:admin -X POST "$GRAFANA/api/access-control/datasources/<OTHER_UID>/builtInRoles/Viewer" \
#             -H 'Content-Type: application/json' -d '{"permission":""}'      # empty = remove
#        curl -u admin:admin "$GRAFANA/api/access-control/datasources/<LOKI_UID>"   # inspect
#
#  * Grafana OSS (no datasource permissions): create a dedicated org that contains ONLY the Loki
#      datasource (optionally pointed at a single Loki tenant via the X-Scope-OrgID header), then run
#      this script with GRAFANA_ORG_ID=<that org id> so the SA and token live in that org.
#        curl -u admin:admin -X POST $GRAFANA/api/orgs -H 'Content-Type: application/json' -d '{"name":"ai-triage"}'
#
#  * Keep role=Viewer; never Editor/Admin. Rotate tokens (a new one is created on every run) and give
#      them an expiry in a corporate setup: -d '{"name":"...","secondsToLive":2592000}'.
#  * Verify: with the restricted token `list_datasources` (MCP) returns only Loki, and
#        curl -H "Authorization: Bearer $TOKEN" $GRAFANA/api/datasources     lists exactly one entry.
# ------------------------------------------------------------------------------------------------
