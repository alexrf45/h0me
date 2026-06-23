# Migration: `talos-pve` → siderolabs/talos `0.12.0-alpha.4`

Date: 2026-06-22 · Module: `_infra/modules/talos-pve` · Root: `_infra/memphis`
Current provider: `0.11.0` → Target: `0.12.0-alpha.4` (pre-release, exact pin)

## Context

The 0.12 line adds two resources — **`talos_machine`** and **`talos_cluster`** —
that replace the classic `talos_machine_configuration_apply` + `talos_machine_bootstrap`
flow and **internalize bootstrap/health sequencing**. Adopting them lets us delete
the two fixed `time_sleep` waits that are the root cause of the recurring
worker-label `Node not found` failure, add proper HA etcd health gating, get
in-place Talos OS upgrades (Renovate-bumpable) with drift detection, and graceful
etcd-leave on destroy (fixes the README scale-down caveat). Decision: **full
adoption** (per session approval). All schema below is from the verbatim
`v0.12.0-alpha.4` provider docs, not cached syntax.

## Target resource wiring

```
talos_machine_secrets.this                          # unchanged
        │ machine_secrets / client_configuration
        ▼
data.talos_machine_configuration.{controlplane,worker}   # per-node (for_each)
        │  ← per-node hostname + allow_scheduling patches MOVE HERE
        ▼
talos_machine.{controlplane,worker}                 # NEW (replaces _configuration_apply)
        │  image = installer URL  → in-place OS upgrades + drift detection
        │  drain_on_upgrade = true, kubeconfig_wo = ephemeral kubeconfig
        ▼
talos_cluster.this                                  # NEW (replaces _machine_bootstrap)
        │  node = CP[0].ip, control_plane_nodes = [all CP ips]
        │  kubernetes_version drives k8s upgrades; waits for Talos-layer health
        ▼
talos_cluster_kubeconfig.this (managed resource, schema UNCHANGED)
        │  kubeconfig_raw + kubernetes_client_configuration{host,ca,cert,key}
        ▼
config-export.tf (1Password) + root kubernetes/flux provider wiring  # unchanged
```

Plus one new helper, used **only** to feed the drain step without a dependency cycle:

```hcl
ephemeral "talos_cluster_kubeconfig" "this" {
  cluster_name    = var.talos.name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = "https://${var.talos.endpoint}:6443"
}
```

## Key schema facts driving the refactor

1. **`talos_machine` has NO `config_patches` arg** (only `machine_configuration`).
   The hostname (`HostnameConfig`) and `allowSchedulingOnControlPlanes` patches
   currently in `talos_machine_configuration_apply.*` (`talos.tf:174-186,208-216`)
   must move into the matching `data.talos_machine_configuration.*.config_patches`
   — which is already `for_each` per node, so `random_id.this[each.key]` hostnames
   still render per-node.
2. **`talos_machine.image`** (installer URL) makes the resource manage OS version:
   on refresh it reads the running Talos version + `machine_configuration_hash` and
   reconciles drift / upgrades in place via `talosctl upgrade` — decoupled from the
   Proxmox VM disk (boot media only). Renovate can bump the installer tag.
3. **`drain_on_upgrade` defaults `true`** and needs a kubeconfig when `image` is set.
   Supplying `talos_cluster_kubeconfig.this.kubeconfig_raw` would create a cycle
   (kubeconfig→cluster→machine). Use the **ephemeral** `talos_cluster_kubeconfig`
   (`kubeconfig_wo = ephemeral...kubeconfig_raw`) — it derives from `machine_secrets`
   only, no running-cluster dependency. Drain only fires on upgrades, not create.
4. **`talos_cluster` completes on Talos-layer health only** ("does not wait for
   Kubernetes components"). That's sufficient for kubeconfig export (API up). It does
   NOT guarantee worker Node registration — which is fine because worker labels move
   to Kyverno (Goal 2B), so the module no longer needs to wait for workers at all.
5. **`talos_cluster.kubernetes_version`** is authoritative for k8s upgrades and must
   be `v`-prefixed (`v1.35.0`). Current `cilium_config.kube_version = "1.35.0"` lacks
   the `v`. Use `local.kubernetes_version = "v${trimprefix(var.cilium_config.kube_version, "v")}"`
   (interim; see cleanup note). Two-step k8s upgrades per provider docs.
6. **`on_destroy { reset = true, graceful = true }`** on `talos_machine` gives a
   graceful etcd leave on node removal — fixes the README "scale-down not reflected
   in k8s" known issue. NB: changes to `on_destroy` require an `apply` before the
   `destroy` takes effect (provider-framework limitation).

## File-by-file changes (`_infra/modules/talos-pve`)

| File | Change |
|------|--------|
| `terraform.tf` | `talos` `0.11.0` → `0.12.0-alpha.4`; `required_version` `>= 1.10.0` → `>= 1.11.0` (write-only args). |
| `talos.tf` | Move hostname/`allow_scheduling` patches into `data.talos_machine_configuration.{controlplane,worker}.config_patches`. Replace `talos_machine_configuration_apply.{controlplane,worker}` with `talos_machine.{controlplane,worker}` (add `image`, `endpoint`, `drain_on_upgrade`, `kubeconfig_wo`, `on_destroy`, keep `replace_triggered_by` on the PVE VM). Replace `talos_machine_bootstrap.this` with `talos_cluster.this` (`node`, `control_plane_nodes`, `kubernetes_version`, depends_on machines). **Delete** `time_sleep.wait_until_apply` and `time_sleep.wait_until_bootstrap`. Add `ephemeral "talos_cluster_kubeconfig" "this"`. Point `talos_cluster_kubeconfig.this.depends_on` at `talos_cluster.this`. |
| `worker-labels.tf` | **Delete** (labels → Kyverno, Goal 2B). |
| `locals.tf` | Add `kubernetes_version`. Drop `worker_node_names` if no longer referenced after labels removal. |
| `outputs.tf` | `machineconfig` → `values(data.talos_machine_configuration.controlplane)[0].machine_configuration`. Fix stale "v3.1.0" strings. Drop/keep `worker_node_names` output (informational). Update post-deploy banner (remove worker-label + bootstrap_cluster lines). |
| `variables.tf` | Remove/deprecate `bootstrap_cluster` (talos_cluster handles "already bootstrapped" idempotently). Remove `worker_labels` (moved to Kyverno). **DONE:** `kubernetes_version` promoted to a **standalone** top-level variable (not nested in `talos`), default `v1.36.0`, `^v\d+\.\d+\.\d+$` validation, Renovate annotation. `kube_version` removed from the `cilium_config` object (type + default) in module **and** root `_infra/memphis/variables.tf`. Consumers (`talos.tf` x2, `cilium_config.tf`) use `trimprefix(var.kubernetes_version, "v")` to keep the bare form they require. |
| `config-export.tf` | No schema change; still reads `talos_cluster_kubeconfig.this.kubeconfig_raw` + `data.talos_client_configuration.this.talos_config`. |
| `README.md` | Update provider table (talos 0.12.0-alpha.4), drop `bootstrap_cluster`/worker-label day-2 notes, document in-place OS upgrade via `image` + graceful destroy. |

### Root `_infra/memphis`
- `terraform.tf`: bump `talos` to `0.12.0-alpha.4`, `required_version >= 1.11.0`.
- `main.tf` / `variables.tf`: drop `bootstrap_cluster` plumbing; remove `worker_labels` passthrough. Flux/kubernetes provider wiring (`providers.tf`) unchanged — it still consumes `module.dev.kubernetes_*` from the kubeconfig resource.
- `.terraform.lock.hcl`: re-locked on `terraform init -upgrade` (provider hashes for the prerelease).

## Renovate hook (sets up Goal 4C later)
Add a custom manager to bump the Talos installer/version so OS upgrades flow as PRs:
track `var.talos.version` (or the `image` tag) against the `ghcr.io/siderolabs/installer`
datasource. Keep the value in a **plaintext** default/local (Renovate can't edit SOPS tfvars).

## Cutover / state strategy
`talos_machine_configuration_apply` → `talos_machine` and `talos_machine_bootstrap`
→ `talos_cluster` are **type changes** (no `moved` block across types). On the
rebuildable dev/staging (`memphis`) cluster — risk accepted — do a clean cutover:
1. `terraform plan` to review (expect destroy of old talos_* apply/bootstrap, create of new).
2. Because `talos_machine_secrets` is preserved, etcd PKI is stable; the new
   `talos_machine` re-applies identical config (hash match → minimal churn) and
   `talos_cluster` sees an already-bootstrapped cluster.
3. If plan shows secret regeneration or VM replacement, treat as a full rebuild
   (acceptable here) and re-bootstrap from scratch.

## Verification
- `terraform -chdir=_infra/memphis init -upgrade` resolves `0.12.0-alpha.4`; `terraform validate` passes; `terraform fmt -check`.
- `terraform -chdir=_infra/memphis plan` (via 1Password CLI, user-run) shows the
  expected swap and **no** `time_sleep` resources.
- After apply: `kube dev get nodes` all Ready; `kube dev get nodes -o wide` hostnames match `${env}-${name}-{cp,node}-${hex}`.
- Kubeconfig/talosconfig still land in 1Password (`<cluster>-kubeconfig`, `-talosconfig`).
- OS-upgrade smoke test (later): bump installer tag, `apply`, confirm in-place `talosctl upgrade` with drain (no VM rebuild).
- Re-run `apply` with no changes → **clean plan** (this is the regression that proves the worker-label failure is gone).

## Implementation status (2026-06-22)
**DONE** — `talos.tf` refactored to `talos_machine` + `talos_cluster` + ephemeral `talos_cluster_kubeconfig`; hostname/`allow_scheduling` patches moved into the `data.talos_machine_configuration.*` `config_patches`; `time_sleep` waits, `talos_machine_configuration_apply.*`, `talos_machine_bootstrap`, and `worker-labels.tf` deleted; `terraform.tf` bumped to talos `0.12.0-alpha.4` / TF `>= 1.11.0` and `hashicorp/time` dropped (module + root `terraform.tf`); `bootstrap_cluster` + `worker_labels` removed from module **and** root `variables.tf`/`main.tf`; `outputs.tf` `machineconfig` repointed at the data source, banner refreshed; README + both `.tfvars.example` updated.

**NOT run by me** (the `terraform` wrapper needs interactive 1Password): `init -upgrade`, `validate`, `fmt`, `plan`. Run these before applying.

**Required manual edits to user-managed secrets** (`_infra/memphis/tfvars.enc` and your gitignored local `terraform.tfvars`):
- Remove `kube_version` from the `cilium_config` block → otherwise `plan` errors *"Unsupported attribute"*.
- Remove `bootstrap_cluster` and the `worker_labels` block → now undeclared (warning, not fatal, but clean them up).
- Note: effective k8s version is now the **module default `v1.36.0`** (no root passthrough). Your local tfvars had `kube_version = "1.36.1"`; it is superseded. To pin a different version, change the module `variables.tf` default (also where Renovate bumps it).

## Sequencing
1. ~~**This migration (priority).**~~ **DONE.** 2. Kyverno worker labels (Goal 2B) — now unblocked (`worker-labels.tf` deleted; nodes have no role label until the policy lands). 3. flux-operator (3C). 4. Cilium 4C→4A.

## Open items to confirm during implementation
- ~~Promote `kubernetes_version` into the `talos` var object now, or keep the interim `local`?~~ **RESOLVED:** made a standalone top-level `kubernetes_version` variable (default `v1.36.0`) so Renovate can bump it directly; `kube_version` dropped from `cilium_config`. **User action required:** remove `kube_version` from the SOPS-encrypted `cilium_config` block in `_infra/memphis/tfvars.enc` — otherwise `plan` errors with "Unsupported attribute". The module default supplies the version (no root passthrough), keeping it out of SOPS.
- Renovate: the bare `renovate.json` is a stub; real config is inline in `_lib/controllers/renovate/helmrelease.yaml`. It ignored all `.tf`. Opened `includePaths` for just `_infra/modules/talos-pve/variables.tf`, dropped the blanket `**/*.tf` ignore (other `.tf` stay out via `includePaths` gating; `**/terraform/**`, `*.tfvars`, state remain ignored), added a `customManagers` regex bound to that file.
- **k8s 1.36 risk:** the `0.11.0` provider bundles a Talos SDK tracking Talos 1.14 / k8s ~1.35. `v1.36.0` may be ahead of the bundled validator — if `plan`/`apply` rejects it, roll the variable default back to `v1.35.0` (per session decision).
- `_infra/modules/talos-pve-v3.1.0` is unused and marked for deletion (see its `DEPRECATED.md`).
