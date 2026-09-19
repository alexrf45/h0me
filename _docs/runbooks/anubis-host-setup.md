# Runbook — anubis Host Setup (Debian + native k3s)

Bringing up the single bare-metal node that hosts the `home` cluster. Everything
here runs **on anubis as root**, by hand. None of it is expressible in Terraform
(`remote-exec` is forbidden by `.claude/rules/terraform-buisness-rules.md`), so
this file is the source of truth — keep it in step with reality.

```
anubis (Debian, 192.168.20.87)
└── k3s server (systemd)            ← this runbook
    ├── containerd
    ├── open-iscsi → TrueNAS 192.168.20.106:3260
    └── no CNI yet                  ← Phase 1 (Terraform) installs Cilium
```

**Host facts.** Intel Celeron G5905 — **2 cores, no SMT** — 31 GiB RAM. CPU is
the binding constraint for the whole cluster; see
`_docs/decisions/single-node-capacity-budget.md`. Nothing in this runbook may
add a background daemon that isn't listed here.

**Scope.** This runbook ends with a **`NotReady` node** and **CoreDNS +
metrics-server sitting `Pending`**. That is the correct finishing state, and the
two facts are the same fact: there is no CNI until Phase 1, and kubelet will not
report `Ready` without one. Do not "fix" it here.

---

## 0. Record these facts first

Later phases consume them. Fill the table in as you go and keep it current.

| Fact | Command | Value |
| --- | --- | --- |
| NIC name | `ip -br link` | `enp2s0` |
| iSCSI IQN | `cat /etc/iscsi/initiatorname.iscsi` | `iqn.2026-09.net.phr3d:anubis` |
| Debian release | `cat /etc/os-release` | `Debian GNU/Linux 13 (trixie)` |
| Kernel | `uname -r` | `6.12.100+deb13-amd64` |
| k3s version | `k3s --version` | `v1.36.4+k3s1` |
| TrueNAS initiator group ID | TrueNAS UI → Sharing → iSCSI → Initiator Groups | `1` |
| TrueNAS portal group ID | TrueNAS UI → Sharing → iSCSI → Portals | `1` |

The NIC name is **not** `eth0` on Debian — it feeds `NODE_INTERFACE` in the
`cluster-config` ConfigMap, which the `CiliumL2AnnouncementPolicy` uses. Get it
wrong and the Gateway's LoadBalancer IP is never ARP-announced on the LAN, with
no error anywhere.

---

## 1. Hostname — before anything else

k3s derives the Kubernetes node name from the hostname. Renaming afterwards
orphans the `Node` object and every node-scoped selector.

```sh
hostnamectl set-hostname anubis
hostnamectl status | head -3
```

Confirm `/etc/hosts` has a line for it so `sudo` and friends don't stall on
reverse lookups.

---

## 2. Disable swap

```sh
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab
systemctl --type swap list-units --all        # mask any remaining .swap units
swapon --show                                  # must print nothing
```

**Why, given 31 GiB of RAM.** k3s starts happily with swap on
(`--fail-swap-on=false`), and kubelet's default `NoSwap` behaviour keeps *pods*
out of swap — but the **system daemons do not get that protection**. Letting the
API server, kine or containerd swap on a 2-core box reproduces the exact
leader-election-loss and probe-timeout cascade from
`_docs/post-mortems/2026-06-27-worker-node-cpu-starvation-after-cordon-drain.md`,
except with nowhere to drain to. Memory is not the constraint here; tail latency
is. Leave the partition on disk, unused.

---

## 3. cgroup v2 and bpffs

Verify rather than configure — Debian 12/13 already do the right thing.

```sh
stat -fc %T /sys/fs/cgroup        # expect: cgroup2fs
mount | grep bpf                  # expect: bpffs on /sys/fs/bpf
```

If `/sys/fs/cgroup` reports `tmpfs` you are on cgroup v1; add
`systemd.unified_cgroup_hierarchy=1` to the kernel cmdline and reboot before
continuing. A host-level bpffs lets Cilium's BPF maps survive an agent restart
without re-pinning.

---

## 4. rp_filter — verify, do not configure

**Nothing to change.** systemd's `/usr/lib/sysctl.d/50-default.conf` ships:

```
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.*.rp_filter = 2
-net.ipv4.conf.all.rp_filter
```

which is already the correct shape for Cilium. Three reasons:

1. **The `-` line is deliberate, documented syntax** — not a typo or a disabled
   line. From `sysctl.d(5)`: *"A key may be explicitly excluded from being set by
   any matching glob patterns by specifying the key name prefixed with a '-'
   character and not followed by '='."* The man page uses this exact rp_filter
   case as its worked example. So `net.ipv4.conf.all.rp_filter` is excluded from
   the glob above and left at the kernel default, **0**.
2. **Effective rp_filter on an interface is `max(conf.all, conf.<iface>)`.** With
   `all` at 0, each interface's own value governs. That is precisely *why* systemd
   excludes `all`: setting it to 2 would impose a floor of 2 everywhere and make
   per-interface exceptions impossible. Writing `net.ipv4.conf.all.rp_filter = 0`
   by hand is therefore a **no-op** — it is already 0 — and setting
   `default.rp_filter = 0` only seeds newly created interfaces, which the glob
   then overrides at creation anyway.
3. **Cilium fixes its own interfaces at startup.** The agent DaemonSet runs an
   init container **`apply-sysctl-overwrites`** (`cilium-sysctlfix`) that writes
   `/etc/sysctl.d/99-zzz-override_cilium.conf` containing
   `net.ipv4.conf.lxc*.rp_filter = 0`, `net.ipv4.conf.cilium_*.rp_filter = 0` and
   `net.ipv4.conf.all.rp_filter = 0`, then restarts `systemd-sysctl`. The manual
   `99-override_cilium_rp_filter.conf` workaround belongs to Cilium 1.7–1.9 and is
   absent from the current system requirements because the agent handles it.

Note also that the value is **2 (loose)**, not 1 (strict). Strict is the mode that
breaks kube-proxy-free load balancing (cilium/cilium#13130); loose is benign on the
host NIC.

Record the starting state so a later regression is diagnosable:

```sh
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter
sysctl net.ipv4.conf.enp2s0.rp_filter
```

**Verify after Phase 1 brings Cilium up** — these interfaces do not exist yet, so
this is not a check for today:

```sh
cat /etc/sysctl.d/99-zzz-override_cilium.conf
sysctl -a 2>/dev/null | grep -E 'conf\.(lxc|cilium_).*rp_filter'   # expect 0
```

If that file is missing *and* pod-to-outside traffic fails, the historical manual
override is the fallback — but a missing file is a Cilium problem to diagnose, not
something to paper over:

```sh
# fallback only, if apply-sysctl-overwrites did not run
echo 'net.ipv4.conf.lxc*.rp_filter = 0' > /etc/sysctl.d/99-override_cilium_rp_filter.conf
systemctl restart systemd-sysctl
```

NetworkManager is **not installed** on anubis, so there is nothing to exclude from
its management. If it is ever added, it must be told to leave `cilium_*`, `lxc*`
and `cni*` alone.

---

## 5. open-iscsi, with a pinned IQN

```sh
apt-get update && apt-get install -y open-iscsi
systemctl enable --now iscsid open-iscsi
```

**Pin the IQN.** Debian generates a random one at install time. A reinstall
regenerates it, which silently breaks every iSCSI attach against the TrueNAS
initiator group — a variant of
`_docs/post-mortems/2026-06-23-iscsi-initiator-group-mismatch.md`, and one that
presents as PVCs stuck `Pending` with `"<N> Initiator not found in database"`.

```sh
echo 'InitiatorName=iqn.2026-09.net.phr3d:anubis' > /etc/iscsi/initiatorname.iscsi
systemctl restart iscsid
cat /etc/iscsi/initiatorname.iscsi
```

### Do not change the TrueNAS Base Name

Two different IQNs are in play and they must stay distinct:

| | Lives on | Example | Set by |
| --- | --- | --- | --- |
| **Initiator** IQN | anubis | `iqn.2026-09.net.phr3d:anubis` | `/etc/iscsi/initiatorname.iscsi`, above |
| **Target** Base Name | TrueNAS | `iqn.2005-10.org.freenas.ctl` | TrueNAS → Shares → iSCSI → Global Configuration |

Every target IQN is `<Base Name>:<target-name>`, so the Base Name is the
*server's* namespace and the initiator IQN is the *client's* identity. Setting the
Base Name to the initiator's IQN is not a match-up — it makes targets come out as
`iqn.2026-09.net.phr3d:anubis:<target>`, which is confusing to debug and diverges
from the `iqn.2005-10.org.freenas.ctl:...` form the repo's docs and any static PV
assume. Leave the Base Name at the TrueNAS default.

### Check reachability — and expect discovery to return nothing

```sh
iscsiadm -m discovery -t sendtargets -p 192.168.20.106:3260; echo "exit=$?"
```

**`exit=0` with no output is the expected, healthy result at this point.** It means
the TCP session opened, the SendTargets request completed, and TrueNAS replied with
an **empty target list**. There is nothing to list yet: the old `dev-*` targets were
wiped, and under dynamic provisioning (see
`.claude/rules/storage.md`) democratic-csi creates the zvol, target and extent
through the TrueNAS API at first PVC — so no target exists until Phase 6.

A real failure looks different. Interpret it like this:

| Result | Meaning |
| --- | --- |
| `exit=0`, no output | Connected; zero targets **visible to this initiator**. Normal now. |
| `exit=0`, target lines | A target exists and is authorized for this IQN. |
| `cannot make connection`, `connection refused`, non-zero exit | Portal unreachable — check the iSCSI service and portal binding on TrueNAS, and that `:3260` is open. |
| `exit=19` / login errors later | Authorization, not connectivity — the initiator group does not include this IQN. |

If a target *does* exist on TrueNAS and discovery still returns nothing, the cause
is authorization rather than connectivity: SendTargets only advertises targets whose
initiator group permits the requesting IQN. Add debug output and check the group:

```sh
iscsiadm -m discovery -t sendtargets -p 192.168.20.106:3260 -d 8 2>&1 | tail -30
```

### Optional but recommended — prove the path end to end now

Worth five minutes of clicking, because both
`_docs/post-mortems/2026-06-23-iscsi-initiator-group-mismatch.md` and
`_docs/post-mortems/2026-06-23-freshrss-zvol-volumehandle-mismatch.md` were this
failure discovered late, as a `Pending` PVC. On TrueNAS create a throwaway 1 GiB
zvol, an extent over it, and a target bound to initiator group `1` and portal
group `1`, then from anubis:

```sh
iscsiadm -m discovery -t sendtargets -p 192.168.20.106:3260      # target now listed
iscsiadm -m node -T <target-iqn> -p 192.168.20.106:3260 --login
lsblk                                                             # new block device
iscsiadm -m node -T <target-iqn> -p 192.168.20.106:3260 --logout
```

Then delete the target, extent and zvol on TrueNAS. If login succeeds, the portal,
the initiator group and the pinned IQN are all correct and Phase 6 has no surprises
left in it.

Record the host paths — the democratic-csi HelmRelease must point at these, and
they differ from the Talos `iscsi-tools` extension paths the repo currently has:

| | Debian (use these) | Talos (old values) |
| --- | --- | --- |
| binary | `/usr/sbin/iscsiadm` | `/usr/local/sbin/iscsiadm` |
| config dir | `/etc/iscsi` | `/var/etc/iscsi` |

---

## 6. Install k3s

Put the configuration in a **file**, not only in `INSTALL_K3S_EXEC`, so a
reinstall or upgrade cannot silently drop a flag.

```sh
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'EOF'
write-kubeconfig-mode: "0600"
node-ip: "192.168.20.87"
node-label:
  - "node=worker"
tls-san:
  - "192.168.20.87"
  - "anubis"
  - "anubis.bun-dominant.ts.net"
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
cluster-dns: "10.43.0.10"
flannel-backend: "none"
disable-network-policy: true
disable-kube-proxy: true
disable:
  - traefik
  - servicelb
  - local-storage
secrets-encryption: true
kubelet-arg:
  - "system-reserved=cpu=300m,memory=1Gi"
  - "kube-reserved=cpu=100m,memory=512Mi"
EOF

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.4+k3s1" sh -s - server
```

### Why each setting

| Setting | Reason |
| --- | --- |
| `flannel-backend: none`, `disable-network-policy`, `disable-kube-proxy` | Cilium owns the CNI, NetworkPolicy enforcement, and kube-proxy replacement. Leaving flannel on silently conflicts; leaving k3s's kube-router netpol controller on fights CiliumNetworkPolicy. |
| `disable: traefik` | Traefik would contend with the Cilium Gateway for :80/:443. Nothing in `_lib` uses `kind: Ingress`. |
| `disable: servicelb` | klipper-servicelb would fight Cilium LB-IPAM and L2 announcements over the `192.168.20.226–.236` pool. |
| `disable: local-storage` | `iscsi` is the only StorageClass, and the only default. k3s's local-path would reintroduce the double-default-class conflict. |
| **`metrics-server` kept** | Not disabled. `kube home top` and `/cluster-health` depend on it, and it replaces the Talos `extraManifests` copy. |
| `node-label: node=worker` | 29 sites in `_lib/` select on `node: worker`. One flag makes all of them correct with a zero-line diff. See `_docs/decisions/node-labels-worker-selection.md`. |
| CIDRs / `cluster-dns` | k3s defaults that happen to match what Talos used, so CNPG's `pg_hba … 10.43.0.0/16` and `clusterDNS` carry over untouched. |
| `system-reserved` / `kube-reserved` | The single most important new setting. Shrinks allocatable to ~1600m so the scheduler cannot book the CPU that k3s itself needs. This is the structural fix for the starvation post-mortem. |
| no `--cluster-init` | Default sqlite/kine. Embedded etcd adds constant raft fsync load to buy HA one node cannot have. **Cost:** the datastore becomes a single unreplicated file — see §9. |

**k3s server nodes are not tainted.** Unlike kubeadm, the node is schedulable by
default; it carries `node-role.kubernetes.io/control-plane` as a *label* only. Do
not add `--node-taint`.

---

## 7. Verify

```sh
systemctl status k3s --no-pager | head -5
k3s kubectl get nodes -o wide
k3s kubectl get node anubis -L node
k3s kubectl get pods -A
```

Expected finishing state:

- `anubis` is **`NotReady`**. Correct — see below.
- `k3s kubectl get node anubis -L node` shows `worker` under the `NODE` column.
- **`coredns` and `metrics-server` are `Pending`.** Correct — there is no CNI.
- **No** `flannel`, `kube-proxy`, `traefik`, `svclb-*` or `local-path-provisioner`
  pods anywhere.
- `swapon --show` prints nothing.

### Why the node is `NotReady` — and how to tell that apart from a fault

`flannel-backend: none` means k3s installs no CNI and writes nothing into
`/etc/cni/net.d`. kubelet will not advertise `Ready` without a network plugin, so
it holds the node at:

```
Ready  False  KubeletNotReady  container runtime network not ready: NetworkReady=false
               reason:NetworkPluginNotReady message:Network plugin returns error:
               cni plugin not initialized
```

This is the same absence that leaves CoreDNS and metrics-server `Pending` — one
cause, two symptoms. Both clear in Phase 1 the moment the Cilium agent drops a CNI
conf. **A `Ready` node at the end of this runbook would mean something installed a
CNI that was not asked for** — check for a surviving flannel.

Confirm the reason rather than assuming it:

```sh
k3s kubectl get node anubis -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}'
ls -l /etc/cni/net.d/ 2>&1      # expect empty or absent
```

| Ready message mentions | Meaning |
| --- | --- |
| `cni plugin not initialized` / `NetworkPluginNotReady` | Expected. Phase 0 is done; go to Phase 1. |
| `PLEG is not healthy` | containerd is wedged — `systemctl status containerd`, `journalctl -u k3s`. |
| `DiskPressure` / `MemoryPressure` | Genuine host problem. Do not proceed. |
| certificate or `Unauthorized` errors | kubelet cannot reach the API server; check `tls-san` and clock skew. |

Every other condition (`MemoryPressure`, `DiskPressure`, `PIDPressure`) must read
`False`. If they do and the only complaint is the CNI, stop here — that is the
gate passed.

If the node label is missing, stop. Fix `/etc/rancher/k3s/config.yaml` and
`systemctl restart k3s` — the label is applied by the kubelet at **registration**,
so a node that registered without it needs the label added by hand
(`k3s kubectl label node anubis node=worker`) as well as the config corrected,
or 29 workloads will go `Pending` in later phases for a non-obvious reason.

---

## 8. Kubeconfig into 1Password

The kubeconfig is never stored on a workstation disk — `_hack/scripts/kubeop.sh`
fetches it on demand from `op://$OP_VAULT/<cluster>-kubeconfig/notesPlain`. This
step replaces what `_infra/modules/talos-pve/config-export.tf` used to do.

```sh
sed 's|127\.0\.0\.1|192.168.20.87|' /etc/rancher/k3s/k3s.yaml
```

Store the output as a 1Password **Secure Note** titled **`anubis-kubeconfig`** in
the `HomeLab` vault. The rewrite works because `192.168.20.87` is in `tls-san`.

Then from a workstation:

```sh
kube-flush
kube home get nodes
```

Expect `anubis   NotReady   control-plane,master` — §7 explains why. Reaching the
API server at all is what this step proves.

`kube home` resolves to cluster `anubis` via `_kubeop_cluster_for_env` — see
`.claude/rules/kube-wrapper.md`. The wrapper is bash as of 2026-09-19 and is
sourced by the Home Manager module `dev-tools/kubernetes.nix` in `nix-config`;
if `kube` is not a known command, that module has not been switched in yet.

---

## 9. Back up the k3s datastore

Choosing sqlite over embedded etcd means cluster state is **one unreplicated
file** with none of etcd's snapshot tooling. This is not optional.

```sh
install -d -m 0700 /var/backups/k3s
cat > /etc/cron.daily/k3s-datastore-backup <<'EOF'
#!/bin/sh
set -eu
out="/var/backups/k3s/k3s-server-$(date -u +%Y%m%dT%H%M%SZ).tar.zst"
tar -C /var/lib/rancher/k3s -caf "$out" server/db server/token server/tls
find /var/backups/k3s -name 'k3s-server-*.tar.zst' -mtime +14 -delete
EOF
chmod +x /etc/cron.daily/k3s-datastore-backup
/etc/cron.daily/k3s-datastore-backup && ls -lh /var/backups/k3s
```

Ship those off-box to TrueNAS — a backup on the same disk as the thing it backs
up is not a backup. Wire that up alongside the CNPG dump export and record it in
`_docs/runbooks/disaster-recovery.md`.

---

## 10. Rollback

```sh
/usr/local/bin/k3s-uninstall.sh
```

Removes k3s, containerd state, and `/var/lib/rancher/k3s` **including the
datastore**. It does not touch the host prep in §1–§5, so a reinstall is just
§6 again. Take a datastore backup first if there is anything in the cluster you
care about.

---

## Next

Phase 1 — `_infra/anubis/` bootstraps **Cilium first** (nothing schedules until
there is a CNI, so Flux's own controllers would otherwise sit `Pending` forever),
then the `sops-age` and git-auth Secrets, then Flux Operator and the
`FluxInstance`. The Cilium bootstrap must set **`gatewayAPI.enabled=false`**: the
operator validates Gateway API CRDs only at process start, and Flux's `crds`
layer has not run yet.

The node flips to `Ready` and CoreDNS and metrics-server go `Running` the moment
Cilium's agent writes a CNI conf. That is the Phase 1 gate, not this one.
