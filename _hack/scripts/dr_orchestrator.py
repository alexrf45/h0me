#!/usr/bin/env python3
"""dr_orchestrator.py — disaster-recovery rehearsal & restore tool for h0me.

Verifies that every persistent-data backup in the dev (`memphis`) cluster is
present, fresh and restorable, and drives the two CNPG restore paths
(physical VolumeSnapshot recovery + logical pg_dump rip cord).

Design constraints (match the repo):
  * stdlib only — PyYAML is NOT installed; we parse `kubectl -o json`.
  * NEVER calls raw kubectl/flux. Every cluster call goes through the
    `kube` / `k8sop` shell wrappers, which are functions sourced from
    ~/.zsh/kubeop.sh (kubeconfig lives in 1Password). We re-source that file
    inside each subshell because subprocesses don't inherit shell functions.
  * SAFE BY DEFAULT — `verify` is read-only; restores require an explicit
    `--execute`. Without it every mutating command is only printed.

Usage:
  dr_orchestrator.py verify                 # health of all backups (read-only)
  dr_orchestrator.py verify --app freshrss
  dr_orchestrator.py list-backups freshrss  # snapshots + dumps for one app
  dr_orchestrator.py restore-snapshot freshrss            # dry-run plan
  dr_orchestrator.py restore-snapshot freshrss --execute  # actually recover
  dr_orchestrator.py restore-dump freshrss --dump <file>  # logical restore

Run `dr_orchestrator.py --help` for the full flag list.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

# --------------------------------------------------------------------------- #
# App registry — facts that DON'T live in the live cluster API.
# Cluster name / namespace are derived; zvol/iqn/dump metadata come from the
# static-PV + dump-cronjob manifests under _lib/applications/<app>/overlays/dev.
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class App:
    name: str
    db: str                 # logical database name (pg_dump target)
    creds_secret: str       # secret holding username/password keys
    zvol: str               # TrueNAS zvol backing the data PV
    iqn: str                # iSCSI target IQN for that zvol

    @property
    def namespace(self) -> str:
        return self.name

    def cluster(self, env: str) -> str:
        return f"{self.name}-{env}-cluster"

    def data_pv(self, env: str) -> str:
        return f"{env}-{self.name}-db-pv"

    def dumps_pvc(self, env: str) -> str:
        return f"{env}-{self.name}-dumps-pvc"

    def dump_prefix(self) -> str:
        return f"{self.name}-"


APPS: dict[str, App] = {
    "freshrss": App(
        name="freshrss", db="freshrss", creds_secret="freshrss-db-creds",
        zvol="dev-freshrss-db", iqn="iqn.2005-10.org.freenas.ctl:dev-freshrss-db",
    ),
    "authentik": App(
        name="authentik", db="authentik", creds_secret="authentik-env",
        zvol="dev-authentik-db", iqn="iqn.2005-10.org.freenas.ctl:dev-authentik-db",
    ),
    "gatus": App(
        name="gatus", db="gatus", creds_secret="gatus-db-creds",
        zvol="dev-gatus-db", iqn="iqn.2005-10.org.freenas.ctl:dev-gatus-db",
    ),
}

CNPG_IMAGE = "ghcr.io/cloudnative-pg/postgresql:17.4-6"
TRUENAS_PORTAL = "192.168.20.106:3260"

# Freshness thresholds (hours). A backup older than this is flagged STALE.
SNAPSHOT_MAX_AGE_H = 30   # daily ScheduledBackup runs ~04:00–05:00 UTC
DUMP_MAX_AGE_H = 30       # daily dump CronJob runs 03:00 UTC


# --------------------------------------------------------------------------- #
# Terminal helpers
# --------------------------------------------------------------------------- #
class C:
    G = "\033[32m"; Y = "\033[33m"; R = "\033[31m"; B = "\033[34m"
    BOLD = "\033[1m"; DIM = "\033[2m"; RESET = "\033[0m"

    @staticmethod
    def strip() -> None:
        for k in ("G", "Y", "R", "B", "BOLD", "DIM", "RESET"):
            setattr(C, k, "")


def ok(msg: str) -> str:    return f"{C.G}✔{C.RESET} {msg}"
def warn(msg: str) -> str:  return f"{C.Y}▲{C.RESET} {msg}"
def bad(msg: str) -> str:   return f"{C.R}✗{C.RESET} {msg}"
def info(msg: str) -> str:  return f"{C.B}ℹ{C.RESET} {msg}"


# --------------------------------------------------------------------------- #
# Wrapper plumbing — run kube/k8sop through a shell that sources kubeop.sh
# --------------------------------------------------------------------------- #
class Cluster:
    def __init__(self, env: str, kubeop: str, shell: str, verbose: bool):
        self.env = env
        self.kubeop = os.path.expanduser(kubeop)
        self.shell = shell
        self.verbose = verbose

    def _wrap(self, inner: str) -> list[str]:
        # Re-source the wrapper inside the subshell so `kube`/`k8sop` exist.
        return [self.shell, "-c", f'source {shlex.quote(self.kubeop)}; {inner}']

    def run(self, inner: str, check: bool = True) -> subprocess.CompletedProcess:
        if self.verbose:
            print(f"{C.DIM}$ {inner}{C.RESET}", file=sys.stderr)
        return subprocess.run(
            self._wrap(inner), check=check, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def kube(self, args: str, check: bool = True) -> subprocess.CompletedProcess:
        return self.run(f"kube {self.env} {args}", check=check)

    def kube_json(self, args: str) -> dict:
        cp = self.kube(f"{args} -o json")
        return json.loads(cp.stdout or "{}")

    def preflight(self) -> bool:
        if not os.path.exists(self.kubeop):
            print(bad(f"wrapper not found: {self.kubeop} "
                      f"(point --kubeop at your kubeop.sh)"), file=sys.stderr)
            return False
        cp = self.kube("version --output=json", check=False)
        if cp.returncode != 0:
            print(bad("cannot reach cluster via wrapper:"), file=sys.stderr)
            print(C.DIM + (cp.stderr.strip() or cp.stdout.strip()) + C.RESET,
                  file=sys.stderr)
            return False
        return True


# --------------------------------------------------------------------------- #
# Time helpers
# --------------------------------------------------------------------------- #
def parse_ts(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def age_hours(ts: datetime | None) -> float | None:
    if ts is None:
        return None
    return (datetime.now(timezone.utc) - ts).total_seconds() / 3600.0


def human_age(h: float | None) -> str:
    if h is None:
        return "unknown"
    if h < 1:
        return f"{int(h * 60)}m"
    if h < 48:
        return f"{h:.1f}h"
    return f"{h / 24:.1f}d"


# --------------------------------------------------------------------------- #
# Discovery
# --------------------------------------------------------------------------- #
@dataclass
class Snapshot:
    name: str
    ready: bool
    created: datetime | None
    size: str
    source_pvc: str


@dataclass
class DumpFile:
    name: str
    size_bytes: int
    mtime: datetime | None


@dataclass
class AppState:
    app: App
    cluster_phase: str = "ABSENT"
    cluster_instances: int = 0
    pv_status: str = "ABSENT"
    backups_total: int = 0
    backups_completed: int = 0
    last_backup: datetime | None = None
    snapshots: list[Snapshot] = field(default_factory=list)
    dumps: list[DumpFile] = field(default_factory=list)
    dumps_pvc_status: str = "ABSENT"
    notes: list[str] = field(default_factory=list)


def discover(cl: Cluster, app: App, inspect_dumps: bool) -> AppState:
    st = AppState(app=app)
    ns = app.namespace
    cluster = app.cluster(cl.env)

    # CNPG cluster + PV
    c = cl.kube_json(f"-n {ns} get cluster.postgresql.cnpg.io {cluster}")
    if c.get("kind") == "Cluster":
        st.cluster_phase = c.get("status", {}).get("phase", "?")
        st.cluster_instances = c.get("spec", {}).get("instances", 0)
    pv = cl.kube_json(f"get pv {app.data_pv(cl.env)}")
    if pv.get("kind") == "PersistentVolume":
        st.pv_status = pv.get("status", {}).get("phase", "?")

    # CNPG Backup CRs (physical, volumeSnapshot method)
    backups = cl.kube_json(f"-n {ns} get backups.postgresql.cnpg.io").get("items", [])
    backups = [b for b in backups
               if b.get("spec", {}).get("cluster", {}).get("name") == cluster]
    st.backups_total = len(backups)
    completed = [b for b in backups
                 if b.get("status", {}).get("phase") == "completed"]
    st.backups_completed = len(completed)
    stamps = [parse_ts(b.get("status", {}).get("stoppedAt")
                       or b.get("status", {}).get("startedAt"))
              for b in completed]
    stamps = [s for s in stamps if s]
    st.last_backup = max(stamps) if stamps else None

    # VolumeSnapshots bound to this cluster's data PVC
    pvc = f"{cluster}-1"
    snaps = cl.kube_json(f"-n {ns} get volumesnapshot").get("items", [])
    for s in snaps:
        src = s.get("spec", {}).get("source", {}).get("persistentVolumeClaimName", "")
        if src != pvc:
            continue
        status = s.get("status", {}) or {}
        st.snapshots.append(Snapshot(
            name=s["metadata"]["name"],
            ready=bool(status.get("readyToUse")),
            created=parse_ts(status.get("creationTime")),
            size=status.get("restoreSize", "?"),
            source_pvc=src,
        ))
    st.snapshots.sort(key=lambda x: x.created or datetime.min.replace(tzinfo=timezone.utc),
                      reverse=True)

    # Dumps PVC + (optional) file listing via a transient read-only probe pod
    dpvc = cl.kube_json(f"-n {ns} get pvc {app.dumps_pvc(cl.env)}")
    if dpvc.get("kind") == "PersistentVolumeClaim":
        st.dumps_pvc_status = dpvc.get("status", {}).get("phase", "?")
        if inspect_dumps and st.dumps_pvc_status == "Bound":
            st.dumps = probe_dumps(cl, app)
        elif not inspect_dumps:
            st.notes.append("dump file listing skipped (--no-inspect-dumps)")
    return st


def probe_dumps(cl: Cluster, app: App) -> list[DumpFile]:
    """Mount the dumps PVC read-only in a transient busybox pod and list it.

    This spawns (and auto-removes) a short-lived pod — it never writes to the
    volume, so it is safe in verify mode. RWO is fine because the dumps PVC is
    only mounted while the dump CronJob is actively running.
    """
    ns = app.namespace
    pvc = app.dumps_pvc(cl.env)
    pod = f"dr-probe-{int(time.time())}"
    overrides = {
        "spec": {
            "nodeSelector": {"node": "worker"},
            "containers": [{
                "name": "probe", "image": "busybox:1.36",
                "command": ["sh", "-c",
                            "ls -l --full-time /backup 2>/dev/null "
                            "| awk 'NR>1{print $5\"|\"$6\"T\"$7\"|\"$9}'"],
                "volumeMounts": [{"name": "b", "mountPath": "/backup", "readOnly": True}],
                "securityContext": {"runAsUser": 26, "runAsGroup": 26,
                                    "runAsNonRoot": True,
                                    "allowPrivilegeEscalation": False,
                                    "readOnlyRootFilesystem": True,
                                    "capabilities": {"drop": ["ALL"]}},
            }],
            "volumes": [{"name": "b",
                         "persistentVolumeClaim": {"claimName": pvc, "readOnly": True}}],
            "restartPolicy": "Never",
        }
    }
    args = (f"-n {ns} run {pod} --rm -i --restart=Never --image=busybox:1.36 "
            f"--overrides={shlex.quote(json.dumps(overrides))} --command -- true")
    cp = cl.kube(args, check=False)
    out = cp.stdout or ""
    dumps: list[DumpFile] = []
    for line in out.splitlines():
        line = line.strip()
        if "|" not in line or "/backup" in line:
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        size_s, ts_s, name = parts
        if not name.endswith(".dump"):
            continue
        try:
            size = int(size_s)
        except ValueError:
            continue
        mt = None
        try:
            mt = datetime.strptime(ts_s.split(".")[0], "%Y-%m-%dT%H:%M:%S").replace(
                tzinfo=timezone.utc)
        except ValueError:
            pass
        dumps.append(DumpFile(name=name, size_bytes=size, mtime=mt))
    dumps.sort(key=lambda d: d.mtime or datetime.min.replace(tzinfo=timezone.utc),
               reverse=True)
    return dumps


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #
def render_state(st: AppState) -> int:
    """Print a per-app health block. Returns the number of CRITICAL issues."""
    a = st.app
    crit = 0
    print(f"\n{C.BOLD}{a.name}{C.RESET}  ({a.namespace})")

    # Cluster + PV
    cphase = st.cluster_phase
    cline = f"CNPG cluster: {cphase} ({st.cluster_instances} instance/s)"
    print("  " + (ok(cline) if "healthy" in cphase.lower() else
                  warn(cline) if cphase != "ABSENT" else bad(cline + " — not found")))
    pvline = f"data PV {a.data_pv('dev')}: {st.pv_status}"
    print("  " + (ok(pvline) if st.pv_status == "Bound" else warn(pvline)))

    # Physical snapshots
    if st.snapshots:
        latest = st.snapshots[0]
        ah = age_hours(latest.created)
        line = (f"VolumeSnapshot: {latest.name}  age={human_age(ah)}  "
                f"size={latest.size}  ready={latest.ready}  "
                f"({len(st.snapshots)} total, {st.backups_completed} completed backups)")
        if not latest.ready:
            crit += 1; print("  " + bad(line + "  ← NOT readyToUse"))
        elif ah is not None and ah > SNAPSHOT_MAX_AGE_H:
            print("  " + warn(line + f"  ← older than {SNAPSHOT_MAX_AGE_H}h"))
        else:
            print("  " + ok(line))
    else:
        crit += 1
        print("  " + bad("VolumeSnapshot: NONE found — physical restore unavailable"))

    # Logical dumps
    dline_pvc = f"dumps PVC {a.dumps_pvc('dev')}: {st.dumps_pvc_status}"
    if st.dumps:
        latest = st.dumps[0]
        ah = age_hours(latest.mtime)
        small = latest.size_bytes < 1024
        line = (f"latest dump: {latest.name}  age={human_age(ah)}  "
                f"size={latest.size_bytes:,}B  ({len(st.dumps)} retained)")
        if small:
            crit += 1; print("  " + bad(line + "  ← suspiciously small (<1KiB)"))
        elif ah is not None and ah > DUMP_MAX_AGE_H:
            print("  " + warn(line + f"  ← older than {DUMP_MAX_AGE_H}h"))
        else:
            print("  " + ok(line))
    elif st.dumps_pvc_status == "Bound":
        print("  " + warn(dline_pvc + " — bound but no .dump files listed"))
    else:
        crit += 1
        print("  " + bad(dline_pvc + " — logical rip cord unavailable"))

    for n in st.notes:
        print("  " + info(n))
    return crit


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def cmd_verify(cl: Cluster, args) -> int:
    apps = select_apps(args.app)
    print(f"{C.BOLD}DR backup verification — env={cl.env}{C.RESET}")
    print(C.DIM + f"snapshot freshness <= {SNAPSHOT_MAX_AGE_H}h, "
          f"dump freshness <= {DUMP_MAX_AGE_H}h" + C.RESET)
    total_crit = 0
    for app in apps:
        st = discover(cl, app, inspect_dumps=not args.no_inspect_dumps)
        total_crit += render_state(st)
    print()
    if total_crit:
        print(bad(f"{total_crit} critical issue(s) — NOT recovery-ready"))
        return 1
    print(ok("all checked backups present, fresh and ready"))
    return 0


def cmd_list_backups(cl: Cluster, args) -> int:
    app = APPS[args.app]
    st = discover(cl, app, inspect_dumps=not args.no_inspect_dumps)
    print(f"{C.BOLD}{app.name} — physical VolumeSnapshots{C.RESET}")
    if not st.snapshots:
        print("  (none)")
    for s in st.snapshots:
        print(f"  {s.name}  ready={s.ready}  age={human_age(age_hours(s.created))}  size={s.size}")
    print(f"\n{C.BOLD}{app.name} — logical dumps "
          f"({app.dumps_pvc(cl.env)}){C.RESET}")
    if not st.dumps:
        print("  (none)")
    for d in st.dumps:
        print(f"  {d.name}  {d.size_bytes:,}B  age={human_age(age_hours(d.mtime))}")
    return 0


def cmd_restore_snapshot(cl: Cluster, args) -> int:
    """Physical recovery: bootstrap a NEW CNPG cluster from a VolumeSnapshot.

    NOTE the static-PV caveat: the live cluster pins its PVC to the pre-created
    PV (dev-<app>-db-pv). CNPG snapshot recovery instead provisions a fresh PVC
    from the snapshot's dataSource (CSI clones the ZFS snapshot into a new
    zvol). So the recovery manifest deliberately drops `volumeName`. To keep the
    original static zvol identity, use the TrueNAS ZFS-rollback path in the
    playbook instead.
    """
    app = APPS[args.app]
    st = discover(cl, app, inspect_dumps=False)
    ready = [s for s in st.snapshots if s.ready]
    if not ready:
        print(bad(f"no readyToUse VolumeSnapshot for {app.name}"))
        return 1
    snap = next((s for s in ready if s.name == args.snapshot), ready[0]) \
        if args.snapshot else ready[0]
    new_cluster = args.target or f"{app.cluster(cl.env)}-restore"

    manifest = render_recovery_manifest(app, snap.name, new_cluster)
    print(f"{C.BOLD}Physical restore plan — {app.name}{C.RESET}")
    print(info(f"source snapshot : {snap.name} "
               f"(age={human_age(age_hours(snap.created))}, size={snap.size})"))
    print(info(f"target cluster  : {new_cluster} (new PVC cloned from snapshot)"))
    print(info("validate the restored cluster, then cut traffic over / "
               "rename per the playbook.\n"))
    print(C.DIM + "--- recovery Cluster manifest ---" + C.RESET)
    print(manifest)
    print(C.DIM + "--- apply with ---" + C.RESET)
    apply_cmd = f"kube {cl.env} apply -f -   # (manifest piped in)"
    print(f"  {apply_cmd}")
    print(f"  kube {cl.env} -n {app.namespace} get cluster {new_cluster} -w")

    if not args.execute:
        print("\n" + warn("DRY-RUN — re-run with --execute to apply"))
        return 0

    if not confirm(f"Apply recovery cluster '{new_cluster}' now?", args.yes):
        print("aborted."); return 1
    cp = cl.run(f"source {shlex.quote(cl.kubeop)}; "
                f"printf %s {shlex.quote(manifest)} | kube {cl.env} apply -f -",
                check=False)
    print(cp.stdout, cp.stderr)
    return cp.returncode


def cmd_restore_dump(cl: Cluster, args) -> int:
    """Logical restore: pg_restore a dump into a (running) CNPG cluster."""
    app = APPS[args.app]
    target_cluster = args.target or app.cluster(cl.env)
    st = discover(cl, app, inspect_dumps=True)
    if not st.dumps and not args.dump:
        print(bad("no dumps found and --dump not given")); return 1
    dump = args.dump or st.dumps[0].name
    pvc = app.dumps_pvc(cl.env)

    # pg_restore runs inside a transient pod that mounts the dumps PVC and
    # connects to the cluster -rw service, reading creds from the app secret.
    restore_sh = (
        "set -euo pipefail; "
        f'echo "[restore] {dump} -> {target_cluster}-rw/{app.db}"; '
        "pg_restore --verbose --clean --if-exists --no-owner --no-acl "
        f'--host={target_cluster}-rw --port=5432 '
        f'--username="$PGUSER" --dbname={app.db} /backup/{shlex.quote(dump)}'
    )
    overrides = json.dumps({
        "spec": {
            "nodeSelector": {"node": "worker"},
            "containers": [{
                "name": "restore", "image": CNPG_IMAGE,
                "command": ["bash", "-c", restore_sh],
                "env": [
                    {"name": "PGUSER", "valueFrom": {"secretKeyRef": {
                        "name": app.creds_secret, "key": "username"}}},
                    {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {
                        "name": app.creds_secret, "key": "password"}}},
                ],
                "volumeMounts": [{"name": "b", "mountPath": "/backup", "readOnly": True}],
            }],
            "volumes": [{"name": "b", "persistentVolumeClaim": {
                "claimName": pvc, "readOnly": True}}],
            "restartPolicy": "Never",
        }
    })
    pod = f"dr-restore-{int(time.time())}"
    run_cmd = (f"kube {cl.env} -n {app.namespace} run {pod} --rm -i "
               f"--restart=Never --image={CNPG_IMAGE} "
               f"--overrides={shlex.quote(overrides)} --command -- true")

    print(f"{C.BOLD}Logical restore plan — {app.name}{C.RESET}")
    print(info(f"dump          : {dump}  (from PVC {pvc})"))
    print(info(f"target        : {target_cluster}-rw / db={app.db}"))
    print(warn("pg_restore --clean --if-exists DROPS and recreates objects in "
               "the target DB. Make sure the cluster is up and idle."))
    print(C.DIM + "\n--- equivalent command ---" + C.RESET)
    print("  " + run_cmd)

    if not args.execute:
        print("\n" + warn("DRY-RUN — re-run with --execute to restore"))
        return 0
    if not confirm(f"Restore {dump} into {target_cluster}/{app.db}?", args.yes):
        print("aborted."); return 1
    cp = cl.kube(f"-n {app.namespace} run {pod} --rm -i --restart=Never "
                 f"--image={CNPG_IMAGE} --overrides={shlex.quote(overrides)} "
                 f"--command -- true", check=False)
    print(cp.stdout, cp.stderr)
    return cp.returncode


# --------------------------------------------------------------------------- #
# Manifest rendering
# --------------------------------------------------------------------------- #
def render_recovery_manifest(app: App, snapshot: str, cluster: str) -> str:
    return f"""\
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {cluster}
  namespace: {app.namespace}
  labels:
    app: {app.name}
    role: dr-restore
spec:
  instances: 1
  imageName: {CNPG_IMAGE}
  superuserSecret:
    name: {app.creds_secret}
  storage:
    size: 10Gi
    storageClass: iscsi
    # No volumeName: recovery provisions a fresh PVC cloned from the snapshot
    # (a new zvol via democratic-csi), NOT the static dev-{app.name}-db-pv.
  bootstrap:
    recovery:
      volumeSnapshots:
        storage:
          name: {snapshot}
          kind: VolumeSnapshot
          apiGroup: snapshot.storage.k8s.io
"""


# --------------------------------------------------------------------------- #
# Misc
# --------------------------------------------------------------------------- #
def select_apps(name: str | None) -> list[App]:
    if name:
        return [APPS[name]]
    return list(APPS.values())


def confirm(prompt: str, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    try:
        return input(f"{C.Y}{prompt}{C.RESET} [y/N] ").strip().lower() in ("y", "yes")
    except (EOFError, KeyboardInterrupt):
        return False


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Disaster-recovery verification & restore for h0me CNPG data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Safe by default: only --execute mutates the cluster.")
    p.add_argument("--env", default="dev", help="cluster env (default: dev)")
    p.add_argument("--kubeop", default="~/.zsh/kubeop.sh",
                   help="path to the kube/k8sop wrapper to source")
    p.add_argument("--shell", default=os.environ.get("SHELL", "/bin/zsh"),
                   help="shell used to source the wrapper")
    p.add_argument("--no-color", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="echo every wrapper command")
    sub = p.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("verify", help="read-only health of all backups")
    v.add_argument("--app", choices=list(APPS), help="limit to one app")
    v.add_argument("--no-inspect-dumps", action="store_true",
                   help="skip the transient probe pod that lists dump files")
    v.set_defaults(func=cmd_verify)

    lb = sub.add_parser("list-backups", help="list snapshots + dumps for an app")
    lb.add_argument("app", choices=list(APPS))
    lb.add_argument("--no-inspect-dumps", action="store_true")
    lb.set_defaults(func=cmd_list_backups)

    rs = sub.add_parser("restore-snapshot",
                        help="physical recovery from a VolumeSnapshot")
    rs.add_argument("app", choices=list(APPS))
    rs.add_argument("--snapshot", help="snapshot name (default: latest ready)")
    rs.add_argument("--target", help="name for the restored cluster")
    rs.add_argument("--execute", action="store_true", help="apply (default: dry-run)")
    rs.add_argument("--yes", action="store_true", help="skip confirmation")
    rs.set_defaults(func=cmd_restore_snapshot)

    rd = sub.add_parser("restore-dump", help="logical pg_restore from a dump")
    rd.add_argument("app", choices=list(APPS))
    rd.add_argument("--dump", help="dump filename (default: latest)")
    rd.add_argument("--target", help="target cluster (default: live cluster)")
    rd.add_argument("--execute", action="store_true", help="restore (default: dry-run)")
    rd.add_argument("--yes", action="store_true", help="skip confirmation")
    rd.set_defaults(func=cmd_restore_dump)
    return p


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    if args.no_color or not sys.stdout.isatty():
        C.strip()
    cl = Cluster(args.env, args.kubeop, args.shell, args.verbose)
    if not cl.preflight():
        return 2
    try:
        return args.func(cl, args)
    except subprocess.CalledProcessError as e:
        print(bad("wrapper command failed:"), file=sys.stderr)
        print(C.DIM + (e.stderr or "").strip() + C.RESET, file=sys.stderr)
        return 2
    except KeyError as e:
        print(bad(f"unknown app: {e}"), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
