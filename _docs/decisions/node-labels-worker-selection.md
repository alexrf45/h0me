# Decision: where to apply the `node=worker` node label

Date: 2026-06-23 · Status: accepted — Option 1 implemented in `_infra/modules/talos-pve/talos.tf` (worker `machine.nodeLabels`), pending verification on next teardown/rebuild
Context owner: cluster bootstrap (`_infra/modules/talos-pve`) + Flux scheduling

## Problem

Every workload in `_lib` schedules with `nodeSelector: node=worker` (cnpg,
authentik, cert-manager, external-secrets, onepassword, cloudflared, and the
freshrss/authentik/gatus dump cronjobs). The label was applied by
`_infra/modules/talos-pve/worker-labels.tf` — a `kubernetes_labels` resource that
patched `var.worker_labels.labels` onto each worker Node post-bootstrap.

The Talos `0.12.0-alpha.4` refactor **deleted** `worker-labels.tf` (it depended on
the removed `talos_machine_configuration_apply.worker` + `time_sleep`). Nodes now
register **unlabeled**, so `node=worker` matches nothing → CNPG stays Pending →
gates authentik, freshrss, etc.

## Constraints discovered (read from config, not assumed)

- `allowSchedulingOnControlPlanes` default = `false` → Talos taints control-plane
  nodes `NoSchedule`. **Untolerated pods already cannot land on control planes.**
  The `node=worker` selector is therefore redundant *for the "keep off CP" goal* —
  the taint already enforces it. It only adds value as a *positive* pin if/when a
  third node class exists (storage, GPU).
- Worker MachineConfig already has a `machine:` block (label injection point).

## Best-practice principle

Node **identity / role / topology** labels are the node provisioner's
responsibility and must exist **at registration**, before the kubelet advertises
the node as schedulable. Anything that gates scheduling on a label that is applied
*after* the node is Ready is a race by construction. With Talos, the provisioner
hook is `machine.nodeLabels`.

### Why NOT Kyverno (rejected)

- Kyverno runs in the `controllers` Flux layer — it does not exist until after the
  CNI and nodes are up. Its mutating webhook fires only on Node **admission**
  (create/update); already-joined nodes emit no update, so they are silently
  missed — a permanent race, not just at startup.
- Layering inversion: the mechanism that makes nodes *selectable* must not itself
  depend on being *scheduled onto* those nodes.
- Kyverno's domain is **workload** mutation/validation, not **node** bootstrap
  identity.

## Options

### Option 1 — Talos `machine.nodeLabels` (RECOMMENDED)
Add to the worker `machine:` block:
```yaml
machine:
  nodeLabels:
    node: worker
```
- **+** Applied by Talos at registration → exists before any pod schedules → no
  Flux ordering concern at all.
- **+** Zero workload edits — every existing `nodeSelector: node=worker` keeps
  working.
- **+** Declarative in the same Terraform that builds the node; no post-apply
  patch, no running-cluster dependency (the thing the 0.12 refactor removed).
- **+** Survives clean-slate rebuilds.
- **−** A Talos config change → next `terraform apply` re-renders + applies worker
  config. A bare label change applies live (no reboot/drain).
- **−** Bare key `node` (no `kubernetes.io` domain) is permitted by NodeRestriction;
  do not switch to a reserved-prefix key without revisiting this.

### Option 2 — Drop the selector; rely on the CP taint
Remove `nodeSelector: node=worker` from every workload. Untolerated pods land only
on workers automatically (CP is `NoSchedule`).
- **+** Fewest moving parts; no node labels to manage; matches the "label may not
  be needed" intuition.
- **−** ~8-file diff across `_lib`.
- **−** Loses the positive pin — if a third node class is added later, selectors
  must come back.
- **−** Any workload that *does* tolerate CP would be free to land there.

### Option 3 — Restore `worker-labels.tf`, rewired to 0.12
Recreate the `kubernetes_labels` resource with `depends_on = [talos_machine.worker]`.
- **−** Post-bootstrap patch: a window where nodes are Ready-but-unlabeled remains,
  so a fast Flux reconcile can still try to schedule before the label lands.
- **−** Re-introduces the running-cluster dependency the refactor deliberately
  removed. Strictly inferior to Option 1.

## Recommendation

**Option 1** as the immediate, race-free fix (no workload churn, label at its
correct source of truth). Optionally follow later with **Option 2** as a deliberate
cleanup if shedding the custom label is desired. Avoid Option 3 and Kyverno.

## Immediate unblock (manual, until rebuild)
```
kube dev label node <worker-1> <worker-2> ... node=worker
```

## If Option 1 is chosen — implementation
- Add `machine.nodeLabels: {node: worker}` to the worker config in
  `_infra/modules/talos-pve/talos.tf` (worker `machine:` block) — or thread it
  through a `var.worker_labels` map for parity with the old interface.
- `terraform apply` (1Password wrapper, run by user) applies worker config live.
- Verify: `kube dev get nodes -l node=worker` lists all workers; CNPG cluster goes
  Ready; downstream apps ungate.
```
