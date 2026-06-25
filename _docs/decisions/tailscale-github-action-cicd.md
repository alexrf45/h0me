# Decision: Tailscale GitHub Action for h0me CI/CD

Date: 2026-06-24 · Status: **proposed**

## Problem

The repo has **no `.github/workflows/`** — CI is greenfield. We want a CI/CD-like
capability that reaches the lab over the tailnet (never the public internet) to:

1. **Validate config changes** before they merge.
2. **Report cluster state / metrics** richer than the public kromgo badges.
3. **Drive Talos-native Kubernetes upgrades** (dry-run on PR → apply on merge).

…without exposing the cluster API publicly or putting kubeconfig/secrets on disk in CI.

## Key context — most of the path already exists

This is **not** from scratch:

- **Tailscale operator is live** (`_lib/networking/tailscale/helmrelease.yaml`, `v1.98.3`)
  with the **API Server Proxy enabled**:

  ```yaml
  apiServerProxyConfig:
    mode: "true"
    allowImpersonation: "true"
  ```

  → the Kubernetes API is already reachable over the tailnet, with impersonation, **no
  kubeconfig fetch required**. This covers Use Cases A and B for free.

- **`talosconfig` and `kubeconfig` are already in 1Password** — exported on cluster
  bootstrap by `_infra/modules/talos-pve/config-export.tf` (items `memphis-talosconfig`,
  `memphis-kubeconfig`). CI pulls these at runtime; nothing lands on disk.

- **kromgo already serves 10 metrics** (`_lib/observability/kromgo/config/config.yaml`)
  and renders the public README badges (`_docs/decisions/readme-live-cluster-stats.md`).

- **Renovate already bumps `kubernetes_version`** in
  `_infra/modules/talos-pve/variables.tf` (default `v1.36.0`) as PRs.

- **Gap:** there is **no Tailscale Connector / subnet router** (grep confirms). The API
  Server Proxy proxies only the **k8s API** — it does **not** expose the **Talos API
  (`:50000`)** on the node IPs. Use Case C (`talosctl`) therefore needs a new Connector.

The action docs: <https://tailscale.com/docs/integrations/github/github-action>.

---

## Integration design (shared foundation)

All three use cases share this foundation. Locked choices first:

- **Auth: OIDC federated identity** (Workload Identity Federation) — GitHub's OIDC JWT is
  exchanged for an ephemeral tailnet node. **No long-lived Tailscale secret stored
  anywhere.** Requires Tailscale ≥ 1.90.1 (operator is 1.98.3 ✓) and action `@v4` with
  `id-token: write`.
- **Secrets: 1Password service account.** A single GitHub secret,
  `OP_SERVICE_ACCOUNT_TOKEN`, lets `1password/load-secrets-action` pull everything else
  (SOPS age key, `memphis-talosconfig`, Connect token) from `op://` references at runtime —
  matching the repo's 1Password-everywhere pattern.

### Connect step (every workflow)

```yaml
permissions:
  id-token: write          # required for OIDC
  contents: read
steps:
  - uses: tailscale/github-action@v4   # pin to a release SHA in practice
    with:
      oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      audience: ${{ secrets.TS_AUDIENCE }}
      tags: tag:ci
      # version: 1.98.3   # optional pin to match the operator
  - uses: 1password/load-secrets-action@v2
    env:
      OP_SERVICE_ACCOUNT_TOKEN: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
```

The action creates a **tag:ci ephemeral node**, applies that tag's ACL grants, and
**auto-cleans up** when the job ends.

### Tailnet setup (Tailscale admin — not currently in this repo)

- Create tag **`tag:ci`**.
- Create a **federated-identity client** with the `auth_keys` scope that owns `tag:ci`;
  note its **audience** value. (Client ID + audience are non-secret but stored as GitHub
  secrets for tidiness.)
- ACL **grants**:
  - `tag:ci → tag:k8s` — reach the API Server Proxy (UC A/B). Impersonation maps the node
    to a Kubernetes group; bind that group to a **read-only** `ClusterRole` for UC B.
  - `tag:ci → <talos-node-CIDR>:50000` — reach the Talos API (UC C only; needs the Connector).

### Cluster reach summary

| Use case | Target | Path | New infra? |
| --- | --- | --- | --- |
| A — validate | k8s API | API Server Proxy (live) | No |
| B — report | k8s API / kromgo / Prometheus | API Server Proxy (live) | No |
| C — upgrade | **Talos API :50000** | **new Connector / subnet router** | **Yes** |

Runner: GitHub-hosted `ubuntu-latest` (image ≥ 2.237.1 for Node 24). The action installs
the Tailscale client itself.

---

## Use Case A — Validate config changes (PR gate)

**Trigger:** PR to `dev` touching `_lib/**`, `_clusters/**`, `_global/**`.

Two tiers:

1. **Offline (no tailnet):** `yamllint` (reuse the repo's `/lint` config), then
   `kubectl kustomize <dir>` render piped to **`kubeconform`** for schema validation.
   Note: Flux `postBuild.substituteFrom` `${...}` vars are **not** expanded offline
   (per `.claude/rules/kustomize.md`) — that's expected, validate structure not values.
2. **Server-side (Tailscale-gated):** connect, then `kubectl apply --dry-run=server` /
   `flux diff kustomization <name>` against the live cluster via the API Server Proxy to
   catch admission/CRD drift a local render can't.

**Pros**
- Catches broken kustomizations, schema errors, and (tier 2) live admission/CRD drift
  before merge.
- Tier 1 needs no tailnet, no secrets — fast, always-on.

**Cons**
- Tier 2 needs Tailscale + cluster reach and a scoped SA.
- Offline render leaves `${...}` placeholders — don't mistake them for failures.

**Recommendation:** ship tier 1 first; add the tier-2 `flux diff` job once `tag:ci` RBAC
is scoped.

---

## Use Case B — Report cluster state / metrics

**Trigger:** schedule (cron) and/or PR.

Connect via Tailscale → query the k8s API (API Server Proxy) / kromgo / Prometheus →
emit a `$GITHUB_STEP_SUMMARY` table (and optionally a PR comment): Flux + HelmRelease
readiness, failing/pending pods, version drift, cert expiry, firing alert count.

**Pros**
- Richer and **private** vs the public kromgo badges; lands context directly in the PR/run.
- Could let us **drop the public `dev-kromgo` endpoint** entirely — ties to Option C in
  `_docs/decisions/readme-live-cluster-stats.md` (query over Tailscale instead of exposing it).

**Cons**
- PR-comment churn if attached to every PR (prefer a single updated comment or job summary).
- Read-only impersonation RBAC for `tag:ci` must be scoped deliberately.
- Another scheduled job to maintain.

**Recommendation:** start as a scheduled job writing a job summary; consider it the
private successor to public kromgo if we later want stats off the public internet.

---

## Use Case C — Talos-native Kubernetes upgrade (dry-run PR → apply on merge)

Uses `talosctl upgrade-k8s`
(<https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes>),
**not** terraform, per the chosen flow.

**Flow**

1. Renovate bumps `kubernetes_version` in `_infra/modules/talos-pve/variables.tf` → opens a PR.
2. **PR job (dry-run):** load `memphis-talosconfig` from 1Password, Tailscale up (with the
   Connector advertising the node CIDR), run
   `talosctl --talosconfig … upgrade-k8s --dry-run --to <ver>`, post the output to the PR.
3. **On merge to `dev`:** a job runs `talosctl upgrade-k8s --to <ver>` for real.

**Pros**
- Matches the requested dry-run-then-merge model; talosconfig stays in 1Password, never on disk.
- The same var-bump PR keeps terraform's authoritative `talos_cluster.kubernetes_version`
  **in sync** — the next *manual* `terraform apply` is a no-op, not a revert.
- Talos **OS** upgrades remain terraform-managed (`talos_machine.image`); only the k8s
  component version is driven here.

**Cons / prerequisites**
- **Needs a new Tailscale Connector** advertising the Talos node CIDR to `tag:ci`
  (net-new manifest + ACL grant) — the API Server Proxy does not expose `:50000`.
- **Two actors can set the k8s version** (CI `talosctl` + terraform's var). They converge
  only because the merged var bump is the single source of truth — this coupling must be
  documented and respected (don't run `talosctl upgrade-k8s` to a version the var doesn't reflect).
- Apply-on-merge grants CI **mutate authority** over the cluster — higher blast radius than
  A/B. Consider a `workflow_dispatch` manual gate instead of auto-apply on merge.

**Recommendation:** adopt last, after the Connector lands and the ACL policy decision is made.

---

## Recommendation

Adopt the **OIDC + 1Password foundation**, then sequence by risk:

1. **Use Case A** (offline tier) — lowest risk, needs no new infra.
2. **Use Case A** tier 2 + **Use Case B** — once `tag:ci` RBAC is scoped on the API Server Proxy.
3. **Use Case C** — after the **Connector** is added and the tailnet-ACL management
   question is resolved; prefer a manual apply gate over auto-apply on merge initially.

## Open questions

1. **Tailnet ACL/policy management:** codify the tailnet policy file in-repo (GitOps via
   `tailscale/gitops-acls`) so `tag:ci` + grants are reviewed in Git, or keep managing ACLs
   manually in the admin console? (Affects all three use cases.)
2. **UC-C Talos API reach:** add a Tailscale **Connector** advertising the Talos node CIDR
   to `tag:ci`, join nodes to the tailnet directly, or run `talosctl` from an **in-cluster
   Job** triggered by CI (keeps the Talos API off the tailnet entirely)?
3. **Repo slug:** Renovate references `alexrf45/th0th` but the local dir is `h0me` — confirm
   the GitHub repo used for OIDC trust and workflow paths.
4. **Branch / trigger model:** PRs target `dev`; confirm **merge-to-`dev`** is the UC-C apply
   trigger, or prefer a `workflow_dispatch` manual gate.
5. **UC-C authority:** auto-apply on merge vs manual `workflow_dispatch` approval for the
   real `talosctl upgrade-k8s` run?
