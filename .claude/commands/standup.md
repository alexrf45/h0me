Situational session-start briefing: reconcile the punch list against **live cluster state** and **recent config churn**, judge what's stable vs. shaky, flag design choices that warrant a formal decision/ADR doc, then recommend whether to **resume** in-flight work or **pick up** something fresh — and start it.

This is the cluster-aware sibling of `/sprint-menu`. Where `/sprint-menu` trusts the last review and never touches the cluster, `/standup` **does a lightweight live survey** and is biased toward "what's the real state right now, what's unverified, what do I need to decide before I build more". It is **read-only** — it writes nothing except (optionally) a new ADR the user explicitly asks for, and it does NOT produce a dated review doc (that's `/lab-review`). If an argument is given (`/standup <theme>`, e.g. `flux`, `storage`, `security`), bias the survey and recommendations toward that theme.

## Steps

1. **Load the tracker.** `ls _docs/reviews/h0me-review-*.md` → read the newest. Its **Open Items Punch List** + **Suggested Next Sprint** are the baseline. Also check auto-memory `MEMORY.md` for the canonical pointer and any `*-in-flight` notes (e.g. migrations mid-landing).

2. **Detect in-flight work** (the "resume" axis):
   - `git status -s` — uncommitted/untracked changes (half-landed work the user may want to finish/commit).
   - `git log --oneline --no-merges --since="<review date>"` — what landed since the baseline that the review predates.
   - Any `_docs/migrations/*` or `_docs/decisions/*` added recently, and memory `*-in-flight` notes — these are explicit "resume me" candidates.

3. **Survey the live cluster** (read-only, via the `~/.zsh/kubeop.sh` wrappers ONLY — never raw `kubectl`/`flux`; see CLAUDE.md → kube-wrapper rule). Keep it light — this is a pulse check, not `/lab-review`:
   ```bash
   source ~/.zsh/kubeop.sh
   kube dev get nodes -o wide
   kube dev get kustomizations -n flux-system
   kube dev get hr -A
   kube dev get pods -A | grep -Ev '(Running|Completed)'
   kube dev get certificate -A
   kube dev get pvc -A
   ```
   If a wrapper isn't sourced, `source ~/.zsh/kubeop.sh` first. If the cluster is unreachable (e.g. stale kubeconfig after a rebuild — try `kube-flush` first), say so and continue from repo state alone, flagging the access gap as the top item.

4. **Form a stability read.** Cross-reference the survey against recent churn and call out, specifically:
   - Anything not Ready / not Running / restarting; certs on the staging issuer; idle operators (0 CRs); unexpected/missing pods.
   - **Recently changed but unverified** config — e.g. a migration that landed but hasn't survived a teardown/rebuild, a pre-release/pinned chart version, a manual fix not yet codified (manual node labels vs. declared, a hand-applied patch), a bootstrap-then-adopt handoff not yet re-tested.
   - Drift between declared intent and live state (Helm values vs. running, inline-bootstrap vs. HelmRelease).
   State each as: `observation · why it matters · is it blocking / latent-risk / cosmetic`.

5. **Flag decision/ADR candidates.** Surface design choices that are currently **implicit, contested, or load-bearing-but-undocumented** and deserve a standalone `_docs/decisions/<slug>.md` ADR rather than living only in a migration note or commit message. Heuristics: a choice that gates a rebuild, has non-obvious tradeoffs, was reached after a failure, or that a future session would likely re-litigate. For each: one-line problem statement + why it warrants an ADR. Do **not** write the ADR unless the user picks that option in step 7.

6. **Recommend options — resume vs. pick up.** Synthesize from steps 1–5:
   - **Resume (in-flight)** — finish/commit/verify work already started (uncommitted changes, a migration awaiting its rebuild check, an unlanded fix). Lead here if something is half-done or unverified.
   - **Pick up (fresh)** — themed bundles from the punch list, leading with the review's "Suggested Next Sprint #1". Per bundle: name · item IDs · rough effort · blast radius · one-line "why now". Keep high-risk/multi-day work standalone.
   - **Decide first** — draft one of the ADRs from step 5, when a fork blocks sensible sprint choice.

7. **Ask, then start.** Use AskUserQuestion to drive the fork, with questions **grounded in this session's findings** (steps 4–5), e.g.: "Verify the node-label change survives a rebuild before new work, or proceed?", "Cilium is on a pre-release pin — pin to stable as its own task, or accept and move on?", "Promote <design choice> to an ADR now?". Put the recommended option first, labeled (Recommended). Offer at least: the lead resume item, the lead pickup sprint, "single task", and "draft an ADR first". Honor the selection.
   - On a sprint that bundles ≥2 independent (no file-overlap) tasks, mention `/sprint-orchestrate <ids...>` as a parallel-execution alternative.
   - Then begin: `TaskCreate` for the chosen work, mark the first item in_progress, and proceed under CLAUDE.md rules (wrappers only; no SOPS/secret edits without confirmation; symptom → read config/logs → hypothesis → fix, no speculative iteration; run `/lint` + offline `kube dev kustomize <dir>` before calling a change done; don't commit unless asked — 1Password SSH signing).

## Notes
- Read actual config/logs/live state before asserting status — mark unknowns ❓, don't guess (CLAUDE.md → Code Fixes).
- This command reads; it mutates nothing on its own. The only write it may make is a new ADR the user explicitly requests in step 7; cluster/repo side effects come only from the work the user then picks.
- Defer to `/lab-review` when the newest review is stale (>~5 days or many commits since) — offer it, but still give the briefing from current state.
- Keep it terse and skimmable. The review doc is the canonical detail; cite item IDs so the user can drill in.
- Distinct from siblings: `/lab-review` writes the dated tracker; `/sprint-menu` picks from it offline; `/standup` reconciles it with the live cluster and surfaces stability + decision risk before choosing.
