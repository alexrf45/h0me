# Remediation plan — kube-apiserver SLO rule load on Prometheus

- **Status:** accepted — Option A implemented in commit `d825791` (2026-06-30)
- **Date:** 2026-06-30
- **Context:** [diagnosis post-mortem](../post-mortems/2026-06-30-prometheus-apiserver-slo-rules-disk-io-saturation.md) · [remediation post-mortem](../post-mortems/2026-06-30-prometheus-apiserver-slo-rules-remediation.md)
- **Affected file:** `_lib/observability/kube-prometheus-stack/helmrelease.yaml`

## Problem

The default `kube-apiserver-burnrate.rules` (78 s/eval) and
`kube-apiserver-availability.rules` (51 s/eval) groups run multi-day range queries
over high-cardinality `apiserver_request_*` series on a 30 s interval. This:

- saturates the Prometheus node's disk (192.168.20.204 at ~97% IO) →
  **NodeDiskIOSaturation**, and
- overruns the interval and the 2 m `query.timeout` → failed/missed evaluations →
  **PrometheusMissingRuleEvaluations**.

Both are symptoms of one cause: the SLO rules are too heavy for this instance
(`cpu: 200m` request, `memory: 2Gi`, iSCSI-backed TSDB).

## Options

### Option A — Disable the kube-apiserver SLO default rule groups (recommended)

Add granular disables under `defaultRules` in the kps values:

```yaml
defaultRules:
  create: true
  rules:
    kubeApiserverSlos: false
    kubeApiserverBurnrate: false
    kubeApiserverAvailability: false
```

Follow-on (implemented, commit `3a2ea29`) — reclaim the SLI bucket's ~18k series.
Note the bucket is **not** unused after disabling burnrate/availability/slos: the
`kube-apiserver-histogram.rules` group still consumes it. Reclaiming it therefore
also requires `kubeApiserverHistogram: false` (giving up apiserver p99 latency
quantiles), then extending the `kubeApiServer.serviceMonitor.metricRelabelings`
drop:

```yaml
regex: "apiserver_request_duration_seconds_bucket|apiserver_response_sizes_bucket|apiserver_request_sli_duration_seconds_bucket"
```

**Benefits**

- Removes the root cause directly — both alerts stop, disk IO drops to idle.
- Zero added resource cost; frees CPU, memory, and disk headroom.
- The SLI bucket drop reclaims significant cardinality/memory against the 2 Gi cap.
- Pure GitOps change, instantly reversible.

**Tradeoffs**

- Loses the "Kubernetes / API server" SLO dashboards and the
  `APIServerErrorBudgetBurn` multiwindow alerts. Low value in a single-tenant
  homelab; apiserver health is still covered by up/latency metrics and the
  existing kubelet/node alerts.

**Risk:** low.

### Option B — Keep the rules, grow Prometheus resources + faster TSDB storage

Raise `prometheus.prometheusSpec.resources.requests.cpu` (200m → 500m–1) and move
or speed up the TSDB volume (the `iscsi` PVC at `helmrelease.yaml:152-159` is the
physical IO wall at 97%).

**Benefits**

- Retains full API-server SLO observability.

**Tradeoffs**

- Treats the symptom, not the cause: the `[3d]` burnrate and `[30d]` increase
  queries are inherently heavy and grow with apiserver history — they can still
  approach the interval/timeout as the cluster ages.
- Consumes scarce cluster CPU; the worker pool already saw CPU starvation on
  2026-06-27.
- Storage migration / IO tuning on the iSCSI zvol is involved and higher-risk than
  a values change.

**Risk:** medium; may not fully resolve.

### Option C — Band-aid: raise query.timeout and/or evaluation interval

Bump `prometheusSpec` query timeout (2 m → 3 m) and/or coarsen
`evaluationInterval` (30 s → 1 m) so the groups stop missing iterations.

**Benefits**

- Smallest change; keeps the rules and dashboards.

**Tradeoffs**

- Does nothing for disk IO — **NodeDiskIOSaturation keeps firing**.
- Longer timeout makes evaluations even slower; coarser interval degrades
  alerting latency for *all* rules globally.
- Does not address the cause; expect recurrence.

**Risk:** does not resolve the disk alert.

## Recommendation

**Option A.** It eliminates both alerts at the source for zero ongoing cost and is
fully GitOps-reversible if the apiserver SLO dashboards are later wanted with
proper resourcing. Apply the rule disables first; add the SLI-bucket
`metricRelabelings` drop as a second commit once the rules are confirmed gone.

## Verification (post-change)

1. `k8sop dev flux reconcile source git flux-system` then
   `k8sop dev flux reconcile kustomization observability` (the `observability`
   Kustomization, `_clusters/dev/cluster.yaml:251`, owns `./_lib/observability`).
2. `kube dev logs -n monitoring prometheus-kps-prometheus-0 -c prometheus --since=30m | grep "Evaluating rule failed"` → empty.
3. Disk IO on 192.168.20.204 returns to single digits
   (`topk(5, max by(instance)(rate(node_disk_io_time_seconds_total[5m])))`).
4. Both Slack alerts stay resolved across a full 30 min / 15 min window.

## Open questions

- Keep any API-server SLO visibility, or drop it entirely? (Option A drops all
  three groups; we could keep `kubeApiserverSlos` recording rules and disable only
  `kubeApiserverBurnrate`/`kubeApiserverAvailability` if you want partial retention
  — though those two are the heavy ones.)
