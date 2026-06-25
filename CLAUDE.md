# h0me

h0me is a self hosted home lab used for learning and hosting open source applications.

## Stack

reference `_docs/lab_architecture.md`

## Key Directories

| Directory     | Purpose                                                                                                                       |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `_clusters/`  | Cluster entrypoints — Flux reads `_clusters/<env>` to start reconciliation                                                    |
| `_lib/`       | Shared manifests, organized by deployment layer (controllers, pki, secrets, networking, dns, storage, security, applications) |
| `_global/`    | CRDs applied across all clusters (Prometheus Operator, CNPG)                                                                  |
| `_infra/`     | Cluster provisioning (Talos on Proxmox, wallabag S3 backup infra)                                                             |
| `_templates/` | Boilerplate for HelmRelease, HelmRepository, Kustomization resources                                                          |
| `_hack/`      | One-off scripts and example YAML                                                                                              |
| `_docs/`      | Reviews, runbooks, migration notes                                                                                            |

## Commands

Slash commands live in `.claude/commands/`:

| Command                  | Purpose                                      |
| ------------------------ | -------------------------------------------- |
| `/lint`                  | Run yamllint across the repo                 |
| `/flux-reconcile [name]` | Reconcile a Flux kustomization (or list all) |
| `/flux-status`           | Show state of all Flux resources             |
| `/cluster-health`        | Check pod and Talos node health              |
| `/terraform-plan`        | Init + plan the dev cluster                  |
| `/terraform-apply`       | Init + plan + apply the dev cluster          |

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.

## General Business Rules

- ALWAYS write plans to disk for human review, do not output to the chat window
- Present 2-3 options in a plan document with clear benefits & tradeoffs
- If uncertain about any tradeoffs or benefits:
  - Ask clarifying questions before proceeding
  - Present options with pros/cons rather than guessing

## File Editing

- Always Read a file before attempting to Edit it (Edit tool requires prior Read)

## Git SSH Agent

Git commits may require SSH signing via 1Password agent. If a commit fails with signing errors, inform the user rather than retrying — they need to authenticate manually.
