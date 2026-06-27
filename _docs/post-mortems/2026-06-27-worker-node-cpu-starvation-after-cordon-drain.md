# Post-Mortem — Worker node CPU starvation after Proxmox-upgrade cordon/drain

- **Date resolved:** 2026-06-27
- **Severity:** SEV2
- **Component:** node scheduling — fallout across `storage` (democratic-csi), `authentik`, `database` (CloudNativePG)
- **Fix commit:** n/a — operational fix (no manifest change); this post-mortem is the artifact
- **Related:** [cluster-manual-intervention runbook](../runbooks/cluster-manual-intervention.md) (rebalance steps to be added)

## Symptom

Mass container restarts across multiple namespaces, several pods having restarted
well over 1000 times. `kube dev get pods -A -o wide` showed every high-restart
pod pinned to a single worker, `dev-memphis-node-0c918d401fccd2b7`
(192.168.20.205):

- `storage/storage-democratic-csi-freenas-controller-*` — CrashLoopBackOff, **1246** restarts
- `storage/storage-local-path-provisioner-democratic-csi-node-tjwp6` — **556** restarts
- `storage/storage-democratic-csi-freenas-node-mhddx` — CrashLoopBackOff, **478** restarts
- `authentik/authentik-worker-*` — `0/1`, **449** restarts
- `kyverno/kyverno-reports-controller-*` — **442** restarts
- `database/database-cnpg-cloudnative-pg-*` — `0/1`, **412** restarts
- `authentik/authentik-server-*` — `0/1`, **204** restarts

`kube dev top nodes` showed the tell: `dev-memphis-node-0c918d401fccd2b7` at
**101% CPU (1972m)** while the other two workers,
`dev-memphis-node-5a0ba518c4d89d69` and `dev-memphis-node-6e5f5b6bbc8b4a2c`, sat
at **6% and 10%**. The same `local-path-provisioner` DaemonSet pod had 556
restarts on the hot node versus 7–9 on the idle ones — identical workload, so the
signal was node-level, not workload-level.

The failures split into two mechanisms, both timeouts:

- **CSI sidecars (CrashLoopBackOff, exit 255/1)** — leader-election lease renewal
  failing:
  ```
  Failed to update lock: client rate limiter Wait returned an error: context deadline exceeded
  failed to renew lease storage/external-attacher-leader-freenas-api-iscsi: timed out waiting for the condition
  stopped leading
  ```
- **authentik / cnpg-operator (Running, probe-killed, exit 137)** — health probes
  timing out:
  ```
  authentik: Liveness probe failed: command timed out: "ak healthcheck" timed out after 3s
  cnpg:      Liveness/Readiness probe failed: Get "https://10.42.4.9:9443/readyz": context deadline exceeded
  ```

## Impact

SEV2, ~2 days (≈2d4h from the cordon/drain window to resolution on 2026-06-27).
Authentik server and worker were effectively down (`0/1`), so SSO-backed access
was unavailable. The democratic-csi freenas **controller** was crash-looping, so
new volume provisioning / attach / resize operations on the cluster were
unreliable for the duration. The CloudNativePG operator was degraded (existing
databases kept serving, but reconciliation of CNPG resources was unreliable). No
data loss. Node `dev-memphis-node-0c918d401fccd2b7` ran saturated at 100% CPU the
entire window.

## Root cause

A manual Proxmox VE upgrade required cordoning and draining each Talos node in
turn. As workers were cordoned one at a time, the scheduler had progressively
fewer destinations and funneled all evictable pods onto the last node left
schedulable, `dev-memphis-node-0c918d401fccd2b7`. After the upgrade the nodes
were uncordoned (verified: `Taints: <none>`, `Unschedulable: false` on all
three), **but Kubernetes does not rebalance running pods** — the concentration
persisted.

That one node was therefore carrying far more than its share and pinned at 100%
CPU. CPU starvation then produced both failure modes above: leader-election
clients couldn't get scheduled CPU to renew their lease before the deadline and
self-terminated, and health-probe commands/HTTP requests couldn't complete inside
their timeout, so the kubelet killed those pods. The restarts were
self-sustaining — 1246+556+478 container respawns kept containerd/kubelet churning
(CPU not visible in pod-level `top`, which is why measured pod CPU did not sum to
2000m), feeding the starvation that caused the restarts.

The operator's initial hypothesis — liveness probes set too tight — was a
symptom, not the cause: the probes were timing out *because* the node was starved.
On an unloaded node the 3s `ak healthcheck` and the cnpg `readyz` probe pass
normally, and probe tuning would not have touched the CSI leader-election crashes
at all.

## Fix

Rebalanced the pods off the hot node so the scheduler spread them across the two
idle workers:

1. `kube dev cordon dev-memphis-node-0c918d401fccd2b7` — stop pods landing back on it.
2. Deleted the concentrated pods on `dev-memphis-node-0c918d401fccd2b7` so their
   controllers recreated them; with the hot node cordoned and the other two
   workers near-idle, the scheduler placed the replacements on
   `dev-memphis-node-5a0ba518c4d89d69` and `dev-memphis-node-6e5f5b6bbc8b4a2c`.
   The CloudNativePG instance pod moved as well; CNPG recreated it on another node
   and reattached its iSCSI PVC.
3. Killed a few additional pods to even the spread once the bulk had moved.
4. `kube dev uncordon dev-memphis-node-0c918d401fccd2b7` to restore it as
   schedulable capacity.

No manifest changes were required — this was a distribution problem, not a
configuration fault.

## Detection & verification

- `kube dev top nodes` — `dev-memphis-node-0c918d401fccd2b7` fell from 101% back
  toward the single-digit range the other workers showed; load now even across
  the three workers.
- `kube dev get pods -A -o wide | awk 'NR==1 || $5+0 > 5'` — recreated pods come
  back with a fresh restart count of 0 on their new nodes and the
  `(Xs ago)` timestamps stopped advancing, confirming the loops broke.
- The DaemonSet pods that could not be moved (`local-path-...`,
  `freenas-node-...` on the hot node) stabilized on their own once the node's CPU
  freed up — confirming they were starved, not faulty.

## Prevention / follow-up

- **Drain hygiene:** when cordoning/draining for host maintenance, drain
  sequentially **and check `kube dev top nodes` after uncordoning** — uncordon
  restores schedulability but never rebalances existing pods. A node sitting at
  ~100% while peers idle is the signature.
- **Add a rebalance runbook entry** to
  `_docs/runbooks/cluster-manual-intervention.md`: cordon hot node → delete/evict
  the concentrated pods → verify spread with `top nodes` → uncordon. (Open
  follow-up.)
- **Consider an automated rebalancer** — a `descheduler` `RemoveDuplicates` /
  `LowNodeUtilization` policy, and/or `topologySpreadConstraints` on the heavier
  Deployments — so post-maintenance concentration self-corrects instead of
  needing manual intervention. Evaluate and file a tracker item.
- **Do not tighten or loosen probes in response to this** — the probe timeouts
  were a starvation symptom; the thresholds are fine on a healthy node.
