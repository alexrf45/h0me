# Post-Mortem — kube-apiserver SLO recording rules saturate the Prometheus node's disk and miss rule evaluations

- **Date resolved:** 2026-06-30 (this is the diagnosis; remediation applied & verified in the companion post-mortem)
- **Severity:** SEV3
- **Component:** `observability` — kube-prometheus-stack Prometheus (`prometheus-kps-prometheus-0`) on `dev-memphis-node-6e5f5b6bbc8b4a2c` (192.168.20.204)
- **Fix commit:** `d825791` — applied & verified, see [remediation post-mortem](2026-06-30-prometheus-apiserver-slo-rules-remediation.md)
- **Related:** plan [decisions/prometheus-apiserver-slo-rule-load.md](../decisions/prometheus-apiserver-slo-rule-load.md); [lab review tracker](../reviews/h0me-review-2026-06-28.md); kps values `_lib/observability/kube-prometheus-stack/helmrelease.yaml`

## Symptom

Two Prometheus alerts fired to Slack within an hour of each other (times EDT,
UTC−4):

- **NodeDiskIOSaturation** (monitoring) — 11:16, resolved ~11:29 (~13 min)
- **PrometheusMissingRuleEvaluations** (monitoring) — 12:14, resolved 12:27 (~13 min)

Both alert expressions (pulled live from `/api/v1/rules`):

```
NodeDiskIOSaturation:
  rate(node_disk_io_time_weighted_seconds_total{device=~"...(sd.+|vd.+|dm-.+|...)"}[5m]) > 10   for: 30m
PrometheusMissingRuleEvaluations:
  increase(prometheus_rule_group_iterations_missed_total{job="kps-prometheus"}[5m]) > 0          for: 15m
```

Prometheus's own logs over the alert window (16:20–16:33 UTC ≈ 12:20–12:33 EDT)
show the rule manager failing the heaviest groups:

```
level=WARN source=group.go:544 msg="Evaluating rule failed" group=kube-apiserver-burnrate.rules
  name=apiserver_request:burnrate3d ... err="query timed out in expression evaluation"
level=WARN ... group=kube-apiserver-availability.rules
  name=...:increase30d            ... err="query timed out in expression evaluation"
... err="expanding series: context deadline exceeded"
```

`prometheus_rule_evaluation_failures_total` and `prometheus_rule_group_iterations_missed_total`
increase **only** for `kube-apiserver-burnrate.rules` and `kube-apiserver-availability.rules`.

Per-group evaluation duration (`prometheus_rule_group_last_duration_seconds`):

| Rule group | Eval time | Interval |
| ---------- | --------- | -------- |
| `kube-apiserver-burnrate.rules` | **77.7 s** | 30 s |
| `kube-apiserver-availability.rules` | **51.3 s** | 30 s |
| next heaviest group | 14.6 s | 30 s |

Disk IO utilization, instant `rate(node_disk_io_time_seconds_total[5m])` per node
(measured during the investigation, still active):

| Node | IO utilization |
| ---- | -------------- |
| **192.168.20.204** (Prometheus node) | **0.97 (97%)** |
| 192.168.20.200 | 0.09 |
| 192.168.20.202 | 0.08 |
| 192.168.20.201 | 0.08 |
| 192.168.20.203 | 0.03 |

`prometheus-kps-prometheus-0` is scheduled on `dev-memphis-node-6e5f5b6bbc8b4a2c`
= 192.168.20.204 — the single saturated node. Every other node is near-idle.

## Impact

SEV3, no user-facing outage. Effects were confined to the monitoring stack:

- The kube-apiserver SLO recording series (`apiserver_request:burnrate*`,
  availability `:increase*`) were stale/gappy whenever the rules timed out, so the
  "Kubernetes / API server" SLO dashboards and `APIServerErrorBudgetBurn` alerts
  were unreliable.
- The Prometheus node's disk ran ~97% busy with an IO queue sustained above the
  alert threshold (weighted-seconds > 10 for 30 min), risking slow scrapes/queries
  for everything else Prometheus serves.
- Recurring Slack noise: both alerts flap because the underlying load is
  effectively continuous, not a one-time spike.

No data loss. No application affected.

## Root cause

The kube-prometheus-stack **default kube-apiserver SLO recording rules** are too
heavy for this Prometheus instance. The `kube-apiserver-burnrate.rules` and
`kube-apiserver-availability.rules` groups evaluate multi-day range queries
(`[1d]`, `[3d]`, `avg_over_time(...[30d])`) over high-cardinality
`apiserver_request_sli_duration_seconds_*` and `apiserver_request_total` series.
Evaluating them has two consequences from one cause:

1. **Disk saturation** — the queries force large TSDB block reads on the node
   hosting Prometheus (192.168.20.204), driving disk IO to ~97% with a deep IO
   queue → **NodeDiskIOSaturation**.
2. **Missed/failed evaluations** — the burnrate group takes ~78 s and the
   availability group ~51 s against a **30 s** `evaluationInterval`, so they can
   never keep up; individual rules also exceed the 2-minute `query.timeout`
   (`err="query timed out in expression evaluation"`), producing failed
   evaluations and missed iterations → **PrometheusMissingRuleEvaluations**.

The two alerts fire and resolve on different windows (NodeDiskIOSaturation needs
queue-depth > 10 for 30 min; PrometheusMissingRuleEvaluations needs a missed
iteration sustained for 15 min), so they flap independently — but both are driven
by the same heavy-query cycle, which is why they appeared close together.

Contributing factors:

- Prometheus is provisioned at `cpu: 200m` request / no CPU limit, `memory: 2Gi`
  limit (`_lib/observability/kube-prometheus-stack/helmrelease.yaml:160-165`).
- `defaultRules.create: true` with no granular disables, so all apiserver SLO
  rule groups are enabled (`helmrelease.yaml:34-35`).
- The existing `kubeApiServer` `metricRelabelings` drop only sheds
  `apiserver_request_duration_seconds_bucket` and `apiserver_response_sizes_bucket`
  (`helmrelease.yaml:271-274`) — **not** the
  `apiserver_request_sli_duration_seconds_bucket` series the SLO rules actually
  consume.

## Fix

Root cause identified; remediation is filed as a plan with options rather than
applied blind — see
[decisions/prometheus-apiserver-slo-rule-load.md](../decisions/prometheus-apiserver-slo-rule-load.md).
Recommended option (A): disable the kube-apiserver SLO default rule groups in the
kps HelmRelease values —

```yaml
defaultRules:
  create: true
  rules:
    kubeApiserverSlos: false
    kubeApiserverBurnrate: false
    kubeApiserverAvailability: false
```

— which removes both the disk-IO driver and the evaluation timeouts, and (once the
consuming rules are gone) lets the `apiserver_request_sli_duration_seconds_bucket`
series be dropped via `metricRelabelings` to reclaim cardinality/memory/disk.

## Detection & verification

Once remediated, confirm:

- Logs clean of timeouts:
  `kube dev logs -n monitoring prometheus-kps-prometheus-0 -c prometheus --since=1h | grep "Evaluating rule failed"` → no output.
- No more missed iterations:
  `prometheus_rule_group_iterations_missed_total` flat (query via the Prometheus
  API on `localhost:9090` through `kube dev exec`).
- Disk IO on 192.168.20.204 back to single digits:
  `topk(5, max by(instance)(rate(node_disk_io_time_seconds_total[5m])))` → .204
  no longer dominant.
- Both alerts stay resolved in Slack across a full 30-min/15-min window.

## Prevention / follow-up

- Apply the remediation plan (Option A) and verify as above.
- Audit other heavy default rule groups before re-enabling any SLO rules; the
  apiserver SLO mixin assumes far more Prometheus headroom than a homelab provides.
- Consider whether the Prometheus TSDB (iSCSI-backed PVC, `storageClassName: iscsi`,
  `helmrelease.yaml:152-159`) is an ongoing IO bottleneck independent of these
  rules; TSDB compaction on slow storage is a plausible co-contributor to baseline
  disk IO and was not isolated from query load during this investigation.
- File a tracker item linking this post-mortem and the remediation plan.
