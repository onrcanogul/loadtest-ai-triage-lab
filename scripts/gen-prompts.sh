#!/usr/bin/env bash
# Generates one GitHub Copilot prompt file per environment from a single template.
#
#   environments : every triage/environments/<env>.md  (lab.md, uat.md, ...)
#   template     : triage/templates/loadtest-triage.prompt.md.tmpl
#   output       : .github/prompts/<env>-loadtest-triage.prompt.md
#
# Why per-environment files instead of an ${input:env} parameter: a prompt file's `tools` list is static,
# and it is the only HARD guard that keeps a UAT triage from querying the lab server (or the reverse).
# The template is the single source of the prompt body; this script keeps the files from drifting.
# Re-run after adding an environment or editing the template. `--check` only reports stale files (CI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/triage/templates/loadtest-triage.prompt.md.tmpl"
OUT_DIR="$ROOT/.github/prompts"
ENV_DIR="$ROOT/triage/environments"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

# Read-only datasource + Loki tools exposed by scripts/grafana-mcp.sh (verify: scripts/mcp-tools-list.sh <env>)
TOOLS=(list_datasources get_datasource check_datasources_health list_loki_label_names list_loki_label_values
       query_loki_logs query_loki_stats query_loki_patterns analyze_loki_labels)

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }
mkdir -p "$OUT_DIR"

stale=0; count=0
for envfile in "$ENV_DIR"/*.md; do
  env="$(basename "$envfile" .md)"
  case "$env" in *[!a-z0-9_-]*) echo "skip '$env': invalid environment name" >&2; continue ;; esac
  tools=""
  for t in "${TOOLS[@]}"; do tools="${tools:+$tools, }'grafana-$env/$t'"; done
  out="$OUT_DIR/$env-loadtest-triage.prompt.md"
  rendered="$(sed -e "s/__ENV__/$env/g" -e "s|__TOOLS__|$tools|g" "$TEMPLATE")"
  if [ "$CHECK" = 1 ]; then
    if [ ! -f "$out" ] || [ "$(cat "$out")" != "$rendered" ]; then echo "STALE: $out"; stale=1; fi
  else
    printf '%s\n' "$rendered" > "$out"
    echo "wrote $out"
  fi
  count=$((count+1))
done

[ "$count" -gt 0 ] || { echo "no environments found in $ENV_DIR" >&2; exit 1; }
if [ "$CHECK" = 1 ]; then
  [ "$stale" = 0 ] && echo "prompts up to date ($count environments)"
  exit "$stale"
fi
