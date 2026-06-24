Produce a fresh, dated state-of-the-lab review at `_docs/reviews/h0me-review-<YYYY-MM-DD>.md`, structured like the most recent existing review, so the user can hop back into the project with a clear punch list of open items.

This is the rolling deployment/migration tracker. Each run supersedes the last review doc (don't delete the old one — it's the historical record).

## Steps

1. **Find the baseline.** `ls _docs/reviews/h0me-review-*.md` — read the newest one. For carried-forward context, the canonical docs now live in the restructured tree: ADRs in `_docs/decisions/`, the patterns/lessons in `_docs/guides/best-practices.md`, the narrative in `_docs/journey.md`, and long-form originals in `_docs/archive/source-docs/`. The baseline's structure is the template for the new doc.

2. **Survey the repo state** (read, don't guess):
   - `git log --since="<date of last review>" --oneline --no-merges` and a rough count — what's the headline work since the baseline?
   - `_clusters/dev/cluster.yaml` — Flux DAG / layer changes
   - `_clusters/dev/config/cluster-configs.yaml` — app versions, subdomains, params
   - `_lib/*/kustomization.yaml` — what's enabled vs. commented out (especially `_lib/security/`, `_lib/controllers/`, `_lib/observability/`)
   - `_lib/applications/*/base/` — securityContext, probes, namespace labels, resource limits per app
   - `grep -rl "kind: PodDisruptionBudget\|kind: ResourceQuota\|kind: LimitRange" _lib global` — resilience-primitive coverage
   - new/abandoned directories (dead code, placeholder dirs, stale policies)
   - `terraform/dev/` — note any module changes vs. the baseline's Terraform section

3. **Survey the live cluster** (all via the `~/.zsh/kubeop.sh` wrappers — see CLAUDE.md → "Cluster access"; never raw `kubectl`/`flux`):

   ```bash
   source ~/.zsh/kubeop.sh
   kube dev get nodes -o wide
   kube dev get kustomizations -n flux-system
   kube dev get hr -A
   kube dev get pods -A | grep -Ev '(Running|Completed)'
   kube dev get certificate -A
   kube dev get pvc -A
   ```

   Flag: anything not Ready, the wildcard cert's issuer (staging vs prod), idle operators (deployed with zero CRs), high restart counts, unexpected pods.
   If a wrapper isn't sourced (`_kubeop_cluster_for_env: command not found`), `source ~/.zsh/kubeop.sh` first. If the cluster is unreachable, say so and produce the review from repo state alone.

4. **Write `_docs/reviews/h0me-review-<today>.md`.** Mirror the baseline's sections. At minimum:
   - **Executive Summary** — headline change since the baseline; what moved, what didn't; recommended next sprint in one sentence.
   - **What Changed Since `<baseline date>`** — table: area · old state · new state.
   - **Live Cluster Snapshot** — compact dump of the survey above, with the notable items called out.
   - **Open Items Punch List** — the core deliverable. Carry forward every unresolved item from the baseline (keep its ID), mark resolved ones ✅, add new findings with new IDs. Group by tier (CRITICAL / HIGH-security / MEDIUM-resilience / observability follow-ups / hygiene-cleanup / terraform / manual-non-GitOps). **Every open item gets: ID · what · status · exact file path(s) · concrete next action + how to verify.** Be specific enough that a future session can act without re-investigating.
   - **Thoth / future-app status** — pre-decision tracking; where to pick up.
   - **Suggested Next Sprint** — ordered, with natural cut points.
   - **Files Referenced** — path · why it matters.

5. **Update auto-memory** — refresh the relevant memory file(s) and make sure `MEMORY.md` points at the new review doc as the canonical open-items tracker (replace the pointer to the superseded one).

6. **Report back** a short summary: headline changes, count of items resolved vs. still-open vs. newly-found, and the top 2–3 next actions. Do **not** commit — leave that to the user (commits may need SSH signing via 1Password).

## Notes

- Read actual config/logs before asserting status — no speculation (CLAUDE.md → "Code Fixes"). If you can't verify something, mark it ❓ rather than guessing.
- Tone: terse, factual, actionable. This doc exists to be re-read cold months later.
- Don't propose fixes inline beyond the one-line "next action" per item — the review is a tracker, not an implementation plan.
