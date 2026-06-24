# Runbook — Manual Cluster Intervention

Quick-reference commands for hands-on troubleshooting of the `memphis` (dev) cluster.
All cluster access goes through the `~/.zsh/kubeop.sh` wrappers — **never** raw
`kubectl`/`flux`/`helm` (the kubeconfig lives in 1Password and is injected by the
wrapper). In a non-interactive shell, source the wrapper first:

```sh
source ~/.zsh/kubeop.sh
```

Wrapper cheat sheet:

| Wrapper                     | Use for                                          |
| --------------------------- | ------------------------------------------------ |
| `kube [env] <args>`         | kubectl (env defaults to `dev`)                  |
| `k8sop <env> <tool> <args>` | flux, helm, stern, kubectl-cnpg, etc.            |
| `kube-flush`                | drop cached kubeconfig (after a cluster rebuild) |

> `flux ... --with-source` breaks through the wrapper (single-use kubeconfig pipe).
> Reconcile the source and the kustomization in two separate calls instead.

---

## Triage — where is it stuck?

```sh
# Flux layers: which kustomization is not Ready?
k8sop dev flux get kustomizations

# HelmReleases across all namespaces (READY + last message)
k8sop dev flux get hr -A

# Pods that are not healthy
kube dev get pods -A | grep -Ev "Running|Completed"

# PVCs that are not Bound
kube dev get pvc -A | grep -v Bound
```

A Flux kustomization stuck on `Reconciliation in progress` is almost always
waiting on a **child resource health check** (a HelmRelease or workload that
never goes Ready). Find the unhealthy child first — don't suspend/resume the
kustomization blindly.

---

## Storage — democratic-csi / iSCSI (TrueNAS)

### Symptom: `iscsi` PVCs stuck `Pending`

```sh
# Read the provisioning error off the PVC's events
kube dev -n <ns> describe pvc <pvc-name> | grep -A8 Events
```

Common provisioner errors and their meaning:

| Error in event | Root cause | Fix |
| -------------- | ---------- | --- |
| `iscsi_target_create.groups.0.initiator: "<N> Initiator not found in database"` | `targetGroupInitiatorGroup` in the CSI config points at a TrueNAS initiator group ID that doesn't exist | Set the correct ID in `_lib/storage/freenas-csi/external-secret.yaml`, commit, reconcile `storage`, **then restart the controller** (see below) |
| `dataset … does not exist` | parent dataset missing on TrueNAS | create the dataset manually on TrueNAS, spell out full path segments |

### The CSI controller caches its config at startup

The democratic-csi driver reads its config file **once at process start**. When
the config secret changes (e.g. the ExternalSecret re-renders after an edit),
the on-disk mount updates but the **running process keeps the old values**. You
must restart the controller for config changes to take effect:

```sh
# Confirm the live mounted config (prints only the matched line, no secrets)
POD=$(kube dev -n storage get pod -l app.kubernetes.io/component=controller -o name | head -1)
kube dev -n storage exec ${POD##*/} -c csi-driver -- \
  sh -c 'grep -i initiatorgroup /config/driver-config-file.yaml'

# Restart the controller so it re-reads the config
kube dev -n storage rollout restart deploy/storage-democratic-csi-freenas-controller
kube dev -n storage rollout status  deploy/storage-democratic-csi-freenas-controller --timeout=120s
```

After the new controller is up, the provisioner retries automatically within
~30s and Pending PVCs bind without recreation. Verify:

```sh
kube dev get pvc -A | grep -v Bound   # should print only the header
```

> Never read the full CSI config secret into the conversation — it contains the
> TrueNAS API key. Grep only the specific non-secret line you need from inside
> the pod, as above.

### Symptom: pod stuck `Init`/`ContainerCreating`, `FailedMount` iscsi login error 19

```sh
kube dev -n <ns> describe pod <pod> | grep -A12 Events:
# MountVolume.MountDevice failed ... iscsiadm: Could not login to target
# initiator reported error (19 - encountered non-retryable iSCSI login failure)
```

This is a **node-plugin login** failure (different stage from controller
provisioning). Error 19 means the TrueNAS target **rejected the node's
initiator** — almost always because the target's Group points at an initiator
group that doesn't include the worker-node IQNs (e.g. after the cluster-wide
initiator group ID was changed and a **static, manually-created** target was
left on the old group).

Tell: **dynamic** volumes (with the corrected initiator group) mount fine while
**static** targets fail. Fix is on TrueNAS, not in-cluster:

> **TrueNAS → Shares → iSCSI → Targets**, for each failing static target (e.g.
> `dev-gatus-db`, `dev-freshrss-pv`), set the Group's **Initiator Group** to the
> same valid group the dynamic volumes use. Then delete the stuck pod to retry:
> `kube dev -n <ns> delete pod <pod>`.

---

## HelmRelease stuck after a transient dependency failure

If a HelmRelease **install/upgrade timed out** while a dependency was broken
(e.g. PVCs couldn't bind), Flux rolls it back and — once `remediation.retries`
is exhausted — stops trying. Fixing the dependency does **not** auto-retry it.

```sh
k8sop dev flux get hr -A | grep -i <name>
# READY False  →  "Helm install failed ... timeout waiting for: ..."
```

Reset the failure counter and force a fresh attempt:

```sh
k8sop dev flux reconcile helmrelease <name> -n flux-system --reset
```

`--reset` clears the failed-retry state so Flux re-attempts the install/upgrade.
Watch it converge:

```sh
k8sop dev flux get hr -n flux-system <name>
kube dev -n <targetNamespace> get pods -w
```

Suspend/resume is the heavier-handed alternative and resets the same state:

```sh
k8sop dev flux suspend helmrelease <name> -n flux-system
k8sop dev flux resume  helmrelease <name> -n flux-system
```

---

## Reconciling Flux layers

```sh
# Pull latest git first, then reconcile a layer (two calls — wrapper limitation)
k8sop dev flux reconcile source git flux-system
k8sop dev flux reconcile kustomization <layer>      # e.g. storage, observability
```

Layer dependency order (each depends on the one above): `cluster-config` →
`crds` → `controllers` → `pki` → `external-secrets-operator` → `secrets` →
`networking` → `dns` → `storage` → `security` → `applications`.

---

## Clearing stale pods from a prior outage

Pods stuck `Init:0/1`, `CrashLoopBackOff`, or `Pending` from a window when a
dependency was down often need a delete to recreate cleanly once the underlying
issue is fixed:

```sh
kube dev -n <ns> delete pod <pod>             # one pod
kube dev -n <ns> rollout restart deploy/<name>  # or the whole workload
```
