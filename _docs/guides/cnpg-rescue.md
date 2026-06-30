# Guide — CNPG Database Rescue

Focused recovery procedures for the single-instance CloudNativePG (CNPG)
Postgres clusters in the `memphis` (dev) cluster. This is the runbook referenced
from each app's `overlays/dev/database.yaml`. For the full multi-scenario
disaster-recovery playbook (cluster loss, ZFS-level recovery, bare-metal
rebuild) see [`_docs/runbooks/disaster-recovery.md`](../runbooks/disaster-recovery.md).

All cluster access goes through the `kube` / `k8sop` wrappers — **never** raw
`kubectl`/`flux`/`helm` (kubeconfig lives in 1Password). In a non-interactive
shell, source the wrapper first:

```sh
source ~/.zsh/kubeop.sh
```

---

## 1. The data, and the two backups

Each app (`freshrss`, `authentik`, `gatus`) runs one CNPG cluster named
`<app>-dev-cluster`, single instance, on a **static** iSCSI PV.

| App | Cluster | DB | Data PV / zvol | Creds secret | Dump prefix |
| --- | --- | --- | --- | --- | --- |
| freshrss | `freshrss-dev-cluster` | `freshrss` | `dev-freshrss-db-pv` / `dev-freshrss-db` | `freshrss-db-creds` | `freshrss-` |
| authentik | `authentik-dev-cluster` | `authentik` | `dev-authentik-db-pv` / `dev-authentik-db` | `authentik-env` | `authentik-` |
| gatus | `gatus-dev-cluster` | `gatus` | `dev-gatus-db-pv` / `dev-gatus-db` | `gatus-db-creds` | `gatus-` |

zvols live under `home-share/iscsi/k8s/dev/volumes` on TrueNAS
(`192.168.20.106:3260`). Every data PV is `Retain` — deleting the PVC never
drops the zvol.

There are **two independent backups** per cluster:

1. **Physical — CSI VolumeSnapshot** (`ScheduledBackup`, method `volumeSnapshot`,
   class `freenas-iscsi`, daily ~04:00–05:00 UTC). Each snapshot is a TrueNAS
   ZFS snapshot of the data zvol. `deletionPolicy: Retain` — deleting the
   `VolumeSnapshot` object keeps the ZFS snapshot; TrueNAS owns retention.
   Fast, full-cluster, byte-identical recovery.
2. **Logical — `pg_dump` rip cord** (CronJob `<app>-cnpg-dump`, daily 03:00 UTC).
   Writes `<prefix><timestamp>.dump` (custom format, last 14 retained) to a
   separate PVC `dev-<app>-dumps-pvc` (20Gi). Survives corruption of the
   snapshot stack or the data zvol itself; portable across PG majors.

> **Pick physical first** for speed/fidelity. Fall back to the logical dump when
> the snapshot is missing, not `readyToUse`, or the zvol/CSI stack is suspect.

---

## 2. Check what you have (read-only)

```sh
# One-shot health of every backup (snapshots + dumps), freshness-checked:
_hack/scripts/dr_orchestrator.py verify

# Or by hand, for one app (freshrss shown):
kube dev -n freshrss get cluster freshrss-dev-cluster
kube dev -n freshrss get backups.postgresql.cnpg.io
kube dev -n freshrss get volumesnapshot
kube dev -n freshrss describe volumesnapshot <name> | grep -E 'ReadyToUse|RestoreSize|Creation'
```

List the logical dumps (mount the dumps PVC read-only in a throwaway pod):

```sh
_hack/scripts/dr_orchestrator.py list-backups freshrss
```

A snapshot is restorable only when `READYTOUSE` is `true`. A dump is valid when
it is recent and clearly larger than 1 KiB (the CronJob aborts on tiny dumps).

---

## 3. Recovery path A — physical, from a VolumeSnapshot

CNPG recovers by bootstrapping a **new** Cluster whose PVC is cloned from the
snapshot's `dataSource` (CSI makes a fresh zvol). This deliberately does **not**
reuse the static `dev-<app>-db-pv` — see the caveat below.

### Dry-run the plan (prints the manifest, changes nothing)

```sh
_hack/scripts/dr_orchestrator.py restore-snapshot freshrss
```

### Execute

```sh
_hack/scripts/dr_orchestrator.py restore-snapshot freshrss --execute
```

Equivalent by hand — apply a recovery Cluster (latest ready snapshot name from
step 2):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: freshrss-dev-cluster-restore
  namespace: freshrss
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:17.4-6
  superuserSecret:
    name: freshrss-db-creds
  storage:
    size: 10Gi
    storageClass: iscsi
    # No volumeName — recovery clones a NEW PVC from the snapshot.
  bootstrap:
    recovery:
      volumeSnapshots:
        storage:
          name: <SNAPSHOT_NAME>
          kind: VolumeSnapshot
          apiGroup: snapshot.storage.k8s.io
```

```sh
kube dev apply -f restore.yaml
kube dev -n freshrss get cluster freshrss-dev-cluster-restore -w
```

Validate, then cut over (see step 5).

> **Static-PV caveat.** The live cluster pins its PVC to `dev-<app>-db-pv` via
> `pvcTemplate.volumeName`. Snapshot recovery provisions a *different*,
> dynamically-named zvol. If you must preserve the original static identity,
> use the **TrueNAS ZFS-rollback** path in the DR playbook instead of CNPG
> recovery.

---

## 4. Recovery path B — logical, from a `pg_dump`

Use when no usable snapshot exists, or to restore a single DB into an
already-running cluster. `pg_restore --clean --if-exists` drops and recreates
objects in the target DB, so the cluster must be up and idle.

### Dry-run

```sh
_hack/scripts/dr_orchestrator.py restore-dump freshrss          # latest dump
_hack/scripts/dr_orchestrator.py restore-dump freshrss --dump freshrss-20260625T030000Z.dump
```

### Execute

```sh
_hack/scripts/dr_orchestrator.py restore-dump freshrss --execute
```

By hand — run `pg_restore` from a throwaway pod that mounts the dumps PVC and
reads creds from the app secret:

```sh
kube dev -n freshrss run dr-restore --rm -i --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:17.4-6 \
  --overrides='{"spec":{"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"dev-freshrss-dumps-pvc","readOnly":true}}],"containers":[{"name":"r","image":"ghcr.io/cloudnative-pg/postgresql:17.4-6","volumeMounts":[{"name":"b","mountPath":"/backup","readOnly":true}],"env":[{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"freshrss-db-creds","key":"password"}}}],"command":["bash","-c","pg_restore --clean --if-exists --no-owner --no-acl --host=freshrss-dev-cluster-rw --username=freshrss --dbname=freshrss /backup/<DUMP>"]}]}}' \
  --command -- true
```

If you instead need a brand-new empty cluster to restore into, apply the normal
`database.yaml` (it `initdb`s an empty DB on the static PV), wait for Ready,
then run the `pg_restore` above against it.

---

## 5. Validate and cut over

After either path, before sending traffic:

```sh
# Cluster healthy, 1/1, primary elected:
kube dev -n freshrss get cluster <cluster> -o wide
k8sop dev kubectl-cnpg status <cluster> -n freshrss

# Sanity-check row counts against what you expect:
kube dev -n freshrss exec -it <cluster>-1 -- psql -U freshrss -d freshrss \
  -c '\dt' -c 'SELECT count(*) FROM <a_known_table>;'
```

Cut over options:

- **Restored into the same cluster name** (path B into the live cluster): the
  app's `-rw` Service already points at it — nothing to change.
- **New `-restore` cluster** (path A): repoint the app, or — once validated —
  delete the broken cluster and rename/recreate the good one under the original
  name. Coordinate with Flux: the cluster is GitOps-managed, so reconcile or
  suspend the `applications` kustomization while you operate manually
  (`k8sop dev flux suspend kustomization applications`, resume after).

---

## 6. Notes & gotchas

- **GitOps drift.** These clusters are reconciled by Flux from
  `_lib/applications/<app>/overlays/dev`. Manual `apply`/`delete` will be
  reverted on the next reconcile. Suspend the `applications` kustomization
  during a manual rescue, and fold any permanent change back into Git.
- **`--with-source` breaks through the wrapper** (single-use kubeconfig pipe) —
  reconcile source and kustomization in two separate `k8sop` calls.
- **RWO dumps PVC** is normally unmounted (the CronJob only mounts it while
  running), so the probe/restore pods can attach it. If a dump Job is mid-run,
  wait for it.
- **Log every rescue** under `_docs/post-mortems/` per the post-mortem
  convention.
