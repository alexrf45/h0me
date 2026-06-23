Parallel sprint executor. Takes a list of punch-list IDs from the newest `_docs/reviews/home-0ps-review-*.md`, classifies them by file overlap, spawns one Task subagent per independent task in its own git worktree, drives each through an acceptance-test loop (cap 5), persists progress to `.claude/sprint-state.json`, and opens a PR into `dev` per passing task.

Pairs with `/sprint-menu` (the picker). The picker chooses; this command executes. If invoked with no arguments, resume from the state file.

## Usage

```
/sprint-orchestrate <task-id> [<task-id> ...]   # start fresh
/sprint-orchestrate                              # resume from .claude/sprint-state.json
/sprint-orchestrate --cap 3 <id> <id>            # override attempt cap (default 5)
/sprint-orchestrate --abort                      # mark all in_progress tasks aborted, leave worktrees for inspection
```

Task IDs are the punch-list IDs from the newest review (`H-3`, `O-9`, `R5`, etc.).

## Steps

### 1. Load context

- Read the newest `_docs/reviews/home-0ps-review-*.md` — that's the source of truth for each task's *what*, *file paths*, and *next action*.
- If `.claude/sprint-state.json` exists and the user passed no IDs, treat it as a **resume**: re-read it, skip steps 2–3, jump to step 4 with the existing task records.

### 2. Classify by file overlap

For each requested task ID:

- Pull the row from the review's "Open Items Punch List" and any "Files Referenced" entries that mention the ID. Build a candidate **touch set** = paths explicitly named in those entries.
- Also `git grep -l "<ID>" _docs/reviews/ _docs/decisions/ _docs/guides/` for fuzzy matches that might name relevant files.
- Edges: tasks share an edge iff their touch sets intersect on at least one file under `_lib/`, `_clusters/`, `global/`, or `terraform/`. Touches to `_docs/`, `.claude/`, or `.github/` don't count as overlap (low coupling risk).

Result: a **wave 1** set (no edges among themselves) and one or more **later waves** for tasks that overlap with wave 1.

### 3. Print the plan and pause

Output, then **pause for explicit "go"**:

```
Plan:
  Wave 1 (parallel, N tasks):
    - H-3 — Falco — touch set: _lib/controllers/falco/, global/crds/falco/
    - O-9 — postgres-exporter dashboards — touch set: _lib/observability/dashboards/
  Wave 2 (sequential after wave 1, M tasks):
    - O-8 — default-deny CCNP — depends on H-3 (touches _lib/security/)
Cap: 5 attempts per task. PR target: dev.
```

Do not spawn anything until the user says go.

### 4. Spawn one subagent per wave-1 task (in parallel)

For each task in the current wave, before spawning:

- `git worktree add /tmp/sprints/<task-id> -b sprint/<task-id> dev` (idempotent — if the worktree exists and is on the right branch, skip).
- `mkdir -p .claude/sprints/<task-id>` (in the **main** working tree, not the worktree — sprint state is tracked alongside the orchestrator, not inside each branch).

Spawn `Agent(subagent_type=general-purpose, run_in_background=true)` for each. Use a self-contained prompt per agent — they have no shared memory with the orchestrator. The prompt must include:

- The task's full punch-list row from the review (quoted verbatim — don't paraphrase).
- The touch-set hints from step 2.
- The worktree path: `/tmp/sprints/<task-id>` — **do all editing there**, not in the main tree.
- The branch name: `sprint/<task-id>` — already checked out in the worktree.
- The iteration loop spec (below).
- The wrapper rules from `CLAUDE.md` (`kube`/`k8sop`, never raw `kubectl`/`flux`/`helm`).
- "Do not push. Do not open PRs. Commit on the branch only — the orchestrator handles publication."

### 5. Per-subagent iteration loop spec

The subagent prompt instructs:

1. **Write `.claude/sprints/<task-id>/accept.sh` FIRST** (before any implementation edits). The script must:
   - Be `#!/usr/bin/env bash` with `set -euo pipefail`.
   - Run yamllint on touched paths (`yamllint -c .yamllint.yaml <paths>`).
   - Run `kube dev kustomize <relevant-overlay-or-base>` and check that output rendered (non-empty, no `${...}` placeholder leakage where final-form is expected).
   - Assert any manifest invariants the task requires (use `yq`/`jq` against the kustomize output — e.g. "PodMonitor exists for `<svc>`", "NetworkPolicy `<name>` selects `<labels>`").
   - Optionally include **one read-only `k8sop dev` probe** for evidence of current cluster state (e.g. `k8sop dev kubectl get podmonitor -n monitoring <name>` — read-only, doesn't mutate).
   - Exit non-zero on any failure.
   - **No `kubectl apply`, no `flux reconcile`, no `helm install`, no pushes.** Static + read-only only.
2. Stage the implementation: edit files under the worktree, `git add`, commit with `feat(<area>): <one-line>` style matching `git log --oneline` history.
3. Run `bash .claude/sprints/<task-id>/accept.sh`. If exit 0 → done, mark `passed`. If exit non-zero → re-diagnose (read failing output, form a new hypothesis per `.claude/rules/code.md`), iterate. **Do not stack speculative fixes.**
4. Cap: 5 attempts. On cap-hit, mark `cap_reached` with the last failure recorded.

After each attempt the subagent must update its slot in `.claude/sprint-state.json` (see schema below). The orchestrator polls this file; agents own their own rows.

### 6. State file schema

`.claude/sprint-state.json` (gitignored, written at runtime):

```json
{
  "review_doc": "_docs/reviews/home-0ps-review-2026-05-27.md",
  "started_at": "2026-05-28T14:00:00Z",
  "cap": 5,
  "pr_target": "dev",
  "tasks": [
    {
      "id": "H-3",
      "branch": "sprint/h-3",
      "worktree": "/tmp/sprints/h-3",
      "wave": 1,
      "touch_set": ["_lib/controllers/falco/", "global/crds/falco/"],
      "attempts": 3,
      "status": "in_progress|passed|cap_reached|aborted",
      "last_failure": "yamllint: line too long at falco/values.yaml:42",
      "pr_url": null
    }
  ]
}
```

Resume = re-read this, skip already-passed tasks, re-spawn `in_progress`/`cap_reached` tasks if the user wants.

### 7. Publication (per passing task)

When a subagent reports `passed`:

1. Verify the worktree's HEAD acceptance test still passes: `(cd /tmp/sprints/<id> && bash .claude/sprints/<id>/accept.sh)`.
2. `git -C /tmp/sprints/<id> push -u origin sprint/<id>`.
3. `gh pr create --base dev --head sprint/<id> --title "<id>: <one-line>" --body "$(cat <<EOF
## Closes
<task ID and review-doc anchor>

## Acceptance test
\`\`\`bash
$(cat .claude/sprints/<id>/accept.sh)
\`\`\`

## Worktree
\`/tmp/sprints/<id>\` (cleaned up after merge)
EOF
)"`.
4. Update `tasks[].pr_url` in the state file.

If `gh pr create` fails (auth, signing, etc.), surface to the user — don't retry. Per `.claude/rules/git-ssh-agent.md`, the user authenticates manually.

### 8. Cleanup

After all waves complete (or `--abort`):

- Print a summary: passed / cap_reached / aborted, with PR URLs.
- Leave worktrees in place for the user to inspect. Suggest the cleanup command per task: `git worktree remove /tmp/sprints/<id> && git branch -D sprint/<id>`.

## Guardrails

- **Never spawn a subagent for a task whose touch set overlaps with another `in_progress` task in the same wave.** That's a classification bug — print and stop.
- **Never push from the orchestrator before the subagent's acceptance test passes locally.** A failing test stays a worktree-only commit.
- **Respect `.claude/rules/secrets.md`:** subagent prompts must not touch SOPS-encrypted files or `.env`. Add this to every spawned prompt.
- **The CI check** (`.github/workflows/sprint-accept.yml`) re-runs `accept.sh` on the PR before merge — that's the second gate. If it fails in CI but passed locally, suspect cluster-drift / out-of-band edits and treat as a regular bug.

## Notes

- The orchestrator does NOT run `/lab-review`. If the newest review is stale, surface that and let the user choose to refresh first (same staleness check as `/sprint-menu`).
- Subagents inherit no skills. If a subagent's task needs a specific skill (e.g. CNPG work → `flux-operations`), name it in the prompt so the subagent invokes it via `Skill`.
- This command is opinionated about a GitOps-Flux-against-`dev` workflow. The acceptance test is **static + read-only probe** by design — cross-cluster integration is verified post-merge by Flux reconcile + Gatus + alerts, not here.
