# Runbook — Disaster Recovery (persistent storage)

How to recover all persistent data in the `memphis` (dev) cluster, from a single
corrupted database up to a full bare-metal rebuild. The goal is rehearsal: run
the dry-runs until recovery is muscle memory **before** this stack is promoted to
production.

Scope: persistent **data**. Stateless workloads come back on their own via Flux
(`_clusters/dev`). For app/DB-specific CNPG mechanics see the companion guide
[`_docs/guides/cnpg-rescue.md`](../guides/cnpg-rescue.md).

All cluster access goes through the `kube` / `k8sop` wrappers — **never** raw
`kubectl`/`flux`/`helm`. In a non-interactive shell:

```sh
source ~/.zsh/kubeop.sh
```

---

## 1. Where the data lives (composition)

| Data | Where it physically lives | Backup | Restore scenario |
| --- | --- | --- | --- |
| **CNPG Postgres** ×3 (freshrss, authentik, gatus) | TrueNAS zvols `dev-<app>-db` under `home-share/iscsi/k8s/dev/volumes`, surfaced as iSCSI extents → static PV `dev-<app>-db-pv` (10Gi, `Retain`) | Daily CSI VolumeSnapshot (ZFS snap) **+** daily `pg_dump` to `dev-<app>-dumps-pvc` | A, B, C |
| **`pg_dump` rip-cord files** | PVC `dev-<app>-dumps-pvc` (20Gi iSCSI, last 14 dumps) | the dumps *are* the backup; PVC `Retain` | B |
| **freshrss app data** | `freshrss-data` (`local-path`, node-local 5Gi) + small iSCSI PV `dev-freshrss-pv` (2Gi) | none dedicated — config is in Git; local-path is node-local & **not** snapshotted | D (rebuild from manifests) |
| **Observability** (Prometheus/Loki) | per-workload PVCs | none — treated as disposable/regenerable | D (accept data loss) |

Key properties baked into the design:

- **Everything that holds data is `Retain`.** Deleting a Kubernetes PVC,
  `VolumeSnapshot`, or PV never deletes the underlying TrueNAS zvol/snapshot.
  Reclaiming storage is always an explicit TrueNAS-side action.
- **Two independent DB backups** (physical ZFS snapshot + logical SQL dump) so a
  failure of the CSI/snapshot stack does not also destroy the only copy.
- **Static PVs** mean each DB's identity is a named, pre-created zvol you can
  snapshot, clone, or roll back directly on TrueNAS.

### Recovery objectives (set real targets before prod)

| | Current (dev) | Notes |
| --- | --- | --- |
| RPO | ≤ 24h | Both backups are daily. Tighten with WAL archiving (Barman Cloud / object store) before prod if < 24h loss is required. |
| RTO (single DB) | minutes | Snapshot recovery clones a zvol; dump restore is a `pg_restore`. |
| RTO (full cluster) | hours | Talos+Flux rebuild + re-attach zvols + recover DBs. |

---

## 2. The orchestrator (verify + guided restore)

`_hack/scripts/dr_orchestrator.py` is stdlib-only (no PyYAML) and drives all of
this through the `kube`/`k8sop` wrappers. **Safe by default**: `verify` is
read-only and restores require `--execute`.

```sh
# Health of every backup, freshness-checked (read-only):
_hack/scripts/dr_orchestrator.py verify
_hack/scripts/dr_orchestrator.py verify --app authentik

# Inspect what's available for one app:
_hack/scripts/dr_orchestrator.py list-backups freshrss

# Plan a restore (DRY-RUN — prints manifest/commands, mutates nothing):
_hack/scripts/dr_orchestrator.py restore-snapshot freshrss
_hack/scripts/dr_orchestrator.py restore-dump   freshrss

# Actually restore (prompts for confirmation; --yes to skip):
_hack/scripts/dr_orchestrator.py restore-snapshot freshrss --execute
_hack/scripts/dr_orchestrator.py restore-dump   freshrss --execute
```

Useful flags: `--env staging|prod`, `--kubeop <path>` (defaults
`~/.zsh/kubeop.sh`), `--no-inspect-dumps` (skip the throwaway probe pod that
lists dump files), `-v` (echo every wrapper command).

`verify` exits non-zero if any backup is missing, stale (snapshot > 30h or dump
> 30h old), not `readyToUse`, or suspiciously small — wire it into a periodic
check before prod.

---

## 3. Scenario A — CNPG recovery from a VolumeSnapshot (physical)

**Use when:** a single DB's data is corrupted but the snapshot stack and TrueNAS
are healthy. Fastest, byte-identical.

```sh
_hack/scripts/dr_orchestrator.py restore-snapshot <app>            # review plan
_hack/scripts/dr_orchestrator.py restore-snapshot <app> --execute  # apply
```

This bootstraps a new `<app>-dev-cluster-restore` Cluster whose PVC is **cloned
from the snapshot** (a fresh zvol). Validate, then cut over (§3 + §5 of the
[CNPG rescue guide](../guides/cnpg-rescue.md)).

Caveat: snapshot recovery does **not** reuse the static `dev-<app>-db-pv`. To
keep the original zvol identity, use Scenario C.

---

## 4. Scenario B — logical restore from a `pg_dump` (rip cord)

**Use when:** the snapshot is missing/`readyToUse=false`, the CSI stack is
suspect, or you need to restore into an existing cluster.

```sh
_hack/scripts/dr_orchestrator.py restore-dump <app>            # latest dump, dry-run
_hack/scripts/dr_orchestrator.py restore-dump <app> --dump <file> --execute
```

`pg_restore --clean --if-exists` rebuilds objects in the live DB. If you need a
clean target, apply the app's `database.yaml` (fresh `initdb` on the static PV),
wait for Ready, then restore into it. Full manual command in the
[CNPG rescue guide §4](../guides/cnpg-rescue.md).

---

## 5. Scenario C — TrueNAS ZFS-level recovery (zvol rollback/clone)

**Use when:** you must restore the **original** static zvol in place (preserving
`dev-<app>-db-pv` identity), or the Kubernetes/CSI layer can't broker the
restore. These steps run on **TrueNAS** (`192.168.20.106`), not via the
wrappers.

> ⚠️ A `zfs rollback` is destructive and discards everything written after the
> snapshot. Take a *fresh* snapshot first so you can undo the undo. Prefer
> **clone** over **rollback** when you want to keep the current state too.

1. **Quiesce the DB** so nothing writes the zvol while you operate:

   ```sh
   k8sop dev flux suspend kustomization applications
   kube dev -n <app> scale cluster <app>-dev-cluster --replicas=0   # or delete the cluster CR
   ```
   Confirm the iSCSI extent has no active sessions on the TrueNAS side.

2. **Snapshot-then-roll on TrueNAS** (CLI shown; the UI works too):

   ```sh
   # list snapshots of the zvol
   zfs list -t snapshot home-share/iscsi/k8s/dev/volumes/dev-<app>-db
   # safety snapshot of current state
   zfs snapshot home-share/iscsi/k8s/dev/volumes/dev-<app>-db@pre-rollback-$(date +%Y%m%d%H%M)
   # roll back to the chosen snapshot
   zfs rollback -r home-share/iscsi/k8s/dev/volumes/dev-<app>-db@<snapshot>
   ```

   *Non-destructive alternative* — clone to a new zvol and re-point a temporary
   PV at it for validation before committing:

   ```sh
   zfs clone home-share/iscsi/k8s/dev/volumes/dev-<app>-db@<snapshot> \
             home-share/iscsi/k8s/dev/volumes/dev-<app>-db-restore
   # create a new iSCSI target/extent for the clone, then a matching static PV.
   ```

3. **Re-present iSCSI** if the extent/target was recreated: ensure the extent
   maps the (rolled-back or cloned) zvol at the LUN/IQN the PV expects
   (`iqn.2005-10.org.freenas.ctl:dev-<app>-db`, LUN 0, portal
   `192.168.20.106:3260`). For an in-place rollback the existing target is
   unchanged — no remapping needed.

4. **Bring the DB back** and reconcile:

   ```sh
   kube dev -n <app> get pv dev-<app>-db-pv          # still Bound/Available, Retain
   k8sop dev flux resume kustomization applications   # recreates the cluster CR
   kube dev -n <app> get cluster <app>-dev-cluster -w
   ```

5. **Validate** (`kubectl-cnpg status`, row counts) per the rescue guide §5.

---

## 6. Scenario D — full cluster loss / bare-metal rebuild

**Use when:** the Kubernetes cluster is gone (lost nodes, trashed etcd, fresh
Talos install). The TrueNAS zvols survive independently, so the DBs are
recoverable as long as TrueNAS is intact.

**Order of operations:**

1. **Rebuild infra (Talos + Flux).** `_infra/memphis` provisions Talos on
   Proxmox and bootstraps the Flux Operator (`/terraform-plan` →
   `/terraform-apply`). Flux then reconciles `_clusters/dev` end-to-end
   (controllers → CNPG → storage → apps). See
   `_docs/migrations/flux-operator-and-cilium-handover.md`.

2. **Re-fetch cluster access:** `kube-flush` then verify
   `kube dev get nodes`.

3. **Let storage + CNPG operators come up**, but expect the app DBs to try to
   `initdb` fresh on their static PVs. The PVs are `Retain` and the zvols still
   hold data — you do **not** want a fresh `initdb` to land on top. Two options:

   - **Preferred — adopt existing zvols:** before the `applications` layer
     reconciles, suspend it (`k8sop dev flux suspend kustomization applications`).
     Confirm each static PV (`dev-<app>-db-pv`) re-binds to its zvol, then
     recover via Scenario A (snapshot) or C (in-place zvol) so the existing data
     is used rather than overwritten.
   - **Fallback — rebuild from dumps:** if the data zvol is unrecoverable, let
     the cluster `initdb` empty, then Scenario B (`restore-dump`) from the dumps
     PVC (which is itself a separate `Retain` zvol).

4. **Re-attach the dumps PVCs.** `dev-<app>-dumps-pvc` are `Retain`; their zvols
   persist. If their static binding doesn't reattach automatically, recreate the
   PVC/PV pair pointing at the surviving zvol before running `restore-dump`.

5. **Verify everything:** `_hack/scripts/dr_orchestrator.py verify` should go
   green across all apps. Then exercise each app's login/UI.

6. **Secrets & DNS** return automatically: 1Password → Connect → External
   Secrets Operator re-materialises secrets; ExternalDNS re-publishes records.
   Nothing to restore by hand unless 1Password itself was lost.

---

## 7. Pre-production rehearsal checklist

Run these until they're second nature. Tick on a fresh shell each time.

- [ ] `dr_orchestrator.py verify` is green for all three apps.
- [ ] For each app: `restore-snapshot --execute` into a `-restore` cluster,
      validate row counts, delete the `-restore` cluster. (Leaves prod data
      untouched; clones a throwaway zvol.)
- [ ] For each app: `restore-dump --execute` into a scratch cluster, validate.
- [ ] Scenario C on **one** app: clone (not rollback) a zvol, mount via a temp
      PV, confirm the DB starts and data matches.
- [ ] Scenario D table-top: confirm `_infra/memphis` plan is clean and you can
      articulate the adopt-zvols-vs-rebuild-from-dumps decision without notes.
- [ ] Confirm TrueNAS-side snapshot retention actually keeps ≥ N days (the CSI
      `Retain` policy relies on TrueNAS GC — verify it's configured).
- [ ] Time each path; record RTO against the targets in §1.
- [ ] File a post-mortem-style note of anything that surprised you under
      `_docs/post-mortems/`.

---

## 8. Known gaps to close before prod

- **RPO is 24h** (daily backups only). If lower loss is required, add WAL
  archiving to object storage (Barman Cloud) for point-in-time recovery.
- **No off-site copy.** Both DB backups live on the same TrueNAS box as the
  primary data — a TrueNAS loss takes everything. Add an off-box/off-site
  replication target (ZFS replication or object-store dump sync) before prod.
- **`local-path` freshrss data is node-local and unsnapshotted** — fine if it's
  truly regenerable from config; otherwise migrate it to iSCSI + snapshots.
- **Backup success isn't alerted.** Wire `dr_orchestrator.py verify` (or a
  CNPG/snapshot freshness alert) into monitoring so a silently-failing backup is
  caught before it's needed. Tracks with the M-OBS items in the production
  readiness checklist.
