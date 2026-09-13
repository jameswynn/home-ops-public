# Longhorn-aware node maintenance gate (#1508)

`core/kube-system/node-maintenance-gate` — a DaemonSet that decides, per node,
whether kured is allowed to start a reboot cycle. It is #1508's third acceptance
criterion: **the next node is not rebooted until the previous node's Longhorn
state has actually recovered.**

## What was already in place

These are merged and are the load-bearing half of #1508. The gate sits on top of
them and does not weaken any of them:

- `nodeDrainPolicy: block-for-eviction-if-contains-last-replica`
  (`core/longhorn-system/longhorn/app/helm-release.yaml`). Longhorn holds the
  singleton instance-manager's PDB shut while any volume's last healthy replica
  lives on the draining node. **That wait is the evacuation.** Deleting the
  instance-manager PDB to "make drains work" removes the evacuation and leaves
  the reboot.
- `forceReboot: false` (kured, #1711). A drain Longhorn will not let finish means
  no reboot happens at all.
- Observability for maintenance windows: #1713 (`NodeMaintenanceDrainStalled`,
  `LonghornMaintenanceRecoveryStalled`, `NodeMaintenanceRebootOverlappedRecovery`,
  `LonghornNodeUnhealthyWhileNodeReady`, `LonghornNodeSchedulingDisabledTooLong`,
  `KuredRebootPendingTooLong`). That is the watching half and gates nothing; this
  gate does not restate any of it.

What was missing is the interlock. kured's `concurrency: 1` serialises reboot
*initiation* only, so the next node could be drained while the previous one's
replicas were still rebuilding — which is how 2026-08-20 ended with ~49 degraded
volumes.

## Shape

A DaemonSet, one pod per node, consumed through kured's `blockingPodSelector`.
Not a CronJob: the gate has to answer continuously, and a one-shot job that has
already exited answers nothing.

Mechanics, read from kured 1.23.0 rather than assumed:

- `pkg/blockers/kubernetespod.go` lists pods with
  `spec.nodeName=<this node>,status.phase!=Succeeded,status.phase!=Failed,status.phase!=Unknown`
  and the configured label selector, across all namespaces. **The check is
  per-node**, so a gate pod only ever blocks its own node — which is exactly why
  a DaemonSet is the right shape.
- A `Pending` or `CrashLoopBackOff` gate pod still matches, so a gate that cannot
  start blocks its node.
- A pod-list error returns `true` (blocked). kured's blocker interface fails
  closed.
- `cmd/kured/main.go` evaluates blockers *before* acquiring the lock and before
  cordoning, and the lock-holding/uncordon path runs earlier without consulting
  blockers — so the gate decides whether a node may *start*, and never strands a
  node mid-cycle.
- The chart (5.12.1) exposes `configuration.blockingPodSelector` as a list and
  `configuration.annotateNodes`; no chart change was needed.

The pod template carries `node-maintenance-gate: blocked`, and the script drops
it to `open` only after a full pass proves the cluster safe. The DaemonSet
selector deliberately does **not** include that label — a selector matching it
would orphan the pod the moment it opened.

## The pass

Any API error, timeout, unparseable JSON, or state string Longhorn does not
document leaves the gate `blocked`. The checks:

1. **Kubernetes** — every node `Ready`; no node cordoned.
2. **Longhorn nodes** — `.spec.allowScheduling == true`,
   `.spec.evictionRequested == false`, condition `Ready == True`. Both are
   *spec* fields on `nodes.longhorn.io` (verified against longhorn-manager
   v1.11.2), so they are read from the object. `evictionRequested` has no metric
   at all, which is the main reason this reads the API rather than Prometheus.
3. **Longhorn volumes** — nothing `degraded` or `faulted`; anything `attached`
   must be `healthy`. A *detached* volume reports robustness `unknown` as a
   matter of course and does not block. A state or robustness value outside the
   documented enums blocks.
4. **Longhorn replicas** — nothing rebuilding, i.e. no replica with
   `.status.currentState == "running"` and an empty `.spec.healthyAt`
   (`healthyAt` is cleared before a rebuild and set once the replica is
   read/write in an engine).
5. **local-path PVCs** — pods mounting a `local-path` claim are node-local and
   cannot reschedule (CNPG, Loki, Tempo, Prometheus, Alertmanager, Garage and the
   Forgejo runner all live there). Any such pod `Running`/`Pending` but not
   `Ready` keeps the gate shut.

### One asymmetry worth knowing

Longhorn's node controller sets **replica** `.spec.evictionRequested`
automatically on any cordoned node under
`block-for-eviction-if-contains-last-replica`
(`controller/node_controller.go:shouldEvictReplica`). Blocking on that would
deadlock the very drain this gate exists to protect, so only *node*-level
`evictionRequested` — which only an operator ever sets — is treated as a block.

## Serialisation: the Lease

`coordination.k8s.io/v1` Lease `kube-system/node-maintenance-gate`. All state
lives on the object, not in the process, so it survives the reboot of the node
running the gate:

| Field | Meaning |
| --- | --- |
| `spec.holderIdentity` | node currently allowed a cycle |
| `spec.leaseDurationSeconds` | 1800 — long enough to cover a reboot outage, since nobody renews while the node is down |
| `.../phase` annotation | `armed` \| `draining` \| `recovering` |
| `.../boot-id` annotation | node boot ID observed at claim time |
| `.../healthy-since` annotation | epoch at which recovery conditions first held |

The Lease is **created by the gate, not by Flux**. A Flux-managed Lease would
have its `holderIdentity` reset on every drift correction, handing the
maintenance slot to another node mid-cycle. Claims are `kubectl replace` of the
object as read, resourceVersion and all, so a concurrent claim loses with a 409
rather than silently winning.

State machine for the holder:

- **armed** — claimed, waiting for kured. Gate `open` while the cluster is safe;
  a failing check closes the gate but does **not** release the lease, because
  handing the slot to a peer mid-incident helps nobody.
- **draining** — this node is cordoned. Gate stays `open`: Longhorn is evacuating
  last replicas, so the cluster is legitimately not "safe" right now, and
  re-blocking would only fight kured's own retry. The lease is what keeps every
  other node out. If kured aborts and uncordons, this drops back to `armed`.
- **recovering** — the node's `bootID` changed, which is the only proof the
  reboot actually happened and is still readable after the gate pod was itself
  restarted by that reboot. Gate stays `blocked` until every check above passes
  *and* has kept passing for `SETTLE_SECONDS` (600). Then the lease is released.

Bounds:

- `CYCLE_TIMEOUT_SECONDS` (7200) releases an `armed`/`draining` lease that never
  produced a reboot, followed by a 600s local cooldown so the same node does not
  immediately re-take the slot.
- **Recovery is deliberately unbounded.** A recovery that never finishes must
  keep every other node still; #1713's `KuredRebootPendingTooLong` (36h) is what
  surfaces that to a human.

Which node claims is decided by kured's own
`weave.works/kured-reboot-in-progress` annotation (hence `annotateNodes: true`),
set on a node it intends to reboot and cleared once the reboot demonstrably
happened. Without that signal the gate would burn maintenance slots on nodes with
nothing to do. It also means a node with nothing pending stops at one cheap
single-object GET per interval — the expensive cluster-wide lists only run on the
node claiming or holding the lease, which matters given the muspelheim etcd
caution in `CLAUDE.md`.

`period` dropped from 1h to 15m at the same time. kured is no longer what spaces
reboots out — the Lease is — and at 1h a node needed one tick to get annotated
and another to act on an open gate, which burnt most of the 02:00–05:00 window on
waiting. Nothing about the recovery wait got shorter.

## Image

`docker.io/alpine/k8s:1.37.0@sha256:b421c...` — Alpine 3.25 with kubectl 1.37.0
(matching the pinned `mise.toml` CLI), jq 1.8.2, bash 5.3 and yq.

This repo holds no application source and no image build pipeline, so a
first-party controller image cannot be produced here, and nothing already in
`core/`, `apps/` or `components/` ships a shell plus a Kubernetes client — the
closest are `mirror.gcr.io/busybox` (no kubectl, no jq) and
`docker.io/curlimages/curl` (no jq). Parsing Longhorn CRD JSON without a real
client, in a component whose entire job is to fail closed, was not a trade worth
making.

The pin is the **multi-arch index digest**, not a platform manifest, so the same
reference resolves on every node. The index was confirmed to carry `linux/amd64`
and `linux/arm64` before pinning. This is a correctness requirement, not
packaging polish: niflheim is an arm64 Pi 4 with an `arm=true:NoSchedule` taint
that runs Longhorn replicas like every other node, and **a node with no gate pod
is a node with no gate**, because kured's check is per-node and finds nothing to
match.

Trade-offs accepted, stated plainly: it is a general-purpose ~317MB image with
cluster credentials, and it is a new third-party supply-chain dependency. It runs
non-root (65534), read-only root filesystem, all capabilities dropped, no
privilege escalation, and its RBAC has no cluster-wide write verb at all — the
only writes are one label on its own pod and one Lease in its own namespace.
Renovate tracks the tag. Replacing it with a first-party controller published to
`forge.wynning.tech/james/…` (like `carol` and `agentmemory`) remains the better
long-term answer; the script is small enough to port.

## Fail-closed boundary

Two cases are not fully covered:

- A gate pod killed while labelled `open` leaves that node unguarded until the
  pod restarts and re-labels. Bounded by the evaluation interval, not eliminated.
  A wedged (rather than killed) loop is covered — the liveness probe reads a
  heartbeat the script writes at the end of every pass, so a stuck gate is
  restarted and comes back `blocked`.
- A node with no gate pod at all is ungated. `NodeMaintenanceGateIncomplete`
  (desired vs ready, `for: 15m`) is the only alert this PR adds, and it exists
  for exactly this.

A permanently-unready local-path consumer, or a Longhorn object stuck in an
unrecognised state, will hold the window shut indefinitely. That is the intended
direction of failure, and `KuredRebootPendingTooLong` is what makes it visible.

## Operating it

```sh
# Who holds the slot, and what phase is it in
kubectl -n kube-system get lease node-maintenance-gate -o yaml

# What each node's gate currently says
kubectl -n kube-system get pods -l app.kubernetes.io/name=node-maintenance-gate \
  -L node-maintenance-gate -o wide

# Why a gate is shut
kubectl -n kube-system logs -l app.kubernetes.io/name=node-maintenance-gate --tail=50

# Force the window shut by hand (the gate is not the only way)
kubectl -n kube-system annotate ds kured \
  weave.works/kured-node-lock='{"nodeID":"manual"}' --overwrite
```

Tunables are environment variables on the container, all with in-script defaults:
`INTERVAL_SECONDS` (60), `LEASE_DURATION_SECONDS` (1800), `SETTLE_SECONDS` (600),
`CYCLE_TIMEOUT_SECONDS` (7200), `COOLDOWN_SECONDS` (600),
`LOCAL_PATH_STORAGE_CLASS` (`local-path`), `REQUEST_TIMEOUT` (20s).

### Rollback

Remove `blockingPodSelector` from the kured HelmRelease and delete the
Kustomization. Order matters only in that removing the DaemonSet while keeping
the selector is the fail-*open* direction — kured finds no matching pod and stops
blocking. The gate owns no cluster state beyond its own pod labels and the Lease,
and the Lease is inert once the selector is gone; `kubectl -n kube-system delete
lease node-maintenance-gate` cleans it up. `annotateNodes` and `period` are
independent of the gate and can be left or reverted separately.

## Rejected: gating on Prometheus alerts

kured can also block on alerts (`prometheusUrl` + `alertFilterRegexp` +
`alertFilterMatchOnly`), which needs no new image, and the metrics partly exist —
`longhorn_volume_robustness` is a state-labelled 0/1 gauge on 1.11.x, and
`longhorn_node_status{condition="allowScheduling"}` is genuinely exported. A
working version was built and validated. It was not shipped:

- It moves the interlock into the monitoring stack: the thing deciding whether it
  is safe to reboot would depend on Prometheus, which lives on local-path storage
  on the nodes being rebooted.
- It collides with #1713 — same `core/kube-system/kured/app/kustomization.yaml`
  line, a second PrometheusRule in the same directory, and duplicate rules.
- `evictionRequested` has no metric, so the Longhorn state that matters most has
  to be read from the API regardless.
