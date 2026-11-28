#!/bin/bash
set -euo pipefail
# kubectl in this image does not pick up the projected service-account
# credentials on its own and falls back to localhost:8080 (same trap
# node-maintenance-gate documents); write an explicit in-cluster kubeconfig.
SA=/var/run/secrets/kubernetes.io/serviceaccount
umask 077
cat >/tmp/kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS:-443}
      certificate-authority: ${SA}/ca.crt
contexts:
  - name: in-cluster
    context: {cluster: in-cluster, namespace: longhorn-system, user: reaper}
current-context: in-cluster
users:
  - name: reaper
    user: {tokenFile: ${SA}/token}
EOF
K=(kubectl --kubeconfig=/tmp/kubeconfig --cache-dir=/tmp/kubectl-cache -n longhorn-system --request-timeout=30s)
MAX_RETRIES="${MAX_RETRIES:-5}"
# Deletions per run. Freeing every stuck slot at once unleashes the whole
# rebuild backlog in one burst, and that I/O stalled etcd on the SATA masters
# (2026-11-08, -15). At one run per 15m this still clears a dozen in an hour.
MAX_PER_RUN="${MAX_PER_RUN:-3}"

notify() {
  # Notification is best-effort: a failed post must not stop the reaper, but
  # it is logged so it shows up in the job's output.
  curl -fsS -m 10 -X POST "${NTFY_URL}" \
    -H "Authorization: Bearer ${NTFY_TOKEN}" \
    -H "Title: Longhorn replica reaped" \
    -H "Tags: broom" \
    -H "Priority: 3" \
    -d "$1" >/dev/null 2>&1 || echo "WARN notify failed: $1" >&2
}

replicas="$("${K[@]}" get replicas.longhorn.io -o json)"
volumes="$("${K[@]}" get volumes.longhorn.io -o json)"
engines="$("${K[@]}" get engines.longhorn.io -o json)"
# Every replica an engine is actually using (any mode). A replica in here is
# live data regardless of what its own spec says; never a candidate.
inengine="$(jq -c '[.items[].status.replicaModeMap // {} | keys[]]' <<<"${engines}")"

# Candidates: exhausted, never healthy, and unknown to every engine. A replica
# that WAS healthy once and then failed is Longhorn's normal failed-replica
# path; leave it alone.
#
# Running candidates first, and outside the cap: a running never-healthy
# replica holds its node's only rebuild slot. On 2026-11-23 ~80 stopped
# candidates (no slot held) filled every run's cap in list order, the five
# slot-holders were never reached, and all rebuilds stayed blocked for ~3h.
# Freeing a slot starts at most one rebuild per node (the per-node limit), so
# this cannot cause the burst the cap exists for.
mapfile -t candidates < <(jq -r --argjson max "${MAX_RETRIES}" --argjson inengine "${inengine}" '
  [.items[]
  | select((.spec.rebuildRetryCount // 0) >= $max)
  | select((.spec.healthyAt // "") == "")
  | select(.metadata.name as $n | $inengine | index($n) | not)]
  | sort_by(.status.currentState != "running")[]
  | "\(.metadata.name) \(.spec.volumeName) \(.spec.nodeID) \(.status.currentState)"' <<<"${replicas}")

if (( ${#candidates[@]} == 0 )); then
  echo "nothing to reap"
  exit 0
fi

reaped=0
reaped_stopped=0
for line in "${candidates[@]}"; do
  read -r name volume node state <<<"${line}"
  healthy="$(jq -r --arg v "${volume}" '
    [.items[] | select(.spec.volumeName == $v and .status.currentState == "running" and (.spec.healthyAt // "") != "")] | length' <<<"${replicas}")"
  wanted="$(jq -r --arg v "${volume}" '.items[] | select(.metadata.name == $v) | .spec.numberOfReplicas // 0' <<<"${volumes}")"
  if (( healthy < 1 )); then
    echo "SKIP ${name}: volume ${volume} has no healthy running replica; needs a human" >&2
    notify "SKIPPED ${name} on ${node}: volume ${volume} has NO healthy replica left. Manual attention needed."
    continue
  fi
  if [[ "${state}" != "running" ]] && (( reaped_stopped >= MAX_PER_RUN )); then
    echo "cap: ${MAX_PER_RUN} stopped replicas deleted this run; ${name} and the rest wait for the next"
    break
  fi
  if "${K[@]}" delete replicas.longhorn.io "${name}" --wait=false >/dev/null; then
    echo "reaped ${name} volume=${volume} node=${node} state=${state} healthy=${healthy}/${wanted}"
    notify "Deleted ${name} (${state}, ${MAX_RETRIES}/${MAX_RETRIES} rebuild retries) on ${node}. Volume ${volume} keeps ${healthy}/${wanted} healthy replicas; Longhorn will schedule a replacement."
    reaped=$(( reaped + 1 ))
    [[ "${state}" == "running" ]] || reaped_stopped=$(( reaped_stopped + 1 ))
  else
    echo "ERROR delete failed for ${name}" >&2
  fi
done
echo "reaped ${reaped} of ${#candidates[@]} candidates"
