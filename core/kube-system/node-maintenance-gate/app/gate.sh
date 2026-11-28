#!/usr/bin/env bash
# Longhorn-aware node maintenance gate (#1508).
#
# One pod per node (DaemonSet). kured consumes it through
# `--blocking-pod-selector=node-maintenance-gate=blocked`; kured's pod query is
# scoped to `spec.nodeName=<its own node>`, so a gate pod only ever blocks the
# node it runs on. The pod template ships the label as `blocked`, and this
# script flips its *own* pod's label to `open` only after a full pass proves the
# cluster safe. Anything else - API error, timeout, unparseable JSON, a state
# string Longhorn does not document - leaves it `blocked`.
#
# Two things this gate deliberately does NOT do:
#   - it does not touch Longhorn's nodeDrainPolicy, the instance-manager PDB, or
#     kured's forceReboot. Those are the evacuation; this is only the interlock
#     that stops the *next* node starting before the previous one recovered.
#   - it never cordons, drains or deletes anything. Its writes are one label on
#     its own pod, one Lease in its own namespace, the Longhorn eviction request
#     for the node holding the Lease, and removal of a stale kured reboot flag
#     from its own node.
#
# State lives in the Lease, not in this process, so it survives the reboot of
# the node the gate is running on:
#
#   spec.holderIdentity                      node currently allowed a cycle
#   metadata.annotations[.../phase]          armed | opened | draining | recovering
#   metadata.annotations[.../boot-id]        node boot ID observed at claim time
#   metadata.annotations[.../healthy-since]  epoch when recovery first held
#
# Rollback: delete this Kustomization and remove `blockingPodSelector` from the
# kured HelmRelease. Nothing else has to be undone - the gate owns no cluster
# state beyond its own pod labels and the Lease, and the Lease is inert once the
# selector is gone. Leaving the selector while removing the DaemonSet is also
# safe: kured finds no matching pod and stops blocking. Removing the DaemonSet
# while keeping the selector is the fail-open direction, so do them in that
# order only deliberately.

set -uo pipefail

NODE_NAME="${NODE_NAME:?NODE_NAME is required}"
POD_NAME="${POD_NAME:?POD_NAME is required}"
POD_NAMESPACE="${POD_NAMESPACE:?POD_NAMESPACE is required}"

GATE_LABEL="${GATE_LABEL:-node-maintenance-gate}"
LEASE_NAME="${LEASE_NAME:-node-maintenance-gate}"
LEASE_NAMESPACE="${LEASE_NAMESPACE:-kube-system}"
LOCAL_PATH_STORAGE_CLASS="${LOCAL_PATH_STORAGE_CLASS:-local-path}"

INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
LEASE_DURATION_SECONDS="${LEASE_DURATION_SECONDS:-1800}"
SETTLE_SECONDS="${SETTLE_SECONDS:-600}"
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-7200}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-600}"
# kured's reboot window. A claim requests Longhorn eviction immediately, so a
# claim kured cannot act on (outside its window) only drains the node for
# CYCLE_TIMEOUT_SECONDS and then gives up. Local time via a POSIX TZ string: the
# image has no tzdata, and busybox date honours TZ=CST6CDT,M3.2.0,M11.1.0 on
# its own. WINDOW_CLAIM_MARGIN_SECONDS keeps a claim from landing so late in the
# window that kured cannot act once the gate opens. The gate now stays blocked
# until the node is evacuated (svartalfheim's ~54 replicas took ~60m on
# 2026-11-24), so the margin covers that plus kured's 15m tick and drain.
MAINTENANCE_WINDOW_START="${MAINTENANCE_WINDOW_START:-02:00}"
MAINTENANCE_WINDOW_END="${MAINTENANCE_WINDOW_END:-05:00}"
WINDOW_CLAIM_MARGIN_SECONDS="${WINDOW_CLAIM_MARGIN_SECONDS:-5400}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-20s}"
# Touched at the end of every pass. The liveness probe reads it, so a wedged loop
# is restarted rather than left holding whatever label it last wrote - the one
# way a gate could otherwise sit `open` over an unguarded node indefinitely.
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/tmp/heartbeat}"

# kured sets this on a node it intends to reboot (requires annotateNodes: true)
# and deletes it once the reboot has demonstrably happened. It is the signal that
# says which node actually wants the lease, so the gate never burns a slot on a
# node with nothing to do.
KURED_REBOOT_ANNOTATION="${KURED_REBOOT_ANNOTATION:-weave.works/kured-reboot-in-progress}"
# kured only removes that annotation after a reboot *it* performed. A node
# rebooted any other way keeps it forever, and the gate then claimed that node
# every night: 2026-11-19..24 svartalfheim (flag from 11-14, rebooted by hand
# 11-17) was evicted for 2h each window, kured never rebooted it (no sentinel),
# and its ~54 replicas piled onto niflheim. A flag older than this boot is
# therefore ignored. /proc/stat btime is kernel-wide, so it is the host's boot.
STALE_FLAG_WARNED=""

ANN_PREFIX="node-maintenance-gate.wynning.tech"
ANN_PHASE="${ANN_PREFIX}/phase"
ANN_BOOT_ID="${ANN_PREFIX}/boot-id"
ANN_HEALTHY_SINCE="${ANN_PREFIX}/healthy-since"

# kubectl does not automatically use the pod's projected service-account
# credentials. Build an explicit in-cluster kubeconfig so it cannot fall back
# to localhost:8080, which would leave every gate permanently blocked.
SERVICE_ACCOUNT_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
KUBECONFIG_FILE="/tmp/kubeconfig"
KUBERNETES_SERVICE_PORT_HTTPS="${KUBERNETES_SERVICE_PORT_HTTPS:-443}"

: "${KUBERNETES_SERVICE_HOST:?KUBERNETES_SERVICE_HOST is required}"
: "${KUBERNETES_SERVICE_PORT_HTTPS:?KUBERNETES_SERVICE_PORT_HTTPS is required}"

umask 077
cat >"${KUBECONFIG_FILE}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: in-cluster
    cluster:
      server: https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}
      certificate-authority: ${SERVICE_ACCOUNT_DIR}/ca.crt
contexts:
  - name: in-cluster
    context:
      cluster: in-cluster
      namespace: ${POD_NAMESPACE}
      user: gate
current-context: in-cluster
users:
  - name: gate
    user:
      tokenFile: ${SERVICE_ACCOUNT_DIR}/token
EOF

KUBECTL=(kubectl --kubeconfig="${KUBECONFIG_FILE}" --request-timeout="${REQUEST_TIMEOUT}" --cache-dir=/tmp/kubectl-cache)

# Last label we successfully wrote. Empty means "unknown, reconcile it".
GATE_STATE=""
# Epoch before which this gate will not claim the Lease again, so a node that
# times out of a cycle does not immediately re-take the slot from its peers.
COOLDOWN_UNTIL=0
# 1 while pass() is inside holder_pass, i.e. this node owns the current cycle.
# Read by longhorn_nodes_ok to decide whether this node's own Longhorn state
# is the gate's doing (exempt) or an operator's (block).
HOLDING=0

# stderr, always: several functions return their result on stdout and a log line
# leaking into that would be read as a verdict.
log() {
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${*:2}" >&2
}

now() { date -u +%s; }
iso_now() { date -u +%Y-%m-%dT%H:%M:%S.000000Z; }

# Kubernetes hands back RFC3339 with optional fractional seconds; busybox date
# parses neither, so jq does it. A value we cannot parse is an error, and every
# caller treats an error as "unsafe".
iso_epoch() {
    jq -rn --arg t "$1" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null
}

# Local wall clock (TZ from the environment) against the kured window, with the
# claim margin taken off the end. HH:MM compared as minutes since midnight; a
# window that wraps midnight is not supported because kured's isn't either.
# Unparseable config is treated as "outside": fail closed, same as every check.
# HH:MM -> minutes since midnight, or failure for anything outside 00:00-23:59.
hm_to_minutes() {
    [[ "$1" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
    local h=$(( 10#${BASH_REMATCH[1]} )) m=$(( 10#${BASH_REMATCH[2]} ))
    (( h <= 23 && m <= 59 )) || return 1
    echo $(( h * 60 + m ))
}

in_maintenance_window() {
    local now_m start_m end_m
    now_m="$(hm_to_minutes "$(date +%H:%M)")" || return 1
    start_m="$(hm_to_minutes "${MAINTENANCE_WINDOW_START}")" || { log ERROR "bad MAINTENANCE_WINDOW_START ${MAINTENANCE_WINDOW_START}"; return 1; }
    end_m="$(hm_to_minutes "${MAINTENANCE_WINDOW_END}")" || { log ERROR "bad MAINTENANCE_WINDOW_END ${MAINTENANCE_WINDOW_END}"; return 1; }
    [[ "${WINDOW_CLAIM_MARGIN_SECONDS}" =~ ^[0-9]+$ ]] || { log ERROR "bad WINDOW_CLAIM_MARGIN_SECONDS ${WINDOW_CLAIM_MARGIN_SECONDS}"; return 1; }
    end_m=$(( end_m - WINDOW_CLAIM_MARGIN_SECONDS / 60 ))
    (( now_m >= start_m && now_m < end_m ))
}

# Idempotent: only patches when the label is not already what we want, and
# forgets the cached value on failure so the next pass retries.
set_gate() {
    local want="$1"
    [[ "${GATE_STATE}" == "${want}" ]] && return 0
    if "${KUBECTL[@]}" -n "${POD_NAMESPACE}" patch pod "${POD_NAME}" --type=merge \
        -p "{\"metadata\":{\"labels\":{\"${GATE_LABEL}\":\"${want}\"}}}" >/dev/null 2>&1; then
        log INFO "gate ${GATE_STATE:-unknown} -> ${want}"
        GATE_STATE="${want}"
        return 0
    fi
    log ERROR "failed to set gate label to ${want}; treating gate state as unknown"
    GATE_STATE=""
    return 1
}

# ---------------------------------------------------------------------------
# Lease
# ---------------------------------------------------------------------------

lease_get() {
    local json
    if json="$("${KUBECTL[@]}" -n "${LEASE_NAMESPACE}" get lease "${LEASE_NAME}" -o json 2>/dev/null)"; then
        printf '%s' "${json}"
        return 0
    fi
    # Not managed by Flux on purpose: Flux drift-correction would reset
    # holderIdentity on every reconcile and hand the slot to another node
    # mid-cycle. The gate creates it once and owns it from then on.
    "${KUBECTL[@]}" create -f - >/dev/null 2>&1 <<EOF
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: ${LEASE_NAME}
  namespace: ${LEASE_NAMESPACE}
  labels:
    app.kubernetes.io/name: node-maintenance-gate
spec:
  leaseDurationSeconds: ${LEASE_DURATION_SECONDS}
EOF
    "${KUBECTL[@]}" -n "${LEASE_NAMESPACE}" get lease "${LEASE_NAME}" -o json 2>/dev/null
}

# Writes back the object we read, resourceVersion and all, so a concurrent claim
# from another node's gate loses with a 409 instead of silently winning.
lease_replace() {
    [[ -n "$1" ]] || return 1
    "${KUBECTL[@]}" replace -f - >/dev/null 2>&1 <<<"$1"
}

lease_field() { jq -r "$2 // \"\"" <<<"$1" 2>/dev/null; }

# Held means: a holder is recorded and the lease has not expired. An unparseable
# or missing renewTime counts as held - if we cannot tell, nobody else goes.
lease_is_held() {
    local lease="$1" holder renew dur expiry
    holder="$(lease_field "${lease}" '.spec.holderIdentity')"
    [[ -z "${holder}" ]] && return 1
    renew="$(lease_field "${lease}" '.spec.renewTime')"
    [[ -z "${renew}" ]] && return 0
    dur="$(jq -r '.spec.leaseDurationSeconds // 0' <<<"${lease}" 2>/dev/null)"
    [[ "${dur}" =~ ^[0-9]+$ ]] || return 0
    expiry="$(iso_epoch "${renew}")" || return 0
    [[ "${expiry}" =~ ^[0-9]+$ ]] || return 0
    (( $(now) < expiry + dur ))
}

lease_claim() {
    local lease="$1" boot_id="$2" next ts
    ts="$(iso_now)"
    next="$(jq \
        --arg node "${NODE_NAME}" --arg ts "${ts}" --arg boot "${boot_id}" \
        --argjson dur "${LEASE_DURATION_SECONDS}" \
        --arg kphase "${ANN_PHASE}" --arg kboot "${ANN_BOOT_ID}" --arg khealthy "${ANN_HEALTHY_SINCE}" '
        .metadata.annotations = ((.metadata.annotations // {}) + {($kphase): "armed", ($kboot): $boot})
        | .metadata.annotations |= del(.[$khealthy])
        | .spec.holderIdentity = $node
        | .spec.leaseDurationSeconds = $dur
        | .spec.acquireTime = $ts
        | .spec.renewTime = $ts
        | .spec.leaseTransitions = ((.spec.leaseTransitions // 0) + 1)
        ' <<<"${lease}" 2>/dev/null)" || return 1
    lease_replace "${next}"
}

lease_renew() {
    local lease="$1" phase="$2" healthy_since="$3" next
    next="$(jq \
        --arg ts "$(iso_now)" --arg phase "${phase}" --arg healthy "${healthy_since}" \
        --arg kphase "${ANN_PHASE}" --arg khealthy "${ANN_HEALTHY_SINCE}" '
        .metadata.annotations = ((.metadata.annotations // {}) + {($kphase): $phase})
        | (if $healthy == "" then .metadata.annotations |= del(.[$khealthy])
           else .metadata.annotations[$khealthy] = $healthy end)
        | .spec.renewTime = $ts
        ' <<<"${lease}" 2>/dev/null)" || return 1
    lease_replace "${next}"
}

lease_release() {
    local lease="$1" next
    next="$(jq \
        --arg kphase "${ANN_PHASE}" --arg kboot "${ANN_BOOT_ID}" --arg khealthy "${ANN_HEALTHY_SINCE}" '
        .metadata.annotations |= (del(.[$kphase]) | del(.[$kboot]) | del(.[$khealthy]))
        | del(.spec.holderIdentity)
        | del(.spec.acquireTime)
        | del(.spec.renewTime)
        ' <<<"${lease}" 2>/dev/null)" || return 1
    lease_replace "${next}"
}

# ---------------------------------------------------------------------------
# Safety checks. Each prints one line per reason the cluster is not safe and
# returns non-zero; silence and exit 0 is the only thing that opens the gate.
# ---------------------------------------------------------------------------

kube_nodes_ok() {
    local json out
    json="$("${KUBECTL[@]}" get nodes -o json 2>/dev/null)" || {
        echo "kubernetes: node list failed"
        return 1
    }
    out="$(jq -r '
        if (.items | length) == 0 then "kubernetes: node list is empty"
        else
          .items[]
          | .metadata.name as $name
          | ([.status.conditions[]? | select(.type == "Ready") | .status] | first) as $ready
          | (
              if $ready == null then "kubernetes: node \($name) has no Ready condition"
              elif $ready != "True" then "kubernetes: node \($name) is Ready=\($ready)"
              else empty end
            ),
            (if (.spec.unschedulable // false) then "kubernetes: node \($name) is cordoned" else empty end)
        end' <<<"${json}" 2>/dev/null)" || {
        echo "kubernetes: node list unparseable"
        return 1
    }
    [[ -z "${out}" ]] || { echo "${out}"; return 1; }
    return 0
}

# allowScheduling and evictionRequested are spec fields on nodes.longhorn.io -
# verified against longhorn-manager v1.11.2 (NodeSpec.AllowScheduling /
# NodeSpec.EvictionRequested). Neither is exported as a metric, which is why this
# reads the API rather than Prometheus.
#
# Note the asymmetry with replicas: Longhorn's node controller sets *replica*
# .spec.evictionRequested automatically on any cordoned node under
# nodeDrainPolicy=block-for-eviction-if-contains-last-replica, so blocking on
# that would deadlock the very drain this gate exists to protect. Node-level
# evictionRequested is only ever set by an operator, so it is safe to block on.
# The self exemptions apply only while this node owns a maintenance cycle
# (HOLDING=1, set by holder_pass): the gate itself put allowScheduling=false and
# evictionRequested=true there. Before claiming, the same fields on this node
# are an operator's doing and block like on any other node — otherwise a claim
# would start a cycle on a node someone has deliberately cordoned in Longhorn,
# and longhorn_clear_eviction would later undo that cordon.
longhorn_nodes_ok() {
    local json out self=""
    (( HOLDING )) && self="${NODE_NAME}"
    json="$("${KUBECTL[@]}" get nodes.longhorn.io -A -o json 2>/dev/null)" || {
        echo "longhorn: node list failed"
        return 1
    }
    out="$(jq -r --arg self "${self}" '
        if (.items | length) == 0 then "longhorn: node list is empty"
        else
          .items[]
          | .metadata.name as $name
          | ([.status.conditions[]? | select(.type == "Ready") | .status] | first) as $ready
          | (
              if (.spec.allowScheduling | type) != "boolean" then "longhorn: node \($name) has no allowScheduling"
              elif .spec.allowScheduling != true and $name != $self then "longhorn: node \($name) has allowScheduling=false"
              else empty end
            ),
            (
              if (.spec.evictionRequested | type) != "boolean" then "longhorn: node \($name) has no evictionRequested"
              elif .spec.evictionRequested != false and $name != $self then "longhorn: node \($name) has evictionRequested=true"
              else empty end
            ),
            (
              if $ready == null then "longhorn: node \($name) has no Ready condition"
              elif $ready != "True" then "longhorn: node \($name) is Ready=\($ready)"
              else empty end
            )
        end' <<<"${json}" 2>/dev/null)" || {
        echo "longhorn: node list unparseable"
        return 1
    }
    [[ -z "${out}" ]] || { echo "${out}"; return 1; }
    return 0
}

# Longhorn requires scheduling to be disabled before evictionRequested can be
# set. Keep both fields in the same patch so the admission webhook sees a valid
# transition and no replica movement starts before the node is unschedulable.
longhorn_request_eviction() {
    if "${KUBECTL[@]}" -n longhorn-system patch nodes.longhorn.io "${NODE_NAME}" \
        --type=merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null 2>&1; then
        log INFO "requested Longhorn eviction for ${NODE_NAME}"
        return 0
    fi
    log ERROR "could not request Longhorn eviction for ${NODE_NAME}"
    return 1
}

longhorn_clear_eviction() {
    if ! "${KUBECTL[@]}" -n longhorn-system patch nodes.longhorn.io "${NODE_NAME}" \
        --type=merge -p '{"spec":{"evictionRequested":false}}' >/dev/null 2>&1; then
        log ERROR "could not clear Longhorn eviction request for ${NODE_NAME}"
        return 1
    fi
    if ! "${KUBECTL[@]}" -n longhorn-system patch nodes.longhorn.io "${NODE_NAME}" \
        --type=merge -p '{"spec":{"allowScheduling":true}}' >/dev/null 2>&1; then
        log ERROR "could not re-enable Longhorn scheduling for ${NODE_NAME}"
        return 1
    fi
    log INFO "cleared Longhorn eviction request and re-enabled scheduling for ${NODE_NAME}"
    return 0
}

# Eviction is requested at claim time; the gate stays blocked (kured cannot
# cordon or reboot) until no attached volume still has a replica here. Opening
# at claim time let kured reboot niflheim 10 minutes into the eviction of 65
# replicas on 2026-11-23: 53 volumes degraded and every rebuild queued behind
# one hung start on the Pi. Detached volumes are not waited on - nothing is
# reading them, and Longhorn rebuilds them on their next attach.
# Prints the remaining count when not evacuated.
longhorn_node_evacuated() {
    local replicas volumes remaining
    replicas="$("${KUBECTL[@]}" -n longhorn-system get replicas.longhorn.io -o json 2>/dev/null)" || { echo "?"; return 1; }
    volumes="$("${KUBECTL[@]}" -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null)" || { echo "?"; return 1; }
    # Both documents on stdin (-s slurps them into [replicas, volumes]), never
    # as --argjson: the replica list is ~1MB and Linux caps one exec argument at
    # 128KiB (MAX_ARG_STRLEN). 2026-11-25 every pass failed with "Argument list
    # too long", the gate never opened and muspelheim's cycle timed out.
    remaining="$(printf '%s\n%s\n' "${replicas}" "${volumes}" | jq -rs --arg node "${NODE_NAME}" '
        .[0] as $r | .[1] as $v
        | ([$v.items[] | select(.status.state == "attached") | .metadata.name]) as $attached
        | [$r.items[] | select(.spec.nodeID == $node and (.spec.volumeName as $n | $attached | index($n)))]
        | length' 2>/dev/null)" || { echo "?"; return 1; }
    [[ "${remaining}" =~ ^[0-9]+$ ]] || { echo "?"; return 1; }
    (( remaining == 0 )) && return 0
    echo "${remaining}"
    return 1
}

# VolumeState and VolumeRobustness enums are from longhorn-manager v1.11.2. A
# value outside either enum means Longhorn is reporting something this gate was
# not written against, so it blocks rather than guesses. A *detached* volume
# reports robustness "unknown" as a matter of course - that is normal and does
# not block; only attached volumes are required to be healthy.
longhorn_volumes_ok() {
    local json out
    json="$("${KUBECTL[@]}" get volumes.longhorn.io -A -o json 2>/dev/null)" || {
        echo "longhorn: volume list failed"
        return 1
    }
    out="$(jq -r '
        ["creating","attached","detached","attaching","detaching","deleting"] as $states
        | ["healthy","degraded","faulted","unknown"] as $robustness
        | .items[]
        | .metadata.name as $name
        | (.status.state // "") as $state
        | (.status.robustness // "") as $rob
        | (if ($states | index($state)) == null then "longhorn: volume \($name) has unrecognised state \"\($state)\"" else empty end),
          (if ($robustness | index($rob)) == null then "longhorn: volume \($name) has unrecognised robustness \"\($rob)\"" else empty end),
          (if $rob == "degraded" or $rob == "faulted" then "longhorn: volume \($name) is \($rob)" else empty end),
          (if $state == "attached" and $rob != "healthy" then "longhorn: volume \($name) is attached but \($rob)" else empty end)
        ' <<<"${json}" 2>/dev/null)" || {
        echo "longhorn: volume list unparseable"
        return 1
    }
    [[ -z "${out}" ]] || { echo "${out}"; return 1; }
    return 0
}

# healthyAt is cleared before a rebuild and set again once the replica is
# read/write in an engine (ReplicaSpec.HealthyAt, v1.11.2). A running replica
# with no healthyAt is therefore a rebuild in flight - the exact condition that
# must not be interrupted by the next node going down.
#
# Only `rebuilding` blocks here. A replica in `error` on an attached volume
# already shows up as a degraded volume above; on a detached volume it is stale
# and blocking on it would jam maintenance indefinitely.
longhorn_replicas_ok() {
    local json out
    json="$("${KUBECTL[@]}" get replicas.longhorn.io -A -o json 2>/dev/null)" || {
        echo "longhorn: replica list failed"
        return 1
    }
    out="$(jq -r '
        ["running","stopped","error","starting","stopping","unknown","terminated"] as $states
        | .items[]
        | .metadata.name as $name
        | (.status.currentState // "") as $state
        | (if ($states | index($state)) == null then "longhorn: replica \($name) has unrecognised state \"\($state)\"" else empty end),
          (if $state == "running" and ((.spec.healthyAt // "") == "")
           then "longhorn: replica \($name) is rebuilding" else empty end)
        ' <<<"${json}" 2>/dev/null)" || {
        echo "longhorn: replica list unparseable"
        return 1
    }
    [[ -z "${out}" ]] || { echo "${out}"; return 1; }
    return 0
}

# A local-path PVC is a directory on one node's disk. Its consumer cannot
# reschedule, so "the pod will come back somewhere else" - true for every
# Longhorn-backed workload - is false here. CNPG, Loki, Tempo, Prometheus,
# Alertmanager, Garage and the Forgejo runner all live on local-path, and a
# maintenance window that starts while one of them is still down is how a single
# reboot turns into a lost quorum.
local_path_consumers_ok() {
    local pvcs claims namespaces ns pods out all_out=""
    pvcs="$("${KUBECTL[@]}" get pvc -A -o json 2>/dev/null)" || {
        echo "local-path: pvc list failed"
        return 1
    }
    claims="$(jq -c --arg sc "${LOCAL_PATH_STORAGE_CLASS}" '
        [.items[] | select((.spec.storageClassName // "") == $sc)
         | {namespace: .metadata.namespace, name: .metadata.name}]' <<<"${pvcs}" 2>/dev/null)" || {
        echo "local-path: pvc list unparseable"
        return 1
    }
    namespaces="$(jq -r '[.[].namespace] | unique | .[]' <<<"${claims}" 2>/dev/null)" || {
        echo "local-path: pvc namespaces unparseable"
        return 1
    }
    [[ -z "${namespaces}" ]] && return 0

    # Per-namespace rather than -A: this runs on every node, and a full
    # cluster-wide pod list once a minute is load the etcd on muspelheim does
    # not need. Only namespaces that actually hold a local-path claim are read.
    while read -r ns; do
        [[ -z "${ns}" ]] && continue
        pods="$("${KUBECTL[@]}" -n "${ns}" get pods -o json 2>/dev/null)" || {
            echo "local-path: pod list failed in namespace ${ns}"
            return 1
        }
        # Succeeded/Failed pods are finished Jobs: they hold no live mount and
        # kured's own phase filter ignores them too.
        out="$(jq -r --argjson claims "${claims}" --arg ns "${ns}" '
            ([$claims[] | select(.namespace == $ns) | .name]) as $names
            | .items[]
            | select([.spec.volumes[]? | .persistentVolumeClaim.claimName? // empty]
                     | any(. as $c | ($names | index($c)) != null))
            | select((.status.phase // "") == "Running" or (.status.phase // "") == "Pending")
            | .metadata.name as $pod
            | ([.status.conditions[]? | select(.type == "Ready") | .status] | first) as $ready
            | if $ready != "True" then "local-path: pod \($ns)/\($pod) mounts a local-path claim and is not Ready" else empty end
            ' <<<"${pods}" 2>/dev/null)" || {
            echo "local-path: pod list unparseable in namespace ${ns}"
            return 1
        }
        [[ -n "${out}" ]] && all_out+="${out}"$'\n'
    done <<<"${namespaces}"

    [[ -z "${all_out}" ]] || { printf '%s' "${all_out}"; return 1; }
    return 0
}

# The one predicate, used both to decide whether a node may start a cycle and to
# decide whether the node that just rebooted has finished recovering. They are
# the same question asked at two moments, so they are the same code.
cluster_safe() {
    local check out reasons="" rc=0
    for check in kube_nodes_ok longhorn_nodes_ok longhorn_volumes_ok longhorn_replicas_ok local_path_consumers_ok; do
        if ! out="$("${check}")"; then
            rc=1
            [[ -n "${out}" ]] && reasons+="${out}"$'\n'
        fi
    done
    if (( rc != 0 )); then
        # Head only: during a real recovery this is every degraded volume in the
        # cluster, and the pod log is not the place for all 105 of them.
        log INFO "not safe ($(grep -c . <<<"${reasons}") reason(s)); first few:"
        while read -r line; do
            [[ -n "${line}" ]] && log INFO "  ${line}"
        done < <(head -5 <<<"${reasons}")
    fi
    return "${rc}"
}

# ---------------------------------------------------------------------------
# Pass
# ---------------------------------------------------------------------------

# Prints "open" or "blocked" on stdout.
holder_pass() {
    local lease="$1" node_json="$2"
    local phase boot_claimed boot_now unschedulable acquire healthy_since acquired_at since

    phase="$(jq -r --arg k "${ANN_PHASE}" '.metadata.annotations[$k] // ""' <<<"${lease}" 2>/dev/null)"
    boot_claimed="$(jq -r --arg k "${ANN_BOOT_ID}" '.metadata.annotations[$k] // ""' <<<"${lease}" 2>/dev/null)"
    healthy_since="$(jq -r --arg k "${ANN_HEALTHY_SINCE}" '.metadata.annotations[$k] // ""' <<<"${lease}" 2>/dev/null)"
    boot_now="$(jq -r '.status.nodeInfo.bootID // ""' <<<"${node_json}" 2>/dev/null)"
    unschedulable="$(jq -r '.spec.unschedulable // false' <<<"${node_json}" 2>/dev/null)"
    acquire="$(jq -r '.spec.acquireTime // ""' <<<"${lease}" 2>/dev/null)"

    if [[ -z "${boot_now}" || -z "${boot_claimed}" || -z "${phase}" ]]; then
        log ERROR "lease is held by this node but its phase/boot-id is unreadable; releasing"
        lease_release "${lease}" || log ERROR "failed to release lease"
        echo blocked
        return 0
    fi

    # A changed boot ID is the only proof the reboot actually happened, and it is
    # still readable after the gate pod itself was restarted by that reboot.
    if [[ "${boot_now}" != "${boot_claimed}" ]]; then
        longhorn_clear_eviction || { echo blocked; return 0; }
        phase="recovering"
    elif [[ "${unschedulable}" == "true" ]] && [[ "${phase}" == "opened" || "${phase}" == "draining" ]]; then
        # Only a cordon after the gate actually opened (phase `opened`: node
        # evacuated and cluster_safe passed) is kured's drain. A cordon before
        # that - by hand, or anything else - must not open the gate over
        # replicas still on this node or an unsafe cluster; it stays armed.
        phase="draining"
    elif [[ "${phase}" == "draining" ]]; then
        # kured aborted the drain and uncordoned. forceReboot=false means no
        # reboot happened, so this is back to waiting rather than recovering.
        phase="armed"
    elif [[ "${phase}" == "opened" ]]; then
        # Open but not cordoned yet: re-check every pass, exactly as armed.
        phase="armed"
    fi

    # Safety valve for armed/opened/draining only. Recovery is deliberately unbounded: a
    # recovery that never finishes must keep every other node still, and
    # KuredRebootPendingTooLong (#1713) is what surfaces that to a human.
    if [[ "${phase}" != "recovering" && -n "${acquire}" ]]; then
        if acquired_at="$(iso_epoch "${acquire}")" && [[ "${acquired_at}" =~ ^[0-9]+$ ]]; then
            if (( $(now) - acquired_at > CYCLE_TIMEOUT_SECONDS )); then
                # The eviction was requested at claim time. Leaving it set after
                # the lease is gone keeps Longhorn draining this node's replicas
                # with no reboot coming, and allowScheduling=false then blocks
                # this node's own next evaluation: 2026-11-13 helheim sat like
                # that for 30h, 16 volumes degraded with their only healthy
                # replica on the node being evicted. So: clear first, and keep
                # the lease until that has actually succeeded — a released lease
                # with eviction still active is exactly the incident.
                if ! longhorn_clear_eviction; then
                    log ERROR "cycle timed out but Longhorn cleanup failed; keeping the lease and retrying next pass"
                    lease_renew "${lease}" "${phase}" "" || log ERROR "failed to renew lease"
                    echo blocked
                    return 0
                fi
                log WARN "cycle timed out after ${CYCLE_TIMEOUT_SECONDS}s with no reboot; releasing lease"
                lease_release "${lease}" || log ERROR "failed to release lease"
                COOLDOWN_UNTIL=$(( $(now) + COOLDOWN_SECONDS ))
                echo blocked
                return 0
            fi
        fi
    fi

    case "${phase}" in
        armed)
            local remaining
            if ! remaining="$(longhorn_node_evacuated)"; then
                lease_renew "${lease}" armed "" || log ERROR "failed to renew lease"
                log INFO "waiting for Longhorn eviction: ${remaining} replica(s) of attached volumes still on ${NODE_NAME}"
                echo blocked
            elif cluster_safe; then
                # Recorded so a later cordon is recognised as kured's drain.
                lease_renew "${lease}" opened "" || log ERROR "failed to renew lease"
                echo open
            else
                # Keep the lease: this node is still the one queued up, and
                # handing the slot to a peer mid-incident helps nobody.
                lease_renew "${lease}" armed "" || log ERROR "failed to renew lease"
                echo blocked
            fi
            ;;
        draining)
            # kured has cordoned and is draining. Longhorn is evacuating the last
            # replicas, so the cluster is legitimately not "safe" right now;
            # re-blocking here would only fight kured's own retry, and the lease
            # is what keeps every other node out.
            lease_renew "${lease}" draining "" || log ERROR "failed to renew lease"
            echo open
            ;;
        recovering)
            if ! cluster_safe; then
                lease_renew "${lease}" recovering "" || log ERROR "failed to renew lease"
                echo blocked
                return 0
            fi
            if [[ ! "${healthy_since}" =~ ^[0-9]+$ ]]; then
                since="$(now)"
                log INFO "recovery conditions met; settling for ${SETTLE_SECONDS}s"
                lease_renew "${lease}" recovering "${since}" || log ERROR "failed to renew lease"
                echo blocked
                return 0
            fi
            if (( $(now) - healthy_since < SETTLE_SECONDS )); then
                lease_renew "${lease}" recovering "${healthy_since}" || log ERROR "failed to renew lease"
                echo blocked
                return 0
            fi
            log INFO "recovery complete and settled; releasing lease"
            if lease_release "${lease}"; then
                COOLDOWN_UNTIL=$(( $(now) + COOLDOWN_SECONDS ))
            else
                log ERROR "failed to release lease"
            fi
            echo blocked
            ;;
        *)
            log ERROR "unrecognised lease phase \"${phase}\"; releasing"
            lease_release "${lease}" || log ERROR "failed to release lease"
            echo blocked
            ;;
    esac
    return 0
}

pass() {
    local node_json lease holder verdict boot_id

    node_json="$("${KUBECTL[@]}" get node "${NODE_NAME}" -o json 2>/dev/null)" || {
        log ERROR "could not read node ${NODE_NAME}"
        return 1
    }
    lease="$(lease_get)" || { log ERROR "could not read or create the lease"; return 1; }
    [[ -n "${lease}" ]] || { log ERROR "lease read returned nothing"; return 1; }

    holder="$(lease_field "${lease}" '.spec.holderIdentity')"

    if lease_is_held "${lease}"; then
        if [[ "${holder}" == "${NODE_NAME}" ]]; then
            HOLDING=1
            verdict="$(holder_pass "${lease}" "${node_json}")"
            HOLDING=0
            [[ "${verdict}" == "open" ]] && return 0
            return 1
        fi
        log INFO "lease held by ${holder}; staying blocked"
        return 1
    fi
    [[ -n "${holder}" ]] && log WARN "lease held by ${holder} has expired; it is up for grabs"

    # Lease is free. Only a node kured has flagged for reboot bothers to take it;
    # every other node stops here at one cheap single-object GET per interval,
    # which matters on a cluster whose etcd is part of what this protects.
    local flag flag_at btime
    flag="$(jq -r --arg k "${KURED_REBOOT_ANNOTATION}" '.metadata.annotations[$k] // ""' <<<"${node_json}" 2>/dev/null)"
    [[ -n "${flag}" ]] || return 1
    btime="$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)"
    if ! flag_at="$(iso_epoch "${flag}")" || [[ ! "${flag_at}" =~ ^[0-9]+$ || ! "${btime}" =~ ^[0-9]+$ ]]; then
        log ERROR "cannot compare reboot flag \"${flag}\" with boot time \"${btime}\"; not claiming"
        return 1
    fi
    if (( flag_at < btime )); then
        # Remove it rather than just ignore it: kured never rewrites an
        # annotation that is already present, so a real reboot request later
        # would keep this old timestamp and be ignored forever. Only this key,
        # only on this node, only once it provably predates the current boot.
        if "${KUBECTL[@]}" annotate node "${NODE_NAME}" "${KURED_REBOOT_ANNOTATION}-" >/dev/null 2>&1; then
            log WARN "removed stale ${KURED_REBOOT_ANNOTATION}=${flag}: node booted at $(date -u -d "@${btime}" +%Y-%m-%dT%H:%M:%SZ), after it was set"
        elif [[ "${STALE_FLAG_WARNED}" != "${flag}" ]]; then
            log ERROR "could not remove stale ${KURED_REBOOT_ANNOTATION}=${flag}; not claiming"
            STALE_FLAG_WARNED="${flag}"
        fi
        return 1
    fi

    if ! in_maintenance_window; then
        return 1
    fi

    if (( $(now) < COOLDOWN_UNTIL )); then
        log INFO "in cooldown for $(( COOLDOWN_UNTIL - $(now) ))s; not claiming"
        return 1
    fi

    log INFO "node is flagged for reboot and the lease is free; evaluating"
    cluster_safe || return 1

    boot_id="$(jq -r '.status.nodeInfo.bootID // ""' <<<"${node_json}" 2>/dev/null)"
    [[ -n "${boot_id}" ]] || { log ERROR "node reports no bootID; cannot track the reboot"; return 1; }

    if ! lease_claim "${lease}" "${boot_id}"; then
        log INFO "lost the race for the lease; staying blocked"
        return 1
    fi
    if ! longhorn_request_eviction; then
        lease="$(lease_get)" && lease_release "${lease}" || log ERROR "failed to release lease after eviction request failure"
        return 1
    fi
    log INFO "claimed the maintenance lease (boot-id ${boot_id}); gate stays blocked until eviction completes"
    return 1
}

shutdown() {
    log INFO "shutting down; closing gate"
    GATE_STATE=""
    set_gate blocked || true
    exit 0
}

main() {
    trap shutdown TERM INT
    log INFO "node-maintenance-gate starting on ${NODE_NAME} (pod ${POD_NAMESPACE}/${POD_NAME})"
    now > "${HEARTBEAT_FILE}"
    # Never inherit the previous pod's verdict: start shut, prove otherwise. A
    # gate that cannot even label itself keeps retrying rather than proceeding —
    # its pod still matches kured's selector while it does, so the node stays shut.
    until set_gate blocked; do
        now > "${HEARTBEAT_FILE}"
        sleep 5
    done

    while true; do
        if pass; then
            set_gate open || true
        else
            set_gate blocked || true
        fi
        now > "${HEARTBEAT_FILE}"
        # Backgrounded so SIGTERM is handled during the sleep rather than after.
        sleep "${INTERVAL_SECONDS}" &
        wait $!
    done
}

main "$@"
