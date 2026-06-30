# Post-Mortem — Remediation: disabling kube-apiserver SLO rules clears disk saturation & missed evaluations

- **Date resolved:** 2026-06-30
- **Severity:** SEV3
- **Component:** `observability` — kube-prometheus-stack Prometheus (`prometheus-kps-prometheus-0`) on `dev-memphis-node-6e5f5b6bbc8b4a2c` (192.168.20.204)
- **Fix commit:** `d825791` — `fix(observability): disable heavy kube-apiserver SLO recording rules`
- **Related:** diagnosis [post-mortem 2026-06-30 (disk-io-saturation)](2026-06-30-prometheus-apiserver-slo-rules-disk-io-saturation.md); plan [decisions/prometheus-apiserver-slo-rule-load.md](../decisions/prometheus-apiserver-slo-rule-load.md)

## Symptom

Recurring Slack alerts — **NodeDiskIOSaturation** and
**PrometheusMissingRuleEvaluations** (both `monitoring`) — driven by the
kube-apiserver SLO recording rules. Root cause established in the companion
diagnosis post-mortem: the `kube-apiserver-burnrate.rules` (78 s/eval) and
`kube-apiserver-availability.rules` (51 s/eval) groups run multi-day range queries
over high-cardinality `apiserver_request_*` series on a 30 s interval, pegging the
Prometheus node's disk at ~97% IO and overrunning the 2 m `query.timeout`. This
record documents the remediation (Option A) and its verification.

## Impact

SEV3, no user-facing outage; effects confined to the monitoring stack (stale
apiserver SLO series, ~97% disk IO on node 192.168.20.204, recurring alert noise).
The remediation itself was a GitOps HelmRelease values change reconciled by Flux —
no workload disruption; Prometheus hot-reloaded its rule config without a restart
(pod `prometheus-kps-prometheus-0` kept its uptime).

## Root cause

See the diagnosis post-mortem for the full causal chain. In short: the default
kube-apiserver SLO rule groups are too heavy for this instance
(`cpu: 200m` request, `memory: 2Gi`, iSCSI-backed TSDB), and a single cause —
evaluating those queries — produced both the disk saturation (TSDB block reads)
and the missed/failed evaluations (eval time > interval and > query timeout).

## Fix

Applied **Option A** — disabled the three heavy kube-apiserver SLO default rule
groups in the kps HelmRelease values
(`_lib/observability/kube-prometheus-stack/helmrelease.yaml`):

```yaml
defaultRules:
  create: true
  rules:                          # added
    kubeApiserverSlos: false
    kubeApiserverBurnrate: false
    kubeApiserverAvailability: false
```

`kubeApiserverHistogram` was left enabled (not a culprit; provides apiserver
latency quantiles for dashboards). Key names were verified against
`helm show values kube-prometheus-stack --version 78.0.0` before editing to avoid a
silent no-op.

Delivery (Flux tracks `refs/heads/dev`):

1. Commit `d825791` on branch `dev`, pushed to `origin/dev`.
2. `k8sop dev flux reconcile source git flux-system` → fetched `d825791`.
3. `k8sop dev flux reconcile kustomization observability` → applied; helm-controller
   upgraded `monitoring-kube-prometheus-stack` to release **v2**
   (`Helm upgrade succeeded`).

No out-of-band steps. Fully GitOps-reversible by reverting the commit.

## Detection & verification

All checks passed (≈16:43–17:00 UTC / 12:43–13:00 EDT):

- **Rule groups removed.** PrometheusRule CRs for burnrate/availability/slos are
  gone — `kube dev get prometheusrules -n monitoring | grep apiserver` lists only
  `kps-kube-apiserver-histogram.rules` and `kps-kubernetes-system-apiserver`.
  Live `/api/v1/rules` confirms the only remaining `kube-apiserver-*` group is
  `kube-apiserver-histogram.rules` (2 rules, **0.18 s** eval). The 78 s and 51 s
  groups no longer exist.
- **Eval failures stopped.** Last `"Evaluating rule failed"` log line at
  **16:44:03 UTC** (`group=kube-apiserver-burnrate.rules`, coincident with the
  reload); none in the 16+ minutes since. `prometheus_rule_evaluation_failures_total`
  top groups all read 0.
- **Disk IO recovered.** Node 192.168.20.204 `rate(node_disk_io_time_seconds_total[5m])`
  fell as the window flushed pre-change samples:

  | t after upgrade | IO util |
  | --------------- | ------- |
  | (pre-change) | 0.97 |
  | +30 s | 0.53 |
  | +120 s | 0.32 |
  | +180 s | 0.18 |
  | +240 s | **0.16** |

  From ~97% to ~16%, now in line with the other nodes — comfortably under the
  NodeDiskIOSaturation threshold (weighted-seconds queue > 10 for 30 m).

Watch item: confirm both Slack alerts stay resolved across a full 30 min / 15 min
window (the `for:` durations) — expected, given the drivers are removed.

## Prevention / follow-up

- **SLI-duration bucket drop — DONE** (commit `3a2ea29`). The deferred premise
  ("the SLI bucket is now unused") was **wrong**: the kept
  `kube-apiserver-histogram.rules` group still consumed
  `apiserver_request_sli_duration_seconds_bucket` (its two
  `cluster_quantile:apiserver_request_sli_duration_seconds:histogram_quantile`
  rules), confirmed by reading the live rule expressions. The bucket carried
  **18,062 series**. Decision (recorded in the SLO rule-load doc): trade the
  apiserver p99 latency quantiles for the cardinality reclaim — so
  `kubeApiserverHistogram: false` was added alongside extending the
  `metricRelabelings` regex to drop the SLI bucket.
  - Verification: HelmRelease upgraded to release **v3**; the
    `kps-kube-apiserver-histogram.rules` PrometheusRule CR is gone; and
    `count(apiserver_request_sli_duration_seconds_bucket)` drained **18062 → 0**
    within ~80 s of the upgrade (metricRelabelings drop at scrape time + series
    staleness). No `kube-apiserver-*` recording groups remain.
- **Storage:** the Prometheus TSDB on the `iscsi` PVC is the physical IO wall; if
  baseline disk IO stays elevated independent of these rules (TSDB compaction was
  not isolated from query load), evaluate faster storage or a larger block budget.
- **Guardrail:** before enabling any default SLO rule mixin, check
  `prometheus_rule_group_last_duration_seconds` against the eval interval — the
  apiserver SLO mixin assumes far more Prometheus headroom than this homelab has.
- File a tracker item linking both post-mortems and the decision doc.
