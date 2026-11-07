#!/usr/bin/env bash
# lq.sh — run a LogQL query against the cluster's Loki with the correct defaults.
#
# Handles the port-forward, the X-Scope-OrgID header, and the step/range invariant
# that silently double-counts if you get it wrong (see SKILL.md, Trap 1).
#
#   lq.sh [--hours N] [--step SEC] [--raw] [--limit N] [--json] '<logql>'
#
#   --hours N   window, ending now (default 24)
#   --step SEC  range-query step (default 3600 — do not change without reason)
#   --raw       log query instead of metric query; prints newest-first lines
#   --limit N   max lines for --raw (default 50)
#   --json      emit the raw Loki JSON response instead of a table
set -euo pipefail

HOURS=24; STEP=3600; RAW=0; LIMIT=50; JSON=0; QUERY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --step)  STEP="$2";  shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --raw)   RAW=1; shift ;;
    --json)  JSON=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) QUERY="$1"; shift ;;
  esac
done
[[ -n "$QUERY" ]] || { echo "error: no query given" >&2; exit 2; }

# Trap 1 guard: Loki splits on 1h, so any other range selector double-counts.
if [[ $RAW -eq 0 ]]; then
  if grep -qE '\[[0-9]+[smhd]\]' <<<"$QUERY" && ! grep -qE '\[1h\]' <<<"$QUERY"; then
    echo "WARNING: range selector is not [1h]. Loki splits queries on a 1h interval," >&2
    echo "         so any other range double-counts across splits. Use [1h] + --step 3600." >&2
  fi
  [[ "$STEP" == "3600" ]] || echo "WARNING: step=$STEP (expected 3600 to match a [1h] range)." >&2
fi

PORT="${LOKI_PORT:-3100}"
if ! curl -sf -o /dev/null "localhost:${PORT}/ready" 2>/dev/null; then
  kubectl -n monitoring port-forward svc/loki-gateway "${PORT}:80" >/dev/null 2>&1 &
  PF=$!
  trap 'kill $PF 2>/dev/null || true' EXIT
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null "localhost:${PORT}/ready" 2>/dev/null && break
    sleep 0.25
  done
fi

END=$(date -u +%s); START=$((END - HOURS * 3600))

if [[ $RAW -eq 1 ]]; then
  RESP=$(curl -sS --fail-with-body -H "X-Scope-OrgID: fake" --get "localhost:${PORT}/loki/api/v1/query_range" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${START}000000000" --data-urlencode "end=${END}000000000" \
    --data-urlencode "limit=${LIMIT}" --data-urlencode "direction=backward")
else
  RESP=$(curl -sS --fail-with-body -H "X-Scope-OrgID: fake" --get "localhost:${PORT}/loki/api/v1/query_range" \
    --data-urlencode "query=${QUERY}" \
    --data-urlencode "start=${START}000000000" --data-urlencode "end=${END}000000000" \
    --data-urlencode "step=${STEP}") || {
    echo "Loki rejected the query (often the 500-series cap — see SKILL.md Trap 2):" >&2
    echo "$RESP" >&2; exit 1; }
fi

if [[ $JSON -eq 1 ]]; then echo "$RESP"; exit 0; fi

RAW=$RAW HOURS=$HOURS python3 -c '
import sys, os, json, datetime
d = json.load(sys.stdin)
if d.get("status") != "success":
    print("query failed:", json.dumps(d)[:800]); sys.exit(1)
data = d.get("data", {})
res  = data.get("result", [])
if not res:
    print("no data in the last %s h" % os.environ["HOURS"]); sys.exit(0)

if os.environ["RAW"] == "1":
    rows = []
    for s in res:
        for ts, line in s["values"]:
            rows.append((int(ts), line))
    rows.sort(reverse=True)
    for ts, line in rows:
        t = datetime.datetime.fromtimestamp(ts/1e9, datetime.timezone.utc)
        print(t.strftime("%Y-%m-%dT%H:%M:%SZ"), line)
    print("\n%d lines" % len(rows), file=sys.stderr)
    sys.exit(0)

# Metric query: total per series, sorted desc. Buckets are labelled at END time.
tot = []
for s in res:
    labels = s["metric"]
    n = sum(float(v) for _, v in s["values"])
    key = ", ".join("%s=%s" % (k, labels[k]) for k in sorted(labels)) or "(no labels)"
    tot.append((n, key))
tot.sort(reverse=True)
grand = sum(n for n, _ in tot)
w = max((len(k) for _, k in tot), default=10)
for n, k in tot:
    pct = (100.0 * n / grand) if grand else 0.0
    print("%-*s  %12s  %5.1f%%" % (w, k, format(int(n), ","), pct))
print("%-*s  %12s" % (w, "TOTAL", format(int(grand), ",")))
if any(len(s["values"]) > 1 for s in res):
    print("(series summed across buckets; buckets are labelled at their END time)", file=sys.stderr)
' <<<"$RESP"
