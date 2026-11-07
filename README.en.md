# loadtest-ai-triage-lab

> Türkçe sürüm: [README.md](README.md)

A local lab for **AI-assisted triage of endpoints that break under load**. Two Spring Boot services
(`credit-service` → `scoring-service`) fail on purpose under a k6 load test, their logs flow into Loki, Grafana
shows them, and any AI client (Claude Code, GitHub Copilot, Cursor) queries Loki through the **Grafana MCP server**
to produce a root-cause report.

- **Loki is the only data source** (no Tempo, no Prometheus). Trace correlation uses the `traceId` field in the log
  lines; the same `traceId` is logged by both services (W3C `traceparent`), so the report can say *which* service owns
  the root cause.
- **The triage logic lives in one file**: [`triage/LOADTEST_TRIAGE.md`](triage/LOADTEST_TRIAGE.md). Client configs only
  reference it.
- **The triage is independent of the load-test tool**: its inputs are an environment name and a time window
  (plus an optional service name). Neither the services nor the triage know anything about k6.

## Architecture

```
k6 (profile: loadtest) ──HTTP──> credit-service:8080 ──HTTP + traceparent──> scoring-service:8081
                                 (Spring Boot, JSON log → stdout)           (Spring Boot, JSON log → stdout)
                                        │ docker log                               │ docker log
                                        └──────────────────┬───────────────────────┘
                                                           ▼
                                  alloy (discovery.docker + loki.source.docker)
                                        │ labels: service, level  |  structured metadata: traceId
                                        ▼
                                      loki:3100  <── grafana:3000 (dashboard + datasource uid=loki)
                                                          ▲
                              AI client ──stdio──> mcp-grafana (binary; docker lab-only) ── service account token
```

One request is logged by both services with the **same `traceId`**: the auto-configured `RestClient.Builder` of
`credit-service` (Micrometer Observation) adds the W3C `traceparent` header to the outgoing call and `scoring-service`
continues it. Alloy collects both containers and derives the `service` label from the container name; no extra config.

### credit-service (Spring Boot 3.4, Java 21)
Shopping-loan API, package `com.lab.credit`:

| Endpoint | Description |
|---|---|
| `POST /api/v1/loans/shopping/apply` | body `{customerId, amount, installmentCount, campaignCode?}` → `201 {applicationId, status, monthlyInstallment}` |
| `GET /api/v1/loans/{applicationId}` | `200` or `404` |
| `GET /actuator/health` | health |
| `GET /v3/api-docs` | OpenAPI 3 document (springdoc); the `openapi` tool of the `ai-workspace` repo snapshots it |

Flow: `LoanController → LoanApplicationService → ScoringClient (HTTP → scoring-service) → InstallmentCalculator → LoanApplicationRepository (ConcurrentHashMap)`.

`ScoringClient` calls `POST /api/v1/scores` on `scoring.base-url` (env `SCORING_BASE_URL`, default
`http://scoring-service:8081`); connect timeout 1 s, read timeout 5 s (longer than the downstream 2 s pool wait plus
worst-case latency, so the signal is *its* 503, not our timeout). Any 5xx, connection or timeout error from
scoring-service becomes `ScoringUnavailableException` → **503**, logged at ERROR with `exceptionClass` / `exceptionMessage`.

### scoring-service (Spring Boot 3.4, Java 21)
Credit-score service (stands in for a credit bureau), package `com.lab.scoring`, port 8081:

| Endpoint | Description |
|---|---|
| `POST /api/v1/scores` | body `{customerId}` → `200 {customerId, score}`; **503** `{error: SCORING_POOL_EXHAUSTED}` when the pool is full |
| `GET /actuator/health` | health |
| `GET /v3/api-docs` | OpenAPI 3 document (springdoc); the `openapi` tool of the `ai-workspace` repo snapshots it |

Flow: `ScoreController → ScoringService` (semaphore pool + deterministic score).

**Deliberate failure modes** (both ON by default, switched off per env var; each lives in its own service):

| Env | Service / class | Behaviour |
|---|---|---|
| `FAILURE_POOL_EXHAUSTION=true` | `scoring-service` / `ScoringService` | `Semaphore(10)` "connection pool". Latency = 150 ms + 15 ms × inflight + jitter, so latency grows with concurrency until `tryAcquire(2s)` fails → `ScoringPoolExhaustedException` → **503**. ERROR log: `scoring pool exhausted, inflight=N, waited=2000ms, poolSize=10`. `credit-service` reflects it as `ScoringUnavailableException` → **503**. **Load-dependent, root cause downstream.** |
| `FAILURE_NPE_BUG=true` | `credit-service` / `InstallmentCalculator` | When `campaignCode` is null and `installmentCount >= 9`, `campaign.getRate()` throws **NullPointerException** → **500** via `@RestControllerAdvice`, stack trace logged. **Load-independent code bug, root cause upstream.** |

**Logging (identical in both services):** `logstash-logback-encoder` writes one JSON object per line to stdout;
`micrometer-tracing-bridge-brave` puts `traceId`/`spanId` into the MDC (no exporter, sampling 1.0, W3C propagation).
Every line carries `@timestamp, level, logger, message, traceId, spanId, service=<credit-service|scoring-service>` and,
when present, `customerId, applicationId, endpoint`. `RequestLogFilter` writes exactly one `request completed` line per
request with `endpoint` (route pattern), `httpStatus`, `durationMs` and, on errors, `exceptionClass`/`exceptionMessage`.

## Running it

```bash
docker compose up -d --build
```

```bash
curl -s localhost:8080/actuator/health && curl -s localhost:8081/actuator/health
```

To see one request logged by both services with the same `traceId`:

```bash
curl -s -X POST localhost:8080/api/v1/loans/shopping/apply -H 'Content-Type: application/json' -d '{"customerId":"C100001","amount":12000,"installmentCount":6,"campaignCode":"POS2025"}' && docker logs credit-service 2>&1 | tail -3 | jq -c '{service,traceId,message}' && docker logs scoring-service 2>&1 | tail -3 | jq -c '{service,traceId,message}'
```

Load test (k6 exists only to generate failures; it runs under the `loadtest` profile):

```bash
docker compose --profile loadtest run --rm k6
```

Scenario (`k6/shopping-loan-load.js`): 0→20 VU in 30 s, 20→80 VU in 60 s, 80 VU for 60 s, →0 in 20 s. 90 % of
requests carry a valid `campaignCode`; 10 % omit it and use `installmentCount` 9 or 12 (triggers the NPE).
Thresholds: `http_req_failed rate<0.05` (**abortOnFail**) and `http_req_duration p(95)<800ms`.

> **Decision:** `delayAbortEval` is **120 s**, not the 30 s of the original spec. With 30 s the constant ~5 % NPE
> errors alone would abort the run at 20 VU, before the load-dependent pool exhaustion ever appears. With 120 s the
> ramp reaches 80 VU, the 503s start, and only then does the test "blow up" and abort, so both root causes land in Loki.

## Where to look in Grafana

http://localhost:3000 (admin / admin) → Dashboards → **Credit Service - Load Test**:

- **Error rate (5xx / min)** and **total requests / min** — an error that grows with load is load-dependent.
- **Status code distribution** — how 500 (NPE) and 503 (pool) evolve next to 201/200.
- **p95 durationMs** (Loki `unwrap`) — 800 ms threshold in red.
- **Error classes / min** — `NullPointerException` flat, `ScoringUnavailableException` growing with load.
- **Latest error logs** — `{service="$service", level="ERROR"}`.

The `service` variable switches between `credit-service` and `scoring-service`.

Useful Explore queries:

```logql
sum by (httpStatus) (count_over_time({service="credit-service"} |= "request completed" | json [1m]))
quantile_over_time(0.95, {service="credit-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)
{service=~"credit-service|scoring-service"} | traceId="<TRACE_ID>"
sum by (service, httpStatus) (count_over_time({service=~"credit-service|scoring-service"} |= "request completed" | json | httpStatus >= 500 [1m]))
```

Only `service` and `level` are labels; `traceId` is structured metadata (high-cardinality fields never become labels).

## AI triage through the Grafana MCP server

### 1. Service account token

```bash
scripts/create-grafana-sa-token.sh
```

Creates a **Viewer** service account named `ai-triage` plus a token through the Grafana API (admin/admin) and writes
`GRAFANA_URL` + `GRAFANA_SERVICE_ACCOUNT_TOKEN` to `.env.mcp.lab` (git-ignored). For a corporate environment such as
`uat` you get the token from the Grafana admins and fill in `.env.mcp.uat` from `.env.mcp.uat.example`.

### 2. The MCP server: one entry point for every client, one server per environment

**Environment separation.** The triage never reads the code or the local environment of the IDE; its data comes from
the Grafana of the *selected environment* over HTTP. Each environment therefore has its own MCP server
(`grafana-<env>`), its own env file (`.env.mcp.<env>`) and its own definition file (`triage/environments/<env>.md`:
datasource uid, service labels, field mapping, where to read the deployed version). No access to UAT, to the load-test
scripts or to the code running in UAT is needed; network access from the developer machine to the Grafana URL
(VPN / proxy) is enough.

**Environment type: `ide` or `script`.** The first line of the definition file, `<!-- triage-env type=ide|script -->`,
decides how the environment can be triggered. This is the technical form of the requirement "no flow we did not ask
for may ever touch UAT":

| Type | Environments | Registered in an IDE | Trigger | Server lifetime |
|---|---|---|---|---|
| `ide` | `lab` only | yes (`.mcp.json`, `.vscode/mcp.json`, `.cursor/mcp.json`) | from chat (`/loadtest-triage lab …`, `/lab-loadtest-triage`) and `scripts/triage.sh lab …` | managed by the IDE |
| `script` | `dev`, `uat` (corporate) | **no, nowhere** | **only** `scripts/triage.sh <env> <from> <to>` | child of that command; dies when it ends |

For a `script`-type environment `scripts/grafana-mcp.sh` starts only with a live lock file handed over by `triage.sh`
(`LOADTEST_TRIAGE_LOCK`, containing the pid of the running `triage.sh`); without it, or with a dead pid, it refuses.
So an IDE chat, a prompt file or an "instruction" found in a log line cannot reach UAT: there is no server to reach.
Copilot itself offers no such mechanism (a server registered in the workspace is visible to every chat, and a prompt
file's `tools` list only narrows that prompt), which is why the lock lives in the server, not in the client. A missing
definition file or marker counts as `script` (fail closed). Adding an environment = env file + definition file, plus
one line in the client configs only for an `ide`-type one. `scripts/gen-prompts.sh --check` fails in CI when a
`script`-type environment leaks into an IDE config or a prompt file.

`scripts/grafana-mcp.sh <env>` reads `.env.mcp.<env>` and starts `mcp/grafana` **read-only, Loki-only**
(`-t stdio --enabled-tools datasource,loki --disable-write`). **The default mode is a native binary**: it runs
`mcp-grafana` from `PATH` or `MCP_GRAFANA_BIN`, no Docker needed. Only the **lab** environment falls back to
`docker run mcp/grafana` when no binary is installed; `uat` and any other environment never do (see "Corporate
environment notes"). `scripts/mcp-tools-list.sh <env>` prints the exposed tools (9).

Every client carries only a thin config that runs this script; **adding a client = one config file**:

| Client | MCP config (only the `ide`-type `lab`) | Triage from chat (lab) | Locked environments (dev, uat) |
|---|---|---|---|
| Claude Code | [`.mcp.json`](.mcp.json) (`grafana-lab`) | [`.claude/skills/loadtest-triage/SKILL.md`](.claude/skills/loadtest-triage/SKILL.md) → `/loadtest-triage lab --last 15m` | `scripts/triage.sh uat … --agent claude` |
| GitHub Copilot (VS Code) | [`.vscode/mcp.json`](.vscode/mcp.json) (`grafana-lab`) | [`.github/prompts/lab-loadtest-triage.prompt.md`](.github/prompts/lab-loadtest-triage.prompt.md) → `/lab-loadtest-triage` in Chat | `scripts/triage.sh uat … --agent copilot` (Copilot CLI) |
| Cursor | [`.cursor/mcp.json`](.cursor/mcp.json) (`grafana-lab`) | Ask the chat to "apply `triage/LOADTEST_TRIAGE.md` for environment lab, last 15 min" | `scripts/triage.sh` (claude or copilot CLI) |

All of them run the same script with the same env variables; the content exists once, in
[`triage/LOADTEST_TRIAGE.md`](triage/LOADTEST_TRIAGE.md).

**Isolation from everyday skills and prompts (lab).** Even in the lab the triage is kept apart from normal coding
prompts: the Copilot prompt file only runs on an explicit `/lab-loadtest-triage` call and its `tools` list allows just
the `grafana-lab` tools. That file is not hand-written: `scripts/gen-prompts.sh` renders one per `ide`-type environment
from a single template (`triage/templates/loadtest-triage.prompt.md.tmpl`) and deletes the prompt file of any
`script`-type environment; `scripts/gen-prompts.sh --check` catches drift and leaks in CI. Never put triage
instructions into always-loaded files such as `copilot-instructions.md`. The Claude Code skill requires an explicit
`/loadtest-triage <env>` call and, for a `script`-type environment, does not triage but prints the `triage.sh`
command. The triage never edits code: the deployed version may differ from the code in the IDE (see the "Version rule"
in `triage/environments/uat.md`).

If your client cannot resolve the relative `./scripts/grafana-mcp.sh` path, use an absolute one.

**Binary install (required for UAT, optional for lab):** `go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest`
or a GitHub release binary, then `MCP_GRAFANA_BIN=/path/to/mcp-grafana` in `.env.mcp.<env>`. Client configs stay the
same. In binary mode `GRAFANA_URL` defaults to `http://localhost:3000` (not host.docker.internal).

### 3. Running the triage

**Locked environments (dev, uat): one command.**

```bash
scripts/triage.sh uat 2026-11-06T14:00:00+03:00 2026-11-06T14:40:00+03:00 --service credit-service
```

Window forms: two RFC3339 timestamps, `--last 30m`, or `--date 2026-11-06 --from 14:00 --to 14:40 --tz +03:00`.
Options: `--service <name>` (default `credit-service`), `--agent claude|copilot` (default: `copilot` if on PATH, else
`claude`), `--out <file>`, `--dry-run` (runs nothing; prints the command, the temporary MCP config and the prompt —
start with this on day one at the company). The script, in order: validates the window with `triage-window.py` →
writes a lock file and a temporary MCP config known only to this run → hands the fixed prompt (instruction + environment
definition + window, file contents embedded) to the agent CLI non-interactively; the agent has no file, shell or write
tools, only the 9 read-only `grafana-<env>` tools → writes the report to
`triage/reports/<env>-<from>-<to>-<service>.md` → on exit (even when interrupted) removes the lock and the temp
config, and the server dies. `scripts/mcp-audit-proxy.py` sits in front of the server: every `tools/call` (tool name,
LogQL, time range; never log contents) is written next to the report as `…audit.jsonl`. **Zero calls = the report is
rejected** (exit 3, text kept as `.rejected.md`): in the lab, with a wrong Copilot CLI permission syntax, the model wrote a
completely invented report without a single query; this guard catches that and answers "who queried what, when". For Claude the command is `claude -p --mcp-config <tmp> --strict-mcp-config
--allowedTools mcp__grafana-<env>`; for Copilot CLI it is `copilot -p … --additional-mcp-config @<tmp> --allow-tool
grafana-<env> -s --no-ask-user`; if the account's default model is rejected (`CAPIError 400 model is not supported`)
set a model such as `COPILOT_MODEL=gpt-4.1`. **Copilot policy:** on this machine the Copilot CLI 1.0.15 account blocked
custom MCP servers (`--output-format json` shows `1 MCP server was blocked by policy: 'grafana-lab'`); the model never
saw the server, wrote an invented report, and the audit guard rejected it. For the CLI to work at the company the
"MCP servers in Copilot" policy must be enabled; verify on day one with `--dry-run` and a lab run. Older versions also
had bugs combining `-p` with MCP ([github/copilot-cli#1592](https://github.com/github/copilot-cli/issues/1592),
[#633](https://github.com/github/copilot-cli/issues/633)). The Claude Code path is verified end to end in the lab. To keep the token off disk, put `GRAFANA_SERVICE_ACCOUNT_TOKEN_CMD="vault kv get …"` in `.env.mcp.<env>`;
the wrapper runs it at every start and passes the output to the server as an environment variable.

**Lab: from chat.**

- **Claude Code:** open `claude` in the project folder, approve the `.mcp.json` server, then `/loadtest-triage lab --last 15m`.
  Headless:
  `claude -p "/loadtest-triage lab --last 15m" --mcp-config .mcp.json --allowedTools "mcp__grafana-lab,Read,Skill,Bash(python3 scripts/triage-window.py:*)"`
  (the last permission is for the window script; a valid CLI session is required, on "OAuth session expired" run `claude login`).
- **Copilot:** in VS Code start `grafana-lab` from `.vscode/mcp.json`; in Copilot Chat (Agent mode) run `/lab-loadtest-triage` and enter the window.
- **Cursor:** enable `grafana-lab` under Settings → MCP and ask the chat to apply the instruction file for lab.
- The same script works for the lab too: `scripts/triage.sh lab --last 15m`. A prompt change bound for the company is
  tried here first, then in `dev` with the same command.

The inputs are the environment name and the time window ("the load test ran in UAT at ..."); the instruction file
queries only that environment and that window.

**Time-window standard.** The window is a pair of RFC3339 timestamps **with offset**
(`2026-11-06T14:00:00+03:00 2026-11-06T14:35:00+03:00`). Date arithmetic is never left to the model:
`scripts/triage-window.py` validates the input, converts it to UTC and prints `{"from","to"}`, which the model uses
verbatim. The script rejects timestamps without offset, reversed order, windows longer than 12 h and windows in the
future. Shortcuts also go through the script: `--last 15m`, or
`--date 2026-11-06 --from 14:00 --to 14:35 --tz +03:00` for times copied from a test report. Copilot prompts ask for
`from` and `to` separately; the "find it" mode (step 0b) shows the detected window in ISO form and asks for
confirmation before continuing.

### Expected outcome

The report must separate two root causes and place each in the **right service**:

1. **Load-dependent, root cause downstream — scoring pool exhausted:** in `credit-service`,
   `POST /api/v1/loans/shopping/apply` → 503 with `exceptionClass=ScoringUnavailableException`; with the same
   `traceId`, `scoring-service` logs `level=ERROR` `scoring pool exhausted, inflight=N, waited=2000ms, poolSize=10`
   and `POST /api/v1/scores` → 503. It starts and grows as requests/min grow, together with p95. The 503 in
   `credit-service` is a reflection; the fix belongs in `scoring-service`: pool size / timeout / backpressure.
2. **Code bug, root cause upstream — campaignCode NPE** (`NullPointerException` in
   `InstallmentCalculator.resolveRate`, 500, `credit-service` only): a steady ~5 % share independent of traffic,
   present from the first minute. The `scoring-service` side of the same trace is a 200, so downstream is clean.
   Fix: null check / standard rate.

## Verification

The lab was run end to end; the outputs are under `triage/reports/`:

- [`triage/reports/claude-code-headless-two-services-2026-11-06.md`](triage/reports/claude-code-headless-two-services-2026-11-06.md) —
  two-service setup, headless triage run *without* a window ("last hour, find it yourself"): it picked the latest busy
  window with step 0b, placed the 503 root cause in scoring-service (downstream) and the NPE in credit-service
  (upstream), and matched the counts on both sides one to one.
- [`triage/reports/claude-code-headless-2026-11-06.md`](triage/reports/claude-code-headless-2026-11-06.md) — headless
  Claude Code run through `.mcp.json`; both root causes correctly classified (pool exhausted = load, NPE = code bug).
- [`triage/reports/2026-11-06-son-15dk.md`](triage/reports/2026-11-06-son-15dk.md) — second report produced by driving
  the same MCP server over stdio by hand (cross-check).
- [`triage/reports/k6-run-2026-11-06.txt`](triage/reports/k6-run-2026-11-06.txt) — the k6 run that crossed its thresholds
  and aborted.
- [`triage/reports/cross-service-trace-2026-11-06.md`](triage/reports/cross-service-trace-2026-11-06.md) — verification
  after `scoring-service` was split out: one `traceId` across both services, the k6 run, Loki evidence of pool exhaustion.

> The first three reports were produced while scoring was still simulated inside `credit-service`, so they show the
> `scoring pool exhausted` lines under `credit-service`. In today's architecture the same lines live in `scoring-service`.

To repeat the checks yourself:

```bash
cd credit-service && mvn -q package
```

```bash
cd scoring-service && mvn -q package
```

One trace across both services (replace `<TRACE_ID>` with a `traceId` from an ERROR line):

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={service=~"credit-service|scoring-service"} | traceId="<TRACE_ID>"' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" | jq -r '.data.result[].values[][1] | fromjson | "\(.["@timestamp"]) \(.service) \(.level) \(.message) \(.httpStatus // "") \(.exceptionClass // "")"' | sort
```

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={service="credit-service", level="ERROR"}' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" --data-urlencode 'limit=20' | jq '.data.result[].values[][1] | fromjson | {message, traceId, exceptionClass}'
```

```bash
curl -s -u admin:admin localhost:3000/api/datasources/uid/loki/health
```

## Log contract and other stacks

The triage depends on the **shape** of the log lines, not on the language the services are written in: one JSON
object per line, exactly one `request completed` line per request (`endpoint`, `httpStatus`, `durationMs`), a W3C
`traceId`, an upper-case `level`, and `exceptionClass`/`exceptionMessage`/`stackTrace` on error lines. That shape is
defined field by field in [`docs/LOG_CONTRACT.md`](docs/LOG_CONTRACT.md), including what must never become a Loki
label, with a production table for Java (logback/logstash), .NET (Serilog) and Node (pino).

As proof, [`samples/dotnet-echo-service/`](samples/dotnet-echo-service/README.md) (ASP.NET Core minimal API +
Serilog `ExpressionTemplate`) implements the contract; `alloy/config.alloy` and the triage templates read its logs
unchanged. It is not part of the default stack and starts under the `samples` profile:

```bash
docker compose --profile samples up -d --build dotnet-echo-service
```

```bash
curl -s -X POST localhost:8090/api/v1/echo -H 'content-type: application/json' -d '{"message":"hi"}'
```

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query=quantile_over_time(0.95, {service="dotnet-echo-service"} |= "request completed" | json | unwrap durationMs [1m]) by (endpoint)' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" | jq '.data.result[] | {endpoint: .metric.endpoint, p95: .values[-1][1]}'
```

```bash
docker compose --profile samples stop dotnet-echo-service
```

To port it to your own .NET (ABP) service, `ContractLogging.cs` + `RequestLogMiddleware.cs` from the sample are
enough; the steps are in the sample's README.

## Corporate environment notes

Piloting this in a bank-like environment changes four things: you do not own the log pipeline (label and field names
differ), customer identifiers must never reach the LLM, Docker Desktop may be forbidden, and the AI must be strictly
read-only. The four pieces below are implemented and verified in this lab; apply the same patterns on the corporate
pipeline.

### 1. PII masking — before Loki

The `loki.process "json"` block in [`alloy/config.alloy`](alloy/config.alloy) runs a `stage.replace` **before**
`stage.json`: `"customerId":"C773001"` → `"customerId":"C7***"` (first two characters + `***`). Masking happens on the
raw line, so the value stored in Loki and handed to the AI through MCP is masked; the raw value exists only on the
container's stdout. `traceId` is untouched, so cross-service correlation still works. Verify after
`docker compose restart alloy`:

```bash
curl -s -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={service=~"credit-service|scoring-service"} | json | customerId != ""' --data-urlencode 'start='"$(( $(date +%s) - 600 ))000000000" --data-urlencode 'limit=5' | jq -r '.data.result[].values[][1] | fromjson | "\(.service) traceId=\(.traceId) customerId=\(.customerId)"'
```

Expected: `credit-service traceId=6aed… customerId=C7***` and, with the same `traceId`, `scoring-service … customerId=C7***`.

On the corporate pipeline: if the platform team owns Alloy/Promtail, ask for a `stage.replace` (Fluent Bit
`modify`/Lua, Logstash `mutate gsub`) for every identity-bearing field (customer number, national id, IBAN, phone) and
have the mask applied **in the collector, before Loki**. Not putting identities into the MDC at all is the cleanest
fix. The "Data protection" section of the instruction file tells the AI never to write even a masked value into the
report and to reference lines by `traceId` only.

### 2. Read-only, Loki-only MCP

[`scripts/grafana-mcp.sh`](scripts/grafana-mcp.sh) starts the server with `--enabled-tools datasource,loki --disable-write`
(flags verified with `docker run --rm mcp/grafana --help`; `--enabled-tools` is an allowlist, so the other 20
categories — dashboard, alerting, incident, oncall, admin, api, search, prometheus, sift, annotations, rendering,
snapshot, ... — are off). The tool count drops from 65 to 9: `list_datasources`, `get_datasource`,
`check_datasources_health`, `list_loki_label_names`, `list_loki_label_values`, `query_loki_logs`, `query_loki_stats`,
`query_loki_patterns`, `analyze_loki_labels`. Verify over stdio (JSON-RPC `tools/list`):

```bash
scripts/mcp-tools-list.sh lab
```

The token is the second line of defence: the service account stays **Viewer** and is restricted to a single
datasource. On Grafana Enterprise/Cloud use datasource permissions to grant `Query` on the Loki datasource only; Grafana
OSS has no datasource permissions, so create a separate org that contains only the Loki datasource and create the SA
there (`GRAFANA_ORG_ID=<id> scripts/create-grafana-sa-token.sh`). Steps and API calls are in the comment block at the
end of [`scripts/create-grafana-sa-token.sh`](scripts/create-grafana-sa-token.sh).

### 3. Field mapping and window detection

[`triage/LOADTEST_TRIAGE.md`](triage/LOADTEST_TRIAGE.md) opens with a **"Field mapping"** table: for every label/field
used by the templates (`service`, `level`, `traceId`, `endpoint`, `httpStatus`, `durationMs`, `exceptionClass`,
`exceptionMessage`, the `request completed` marker) the lab default and a "corporate value" column to fill in; the AI
reads the templates through that mapping. When the load-test time is unknown, step **0b** finds the busy window from the
last N hours of 5-minute volume (`sum(count_over_time({service="..."} [5m]))`) and asks the user to confirm it. Step
**0c** gives the query discipline for corporate Loki limits: selective `| json a, b`, small `limit`, no range wider
than the window.

### 4. Docker-free mode, proxy and corporate CA

Docker plays two separate roles here and they must not be confused: (1) `docker-compose.yml` is a **local stand-in** for
the corporate UAT + Loki + Grafana, and none of it moves to the company; (2) `scripts/grafana-mcp.sh` starts the MCP
server on the developer machine, and that is the only developer-side piece that can touch Docker. Because a corporate
workstation is not assumed to have Docker, the script's **default mode is the native binary**:

| Environment | Binary found (`MCP_GRAFANA_BIN` / PATH) | No binary |
|---|---|---|
| `lab` | binary | `docker run mcp/grafana` (with a warning; the lab stack is compose anyway) |
| `uat` and others | binary | **error + install instructions**; never falls back to Docker |

`MCP_GRAFANA_MODE=docker` forces Docker in any environment (a deliberate choice, not the default). In binary mode
`GRAFANA_URL` defaults to `http://localhost:3000`; a `host.docker.internal` value in `.env.mcp.lab` is rewritten to
localhost. Proxy (`HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`) and corporate CA (`SSL_CERT_FILE`) pass through in both
modes; in docker mode the CA bundle is bind-mounted read-only into the container (corporate TLS inspection).
`MCP_GRAFANA_EXTRA_ARGS` appends extra flags. Errors are explicit:

```bash
MCP_GRAFANA_BIN=/bin/false scripts/grafana-mcp.sh
```

→ `grafana-mcp.sh: MCP_GRAFANA_BIN='/bin/false' is not an executable file` (on macOS `/bin/false` does not exist; on
Linux the same command yields `'/bin/false --help' failed - this does not look like an mcp-grafana binary`), exit code 1.
`scripts/grafana-mcp.sh uat` without a binary says `environment 'uat' needs an mcp-grafana binary and none was found`
and prints install instructions; it does not run Docker even when Docker is installed. Install:
`go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest` or a GitHub release binary, then
`MCP_GRAFANA_BIN=/path/to/mcp-grafana` in `.env.mcp.<env>`. Client configs do not change.

### Known gap: multi-line stack traces

The lab services write the stack trace as a **single line** inside the JSON `stackTrace` field, so Alloy has no
`stage.multiline`. Corporate applications that print plain text with multi-line stack traces produce one log record per
line, `| json` fails and exception clustering breaks. The fix is in the collector, before `stage.json`:
`stage.multiline { firstline = "^\\d{4}-\\d{2}-\\d{2}" max_wait_time = "3s" }` (first-line pattern per log format), or a
JSON encoder in the application. **Not tested** in this lab.

## Layout

```
credit-service/        Entry-point Spring Boot service; calls scoring-service over HTTP (+ Dockerfile)
scoring-service/       Downstream scoring service; the pool-exhaustion failure mode lives here (+ Dockerfile)
docker-compose.yml     loki, alloy, grafana, scoring-service, credit-service, k6 (profile: loadtest), dotnet-echo-service (profile: samples)
loki/loki.yaml         single-binary Loki 3.x
alloy/config.alloy     docker log collection → Loki (PII masking, k6 containers dropped)
grafana/               datasource + dashboard provisioning
k6/                    load scenario
triage/                LOADTEST_TRIAGE.md (single source of the triage), environments/<env>.md (first line: type=ide|script), templates/, reports/
docs/LOG_CONTRACT.md   stack-independent log contract (the fields the triage expects)
docs/loadtest-ai-triage-sunum.pptx  management deck (Turkish)
samples/dotnet-echo-service/  ASP.NET Core + Serilog sample implementing the contract (profile: samples)
scripts/               triage.sh (sole entry for locked environments), grafana-mcp.sh (MCP wrapper: binary, lock, token command),
                       mcp-audit-proxy.py (tool-call audit trail), triage-window.py, gen-prompts.sh, create-grafana-sa-token.sh, mcp-tools-list.sh
.mcp.json .vscode/ .cursor/ .claude/ .github/   thin client configs
```
