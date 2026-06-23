Surface a pick-list of candidate **sprints**, **tasks**, and **open questions** at the start of a session, sourced from the newest lab review, then start whatever the user selects.

This is the session-kickoff / triage command. It does **not** survey the live cluster — it trusts the latest `/lab-review` output. If that review is stale, it says so and offers to run `/lab-review` first. If an argument is given (`/sprint-menu <theme>`, e.g. `security`, `storage`, `observability`, `quick`), filter the listing to that theme/tier.

## Steps

1. **Load the tracker.** `ls _docs/reviews/h0me-review-*.md` and read the newest. That doc's **Open Items Punch List** + **Suggested Next Sprint** are the source of truth. Do NOT re-survey the cluster — that's `/lab-review`'s job.

2. **Staleness check.** Compare the review's date (filename / header) to today, and run `git log --oneline --no-merges --since="<review date>"`. If the review is more than ~5 days old, or there are substantive commits it predates, flag it: "Newest review is `<date>` (`<N>` days old, `<M>` commits since) — want me to run `/lab-review` first?" Proceed with the listing regardless unless the user asks to refresh.

3. **Synthesize three groups** from the punch list (skip items marked ✅ or ~~struck~~; list ⏸️ deferred separately only if relevant):
   - **Sprints (3–4)** — themed bundles of related open items that make sense to do together in one session. **Lead with the review's "Suggested Next Sprint #1".** For each: a short name, the item IDs it covers, rough effort (½-day / 1-day / multi-day), blast-radius/risk, and a one-line "why now". Keep high-risk or multi-day work (e.g. the storage S-tier, a CNPG migration) as its own standalone sprint — never bundle it onto a grab-bag day.
   - **Tasks** — discrete open items worth doing on their own: `ID · what · file path · next action`. **Flag quick wins** (<30 min, low risk, reversible) explicitly.
   - **Questions** — decision forks and clarifications to resolve before/while working: anything marked ❓ in the review, "decide X first" notes embedded in next-actions (e.g. CRD-ownership, which-app-first), and scope ambiguities. These shape the work — surface them so the user can answer or defer.

4. **Present + pick.** Output the three groups compactly (IDs + one line each — the detail lives in the review doc; cite it so the user can drill in). Then use an interactive picker (AskUserQuestion) offering: the candidate sprints, a "single task" choice, and an "answer a question first" choice. Put the recommended sprint (the review's #1) first and label it (Recommended). Honor the selection. If the chosen sprint bundles ≥2 independent tasks (no file overlap among the IDs), mention `/sprint-orchestrate <ids...>` as a parallel-execution alternative — the user can still pick sequential if they want closer supervision.

5. **Start the selected work.**
   - Create a task list (TaskCreate) for the chosen sprint/task; mark the first item in_progress.
   - Follow CLAUDE.md: cluster access via the `kube` / `k8sop` wrappers ONLY (never raw `kubectl`/`flux`/`helm`/`kustomize build` against the cluster); don't modify SOPS/`.env`/secrets without explicit confirmation; verify before asserting (symptom → read config/logs → hypothesis → fix, no speculative iteration).
   - Run the project's local checks (`/lint`, offline `kubectl kustomize <dir>`, tests) before calling a change done.
   - Do NOT commit unless the user asks — commits may need 1Password SSH signing.

## Notes
- This command reads; it doesn't mutate the cluster or repo on its own. Side effects come only from the work the user picks.
- If a tier has no open items, omit it rather than padding.
- Keep the menu terse. The review doc (`_docs/reviews/h0me-review-<date>.md`) is the canonical detail.
- The picker is for choosing what to start, not for plan approval — once chosen, just begin (use a Plan only if the selected work is non-trivial and needs alignment).
