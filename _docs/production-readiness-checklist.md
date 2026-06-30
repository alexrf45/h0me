# Production-Readiness Checklist

Date: 2026-06-24 · Status: **living document**

The gate for promoting a cluster from `dev` (memphis) to **production**. `dev` is the proving
ground; a cluster is "production" only when **every box is checked and its benchmark is met** —
not when the manifests merely exist. Each milestone states an **Exit criteria** (a concrete,
observable benchmark) so "done" is testable, not asserted.

Open punch-list IDs in brackets (e.g. `[A1]`, `[N6]`) cross-reference the rolling review
`_docs/reviews/h0me-review-2026-06-24.md` — track the work there; this doc is the promotion gate.

---

## M-OBS — Observability & Alerting *(detailed — the headline milestone)*

Goal: when the lab misbehaves, **I find out on my iPhone before a user does**, for both the
clusters and Proxmox.

### Metrics coverage
- [ ] Every workload exposes metrics via a ServiceMonitor/PodMonitor (audit against
  `_lib/observability/kube-prometheus-stack/servicemonitor-*.yaml`).
- [ ] **Proxmox nodes scraped** — `pve-exporter` (or node-exporter on the PVE hosts) added as
  a `ScrapeConfig` alongside `_lib/observability/scrape-configs/truenas-scrapeconfig.yaml`.
  *Currently a gap: only TrueNAS is scraped, no Proxmox metrics.*
- **Exit:** Prometheus targets page shows every app **and** every PVE/TrueNAS node `UP`.

### Alert rules
- [ ] Each critical failure mode has a PrometheusRule (extend
  `_lib/observability/kube-prometheus-stack/prometheusrule-custom.yaml` — today covers OOM,
  Flux, CNPG backup, cert expiry, PVC capacity, Gatus-down).
- [ ] Watchdog / dead-man's-snitch verified end-to-end (a *missing* Watchdog pages someone).
- **Exit:** deliberately break one component per rule group → the matching alert fires.

### Notification delivery *(the goal)*
A synthetic **critical** alert must reach the on-call iPhone in **< 2 min**. Pick at least one
delivery path (Pushover recommended for true push; Slack is the shared-channel baseline):
- [ ] **Slack mobile** — free; the revived app per `_docs/decisions/slack-notifications-terraform.md`. Baseline channel + history.
- [ ] **Pushover** ★recommended — Alertmanager **native `pushover_configs`** receiver, ~$5
  one-time, homelab-standard reliability; secret via 1Password → ESO.
- [ ] **ntfy** — self-hosted, free iOS app, fits the self-hosted ethos; more infra to run/secure.
- **Exit:** fire a test critical alert → phone buzzes in < 2 min, and the resolve clears it.

### Proxmox alerting
Hosts run **PVE 9.2.3** (not 8.x — the notification stack exists since 8.1 but the
notification/matcher API and webhook target schema changed across 8.x→9.x; validate target
config against the 9.2 API, not 8.1 docs).
- [ ] **PVE 9.2 built-in notification target** configured (Gotify / SMTP / webhook) routed to
  the chosen push path above — covers host events backups can't (node down, fencing, ZFS).
- [ ] *(optional)* `pve-exporter → Prometheus` so node disk/ZFS/temp/quorum get metric alerts.
- **Exit:** pull a node's power (or fail a PVE backup job) → the iPhone is notified.

### Signal-path resilience
- [ ] Alertmanager ≥ 2 replicas / clustered (today **single replica** — a down AM pod = no
  alerts). Prometheus HA (2 replicas or Thanos/agent) is a stretch goal.
- **Exit:** kill the active Alertmanager pod, fire an alert, confirm it still delivers.

### Dashboards & SLO
- [ ] Grafana SLO view over `gatus_results_endpoint_success` (uptime/error budget per service).
- [ ] Critical alerts carry `runbook_url` annotations pointing at `_docs/` runbooks.
- **Exit:** every critical alert links to a runbook; SLO dashboard renders per-service uptime.

---

## Milestone stubs *(gating dimensions — tracked in the review, summarized here)*

### M-HA — Availability & resilience
- [ ] PDB coverage on all apps — **done** `[M1]` (PR #4); CNPG manages its own DB PDBs.
- [ ] Multi-replica control plane + worker anti-affinity for stateless apps.
- **Exit:** drain any single node → no user-facing outage.

### M-DR — Backup & disaster recovery
- [ ] CNPG backups (Barman Cloud) green for every database.
- [ ] **Restore drill** performed and documented (not just "backups exist").
- **Exit:** a documented, timed restore of one database from object storage succeeds.

### M-SEC — Security
- [ ] Default-deny NetworkPolicies; Kyverno + Falco in enforce (not audit) where intended.
- [ ] **Prod ClusterIssuer** — Let's Encrypt **production** (not staging) for all public certs.
- [ ] Secret rotation path proven (1Password → ESO refresh observed end-to-end).
- **Exit:** an unsanctioned cross-namespace flow is blocked; all certs chain to LE prod.

### M-CAP — Capacity & limits
- [ ] `ResourceQuota` + `LimitRange` per app namespace; requests/limits on every workload.
- **Exit:** no workload runs unbounded; a runaway pod is capped, not node-killing.

### M-UPG — Lifecycle
- [ ] Safe, repeatable Talos + Kubernetes upgrades `[CI1` / UC-C`]`.
- [ ] Proxmox/k8s node-drain automation `[A1]` (cordon→upgrade host→reboot→uncordon,
  pve06→pve01) — gated on M-HA PDB coverage.
- [ ] Renovate hygiene — pinned CRDs track operator chart versions.
- **Exit:** a k8s patch bump rolls through via the documented flow with zero manual node surgery.

### M-OPS — Operational readiness
- [ ] Runbooks for the top failure modes; post-mortem habit maintained (`_docs/post-mortems/`).
- [ ] On-call / alert-ack loop documented and tested (alert → ack → resolve).
- **Exit:** a cold re-read of the runbooks lets a fresh session resolve a paged alert.

---

## Promotion gate

A cluster is **production** when:

1. **M-OBS** fully green — Proxmox + clusters scraped, alerts fire, and a critical alert
   reaches the iPhone in < 2 min over an HA signal path.
2. **M-HA / M-DR / M-SEC** green — survives a node loss, a restore is proven, certs are on the
   LE prod issuer behind default-deny.
3. **M-CAP / M-UPG / M-OPS** green — bounded resources, a repeatable upgrade path, and
   runbooks that work cold.
