# Decision: live cluster stats in README.md

Date: 2026-06-23 · Status: **accepted — Option B**, implemented in `README.md`

## Problem

Surface lab stats in the top-level `README.md` — CPU, memory, running pods,
Talos version, Kubernetes version, cluster uptime (and we get nodes, Flux
version, cluster age, firing-alert count for free). Decide *how* to render them.

## Key context — the pipeline already exists and is live

This is **not** a from-scratch build. The metrics and the public path are done:

- **kromgo** (`_lib/observability/kromgo/config/config.yaml`, `v0.10.0`) already
  defines every requested metric: `talos_version`, `kubernetes_version`,
  `flux_version`, `cluster_node_count`, `cluster_pod_count`, `cluster_cpu_usage`,
  `cluster_memory_usage`, `cluster_age_days`, `cluster_uptime_days`,
  `cluster_alert_count`.
- **Public exposure is live.** `_infra/cloudflare-tunnel/main.tf` already routes
  `dev-kromgo.th0th.dev → kromgo.monitoring.svc:8080`, with a proxied CNAME, a
  rate-limit ruleset, and the cloudflared→kromgo NetworkPolicy. Verified serving
  `HTTP 200` today.

kromgo output formats (verified live):

| URL | Returns |
| --- | --- |
| `https://dev-kromgo.th0th.dev/<metric>?format=badge` | native SVG badge (`image/svg+xml`), uses kromgo's color thresholds |
| `https://dev-kromgo.th0th.dev/<metric>` (default) or `?format=endpoint` | shields.io endpoint JSON: `{"label":"Uptime","message":"0d","schemaVersion":1}` |
| `?format=raw` | raw Prometheus result |

So the remaining work is almost entirely **README markup**. The options differ in
who renders the badge and whether the README depends on the live endpoint.

---

## Option A — kromgo native SVG badges (direct embed)

Embed kromgo's own SVG directly:

```markdown
![Talos](https://dev-kromgo.th0th.dev/talos_version?format=badge)
![Kubernetes](https://dev-kromgo.th0th.dev/kubernetes_version?format=badge)
![CPU](https://dev-kromgo.th0th.dev/cluster_cpu_usage?format=badge)
![Memory](https://dev-kromgo.th0th.dev/cluster_memory_usage?format=badge)
![Pods](https://dev-kromgo.th0th.dev/cluster_pod_count?format=badge)
![Uptime](https://dev-kromgo.th0th.dev/cluster_uptime_days?format=badge)
```

**Pros**
- Fully self-hosted rendering; one hop; no third-party renderer.
- kromgo's configured color thresholds (CPU/mem/alerts green→orange→red) render as-is.
- Zero new infra — README-only change.

**Cons**
- GitHub proxies images through its **camo** cache (minutes–hours TTL), so "live"
  numbers lag and won't match a fresh `curl`.
- Badge style is kromgo's; can't easily match shields logos/styling used elsewhere.

---

## Option B — shields.io endpoint badges (Recommended)

Let shields.io fetch kromgo's JSON and render a consistent badge. This is the
path the existing terraform comments explicitly anticipate ("shields.io fetches
/<metric_name> from this host"):

```markdown
![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Ftalos_version&logo=talos&style=flat)
![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fkubernetes_version&logo=kubernetes&style=flat)
![CPU](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_cpu_usage&style=flat)
![Memory](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_memory_usage&style=flat)
![Pods](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_pod_count&style=flat)
![Uptime](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_uptime_days&style=flat)
```

**Pros**
- Consistent shields look — add `&logo=`, `&style=flat-square`, `&color=` to match
  conventional README badge rows.
- kromgo's default output is already the exact shields endpoint schema — no kromgo
  change needed.
- README-only change; lowest effort given infra is done.

**Cons**
- Two external dependencies (shields.io **and** your tunnel); if either is down the
  badge shows an error/placeholder.
- Double caching (shields ~5 min + GitHub camo) — numbers lag further than Option A.

---

## Option C — committed static snapshot (scheduled refresh)

A scheduled GitHub Action (or in-cluster CronJob) queries kromgo on an interval
(e.g. hourly), rewrites a delimited block in the README, and commits it back:

```markdown
<!-- BEGIN CLUSTER STATS -->
| Talos | Kubernetes | CPU | Memory | Pods | Uptime |
|-------|-----------|-----|--------|------|--------|
| v1.x  | v1.3x     | 14% | 38%    | 96   | 0d     |
<!-- END CLUSTER STATS -->
```

**Pros**
- README renders even if the cluster is private/offline — no per-view dependency on
  the tunnel.
- Lets you **remove** the public `dev-kromgo` hostname entirely (query via a
  self-hosted/Tailscale runner) if you'd rather not expose stats publicly.
- Git history becomes a record of cluster stats over time.

**Cons**
- Stats only as fresh as the cron interval; never truly live.
- Commit churn in history; needs a runner with kromgo/cluster reach + a write token.
- Most moving parts to build and maintain (a workflow + templating script).

---

## Recommendation

**Option B.** The infrastructure was clearly built with shields.io README badges in
mind (terraform + kromgo comments), kromgo already emits the shields schema, and it
gives the cleanest, most conventional public-README look for the least effort. If
you want to drop the shields.io dependency, **Option A** is a one-line-per-badge
variant on the same live endpoint. Reserve **Option C** for when you want
offline-resilient stats or to stop exposing the endpoint publicly.

## Resolved (2026-06-23)

1. **Layout:** two rows — versions (Talos / Kubernetes / Flux) and resources
   (CPU / Memory / Pods / Nodes / Uptime / Alerts).
2. **Styling:** `style=flat`, no logos.
3. **Uptime:** use `cluster_uptime_days` as-is (node boot time; resets on reboot).
4. **Public exposure:** keep `dev-kromgo.th0th.dev` public (Option B as designed).
5. **Multi-cluster:** per-cluster badge rows — one `### <env> — <cluster>` block
   each, pointing at `https://<env>-kromgo.th0th.dev/<metric>`. dev (memphis) is
   live; a commented staging/prod template is left in `README.md`.

Verified live before commit: shields.io rendered Talos 1.13.4, Kubernetes 1.36.0,
CPU 13.2%, Alerts 4 from `dev-kromgo.th0th.dev`.
