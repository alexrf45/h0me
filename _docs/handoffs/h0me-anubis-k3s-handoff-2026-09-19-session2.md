# Handoff — h0me on anubis, session 2 (phase 0 complete)

**Date:** 2026-09-19 · **Repo:** `/home/fr3d/h0me` · **Branch:** `feat/anubis-k3s`

Continues `_docs/handoffs/h0me-anubis-k3s-handoff-2026-09-19.md`. Read that first —
it holds the background this doc does not repeat.

## Read these first — do not re-derive

| Artifact | Path / URL |
| --- | --- |
| **Implementation plan** (authoritative) | `~/.claude/plans/tidy-whistling-mountain.md` |
| Previous handoff | `_docs/handoffs/h0me-anubis-k3s-handoff-2026-09-19.md` |
| Phase 0 runbook | `_docs/runbooks/anubis-host-setup.md` |
| h0me PR (open) | https://github.com/alexrf45/h0me/pull/8 |
| nix-config PR (merged) | https://github.com/alexrf45/nix-config/pull/38 |

Rationale for every change this session is in the commit messages on PR #8. They are
long on purpose — read them rather than re-deriving from the diff.

## What changed this session

**Phase 0 is complete.** k3s is installed on anubis, the kubeconfig is in the
1Password note `anubis-kubeconfig`, and `kube home get nodes` works from thoth.

Three problems were found and fixed:

1. **The runbook predicted a `Ready` node.** It cannot be: `flannel-backend: none`
   means nothing writes `/etc/cni/net.d`, and kubelet will not report `Ready`
   without a CNI — the same absence that leaves CoreDNS `Pending`. §7 now expects
   `NotReady` and carries a table separating that from PLEG / disk-pressure /
   certificate failures. **User confirmed the live node matches the expected
   message.** It flips to `Ready` in Phase 1 when Cilium lands.
2. **The `kube` wrapper was zsh** and thoth migrated to bash on 2026-09-13, so
   `kube` was undefined in every shell. Ported to bash, `home → anubis` added,
   `dev → memphis` removed. `_hack/scripts/kubeop.sh` is the source of truth.
3. **The k8s tooling was gone** — dropped in nix-config `39c1978` when memphis was
   decommissioned. Restored as a Home Manager module; the user has rebuilt and all
   eight binaries are on PATH.

The kubeconfig note originally still said `server: https://127.0.0.1:6443` — §8's
rewrite to `192.168.20.87` had been missed. The user fixed it.

## Repo state

| Repo | Branch | State |
| --- | --- | --- |
| `h0me` | `feat/anubis-k3s` | 4 commits ahead of main, **pushed**, on PR #8 |
| `nix-config` | `main` | PR #38 merged (horus retirement) |
| `nix-config` | `feat/k8s-tooling` | commit `55184db`, **local only — never pushed, no PR** |

`h0me` working tree is clean apart from untracked `prompt.txt` and `specs.txt`
(deliberate — the plan deletes them in Phase 8).

## Immediate next steps

1. **Push `feat/k8s-tooling` and open a PR** in nix-config. It is committed and
   verified (`nixos-rebuild build --flake .#thoth`, `nix fmt`, both clean) but
   exists only on the user's disk. Note the `thoth` shell alias rebuilds from
   `github:alexrf45/nix-config#thoth` — the *remote* — so the module will not
   survive a rebuild via that alias until it is merged.
2. **Verify runbook §9** — the k3s datastore backup cron. It was never discussed
   this session and its status is **unknown**. sqlite means cluster state is one
   unreplicated file; do not start Phase 1 without checking.
3. **Phase 1 — `_infra/anubis/`.** Needs from the user: SOPS-encrypted tfvars, and
   two 1Password item renames (`staging_flux_age_key` → `anubis_flux_age_key`,
   `flux_bootstrap_test` → `h0me_flux_git_pat`). The ordering hazard — Cilium
   before Flux, with `gatewayAPI.enabled=false` — is in the plan and at the end of
   the runbook. Do not re-derive it.

## Known-open, none blocking

- **`/lint` is broken.** `.claude/commands/lint.md` runs `yamllint -c .yamllint.yaml .`
  but no such config is tracked, so it fails outright; the `PostToolUse` hook passes
  no `-c` and falls back to defaults, where an 80-char limit flags most of `_lib`
  (36 violations in the two observability files alone). Fixing it means choosing a
  lint policy — the user's call.
- **49 `kube dev` references remain** in 7 post-mortems, 3 reviews, 2 migrations and
  the two `2026-06-23` decision records. Left deliberately: they describe what was
  run against memphis. Phase 8 amends the decisions.
- `/cluster-health` still hardcodes `talosctl health`; Phase 8 rewrites it.
- `overlays/dev`, `_clusters/dev` and the `<app>-dev-cluster` CNPG names are
  unchanged and still correct on disk. Renaming is Phase 2, not a loose end.
- Phone delivery for alerting still deferred to Phase 6. Pushover leading.

## Working agreements (carried forward, all still observed)

- **Do not commit or push unless asked.** Every commit this session was requested.
- Plans go to disk, never the chat window; they end with unresolved questions.
- Terraform is run by the user via the 1Password CLI. `remote-exec` is forbidden.
- The user encrypts SOPS files. Never modify or re-encrypt secrets.
- All cluster access goes through `kube` / `k8sop`. Never raw `kubectl`.
- The user edits files between turns — flag changes rather than silently reapplying.

## Environment gotchas that cost time

- **`op` is not signed in inside agent shells** and `SSH_AUTH_SOCK` is unset. Export
  `SSH_AUTH_SOCK=/home/fr3d/.1password/agent.sock` for any git operation (commits are
  SSH-signed) or `ssh`. There is no way to inherit the user's `op` session, so live
  cluster checks must be handed to the user.
- Commits verify as `Good signature … No principal matched` (trust flag `U`). That is
  a missing local `gpg.ssh.allowedSignersFile`, not a signing failure.
- nix flake evaluation ignores untracked files — `git add -N` a new `.nix` file before
  `nixos-rebuild build`, or it will not be seen.
- `zsh` is **not installed** on thoth. `~/.zshrc` and `~/.zsh/` do not exist.

## One lesson worth not repeating

A bug shipped in the bash port because a test asserted on the kubeconfig *path*
(`/dev/fd/63`) without ever reading the file. It was delivering **zero bytes**, and
kubectl silently fell back to `localhost:8080`. **Assert on content, not on a
filename.** Fixed in `f5e19cc`; the trap is documented in the script so it does not
get "simplified" back.

## Suggested skills

| Skill | When |
| --- | --- |
| `terraform-engineer` | Phase 1, writing `_infra/anubis/`. Fetch live provider docs; repo rules forbid cached syntax and pinned majors must be verified. |
| `flux-gitops-patterns` | Phase 2, building `_clusters/home/` and the layer DAG |
| `flux-operations` | Phases 2–7, reconciling layers as they land |
| `flux-troubleshooting` | When a Kustomization or HelmRelease stalls. A HelmRelease that exhausted `remediation.retries` will **not** retry on its own — needs `--reset`. |
| `kubernetes-specialist` | Phases 4–7, workload and networking manifests |
| `k8s-network-troubleshooting` | Phase 4, if the Gateway never gets an address or L2 announcement misbehaves |
| `documentation-and-adrs` | Phase 8 ADRs and the amendments to the two 2026-06-23 decisions |
| `lint` | Before every commit — but see the `/lint` breakage above |
| `cluster-health` | Once Cilium is up. Still hardcodes `talosctl`. |

Avoid `k8s-platform-tenancy`, `k8s-continual-improvement` and `kubernetes-architect`
— they assume multi-tenant or multi-node capacity planning, and the architect skill
explicitly disclaims single-node setups.

For nix work, the `nix-config` repo carries its own skills at
`~/nix-config/.claude/skills/` (`nixos-best-practices`, `nixos-patterns`) and rules at
`~/nix-config/.claude/rules/common/`. The user asked that these be consulted for any
nix change. Verification there means `nix fmt` (alejandra) plus
`nixos-rebuild build --flake .#thoth` — there is no test suite.
