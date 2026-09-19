# Handoff — h0me rebuild on single-node k3s (anubis)

**Date:** 2026-09-19 · **Repo:** `/home/fr3d/h0me` · **Branch:** `feat/anubis-k3s`

## What this work is

The repo describes a 6-node Talos-on-Proxmox cluster (`memphis`, env `dev`). **That hardware
is gone** — the Beelink NUCs were sold in the summer 2026 consolidation. The lab is being
rebuilt as a **single native k3s node on `anubis`** (Debian 13, `192.168.20.87`), new env
`home` / cluster `anubis`, keeping Flux, Cilium Gateway API, 1Password→ESO secrets and
TrueNAS iSCSI. A blog moves onto it later and is **out of scope**.

This is a rebuild, not a migration: no live cluster to cut over, no data to preserve.

## Read these first — do not re-derive them

| Artifact | Path / URL |
| --- | --- |
| **Implementation plan** (authoritative) | `~/.claude/plans/tidy-whistling-mountain.md` |
| Project doc in the notes vault | `~/notes/202609190219-single-node-k3s-lab-on-anubis.md` |
| Phase 0 runbook (committed) | `_docs/runbooks/anubis-host-setup.md` |
| Pull request | https://github.com/alexrf45/h0me/pull/8 |
| Commit | `9bdf005 docs(runbook): add anubis host setup for single-node k3s` |

The plan file carries the locked decisions, the CPU budget, per-phase detail, a "Resolved
decisions" section (7 former open questions, answered with evidence), a "Review corrections"
section, and the ordering hazards. **Everything below is state and process only** — the
reasoning lives in those documents.

## Where the work stopped

Phase 0 (host prep on anubis) is done through **§5**. The user paused before **§6, the k3s
install**, and will resume from there.

Facts already verified and recorded in the runbook's §0 table:

| Fact | Value |
| --- | --- |
| NIC | `enp2s0` |
| OS / kernel | Debian 13 (trixie) / `6.12.100+deb13-amd64` |
| k3s version to install | `v1.36.4+k3s1` |
| iSCSI initiator IQN | `iqn.2026-09.net.phr3d:anubis` |
| TrueNAS initiator group ID | `1` (**not** the `34` hardcoded in the repo) |
| TrueNAS portal group ID | `1` |

Verified live during the session: anubis has only SSH open; TrueNAS `192.168.20.106` has 443
and 3260 open but **no node_exporter on 9100**; there is **no `loki` peer** on the tailnet, so
the old Loki Compose stack is gone.

## Immediate next steps

1. **§6 of the runbook** — install k3s from `/etc/rancher/k3s/config.yaml`. First
   hard-to-reverse step; `k3s-uninstall.sh` (§10) is the rollback. It ends with CoreDNS and
   metrics-server **`Pending`** — correct, there is no CNI yet.
2. **§7–§9** — verify, export the kubeconfig to the 1Password secure note `anubis-kubeconfig`,
   set up the k3s datastore backup.
3. **Phase 1** — `_infra/anubis/`. Needs from the user: SOPS-encrypted tfvars, and two
   1Password item renames (`staging_flux_age_key` → `anubis_flux_age_key`,
   `flux_bootstrap_test` → `h0me_flux_git_pat`).

**The single most important Phase 1 detail:** Terraform must install **Cilium before Flux** —
with `--flannel-backend=none` there is no CNI, so Flux's own controllers would sit `Pending`
forever and never reconcile the layer that installs Cilium. That bootstrap must set
`gatewayAPI.enabled=false`, because the Cilium operator validates Gateway API CRDs only at
process start and the `crds` layer has not run yet. Flux's later upgrade flips it and restarts
the operator.

## Open decisions (neither blocks Phase 0 or 1)

- **Phone delivery for alerting**, deferred to Phase 6 by the user. In-cluster fan-out is
  settled (gatus native provider + Grafana unified alerting, no Alertmanager). Not Slack; SMS
  ruled out. Key constraint: self-hosted ntfy cannot push to iOS without relaying through
  `ntfy.sh` (APNs). Pushover is the leading alternative.
- Whether to flip PR #8 to draft (`gh pr ready --undo`) while it accumulates phases 1–8.

## Working agreements observed this session

- **Plans go to disk, never the chat window** (repo `CLAUDE.md`). Plan documents end with a
  list of unresolved questions.
- **Do not commit or push unless asked.** The user asked explicitly for the one commit and the
  PR that exist.
- **Terraform is run by the user**, via the 1Password CLI. `remote-exec` is forbidden, so host
  work lives in runbooks rather than TF.
- **The user encrypts SOPS files.** Never modify or re-encrypt secrets.
- All cluster access goes through the `kube` / `k8sop` wrappers — never raw `kubectl`, `flux`,
  `helm`. Env→cluster map becomes `home → anubis`. `flux --with-source` breaks through the
  wrapper (single-use pipe) — issue two separate calls.
- Standalone `kustomize` is **not installed**: use `kube <env> kustomize <dir>`, with **no
  `build` subcommand**. Leftover `${VAR}` in rendered output is expected, not a failure.
- The user edits files between turns. `_docs/runbooks/anubis-host-setup.md` was overwritten
  once, reverting a correction; flag such changes rather than silently re-applying.
- Verify claims against the actual files and hosts before asserting them. Two of this
  session's most useful findings came from probing rather than reading.

## Corrections made during the session — do not reintroduce

- **rp_filter needs no host configuration.** systemd's `50-default.conf` already excludes
  `net.ipv4.conf.all.rp_filter` from its glob, and effective rp_filter is
  `max(conf.all, conf.<iface>)`, so setting it by hand is a no-op. Cilium's
  `apply-sysctl-overwrites` init container owns `lxc*`/`cilium_*`.
- **Empty `iscsiadm -m discovery` output is the expected result** at this stage. Under dynamic
  provisioning democratic-csi creates the zvol, target and extent at first PVC, so no target
  exists until the storage phase.
- **TrueNAS Base Name must stay distinct from the initiator IQN.** The user had set them equal;
  it was reverted.

## Suggested skills

| Skill | When |
| --- | --- |
| `terraform-engineer` | Phase 1, writing `_infra/anubis/`. Fetch live provider docs — the repo's rules forbid relying on cached syntax, and pinned majors must be verified. |
| `flux-gitops-patterns` | Phase 2, building `_clusters/home/` and the layer DAG |
| `flux-operations` | Phases 2–7, reconciling layers as they land |
| `flux-troubleshooting` | When a Kustomization or HelmRelease stalls. Note: a HelmRelease that exhausted `remediation.retries` will **not** retry on its own — needs `--reset`. |
| `kubernetes-specialist` | Phases 4–7, workload and networking manifests |
| `k8s-network-troubleshooting` | Phase 4, if the Gateway never gets an address or L2 announcement misbehaves |
| `documentation-and-adrs` | Phase 8's ADRs (dynamic iSCSI provisioning, capacity budget, CoreDNS approach) and the amendments to existing decisions |
| `lint` | Before every commit — a `PostToolUse` hook already runs yamllint on `*.yaml` |
| `cluster-health` | Once the cluster is up. The command still hardcodes `talosctl health` and needs rewriting in Phase 8. |

Avoid `k8s-platform-tenancy`, `k8s-continual-improvement` and `kubernetes-architect` for this
work — they assume multi-tenant or multi-node capacity planning, and the architect skill
explicitly disclaims single-node setups.

## Repo hygiene note

`prompt.txt` and `specs.txt` are untracked in the repo root. The plan slates them for deletion
in Phase 8; they were deliberately left alone and kept out of the commit.
