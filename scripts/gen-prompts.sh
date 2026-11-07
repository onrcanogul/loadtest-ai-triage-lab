#!/usr/bin/env bash
# Generates one GitHub Copilot prompt file per `ide`-type environment from a single template, and checks
# that no `script`-type environment leaks into an IDE.
#
#   environments : every triage/environments/<env>.md; first line `<!-- triage-env type=ide|script -->`
#   template     : triage/templates/loadtest-triage.prompt.md.tmpl
#   output       : .github/prompts/<env>-loadtest-triage.prompt.md      (ide environments only)
#
# ide    : prompt file generated, server may be registered in .mcp.json / .vscode/mcp.json / .cursor/mcp.json
# script : NO prompt file, NO IDE registration; only scripts/triage.sh starts the server (see grafana-mcp.sh).
#          A stale prompt file for a script environment is deleted (generate) or reported (--check), and a
#          `grafana-<env>` entry for it in any IDE config fails the check in both modes.
#
# Why per-environment files instead of an ${input:env} parameter: a prompt file's `tools` list is static,
# and it is the only HARD guard inside Copilot that keeps a lab triage on the lab server.
# Re-run after adding an environment or editing the template. `--check` only reports (CI).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/triage/templates/loadtest-triage.prompt.md.tmpl"
OUT_DIR="$ROOT/.github/prompts"
ENV_DIR="$ROOT/triage/environments"
IDE_CONFIGS=(.mcp.json .vscode/mcp.json .cursor/mcp.json)
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

# Read-only datasource + Loki tools exposed by scripts/grafana-mcp.sh (verify: scripts/mcp-tools-list.sh <env>)
TOOLS=(list_datasources get_datasource check_datasources_health list_loki_label_names list_loki_label_values
       query_loki_logs query_loki_stats query_loki_patterns analyze_loki_labels)

[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }
mkdir -p "$OUT_DIR"

env_type() { # prints ide|script; missing marker = script (fail closed)
  local t; t="$(head -n 1 "$1" | sed -n 's/.*triage-env type=\([a-z]*\).*/\1/p')"; echo "${t:-script}"
}

fail=0; count=0
for envfile in "$ENV_DIR"/*.md; do
  env="$(basename "$envfile" .md)"
  case "$env" in *[!a-z0-9_-]*) echo "skip '$env': invalid environment name" >&2; continue ;; esac
  type="$(env_type "$envfile")"
  out="$OUT_DIR/$env-loadtest-triage.prompt.md"
  count=$((count+1))

  if [ "$type" = "script" ]; then
    if [ -f "$out" ]; then
      if [ "$CHECK" = 1 ]; then echo "STALE: $out exists but '$env' is a script-type environment"; fail=1
      else rm -f "$out"; echo "removed $out ('$env' is script-type: no chat prompt)"; fi
    fi
    for cfg in "${IDE_CONFIGS[@]}"; do
      if [ -f "$ROOT/$cfg" ] && grep -q "\"grafana-$env\"" "$ROOT/$cfg"; then
        echo "LEAK: $cfg registers grafana-$env, but '$env' is a script-type environment (remove it)"; fail=1
      fi
    done
    echo "$env: script-type, no prompt file (use scripts/triage.sh $env ...)"
    continue
  fi

  tools=""
  for t in "${TOOLS[@]}"; do tools="${tools:+$tools, }'grafana-$env/$t'"; done
  rendered="$(sed -e "s/__ENV__/$env/g" -e "s|__TOOLS__|$tools|g" "$TEMPLATE")"
  if [ "$CHECK" = 1 ]; then
    if [ ! -f "$out" ] || [ "$(cat "$out")" != "$rendered" ]; then echo "STALE: $out"; fail=1; fi
  else
    printf '%s\n' "$rendered" > "$out"
    echo "wrote $out"
  fi
done

[ "$count" -gt 0 ] || { echo "no environments found in $ENV_DIR" >&2; exit 1; }
if [ "$CHECK" = 1 ] && [ "$fail" = 0 ]; then echo "prompts up to date, no IDE leaks ($count environments)"; fi
exit "$fail"
