# Post-Mortems

Incident log for the `h0me` lab. One file per incident captures an **error,
stoppage, or fix action** so the root cause and remedy survive past the commit
message. Blameless: focus on the system and the signal, not the operator.

## When to write one

Open a post-mortem whenever something stopped working and needed a deliberate
fix — a Flux layer stuck not-Ready, a workload crash-looping, a PVC stuck
Pending, a cert/secret failing to render, a node down. A one-line typo fix that
never reached the cluster does not need one; a typo that *broke reconciliation*
does.

Trivial entries can be terse — the template scales down. The goal is a
searchable record of "we hit this before, here's what it was."

## Conventions

- **File name:** `_docs/post-mortems/YYYY-MM-DD-<kebab-slug>.md` (date the
  incident was resolved).
- **Template:** copy [`_template.md`](_template.md).
- **Spell out full paths and dataset segments** — never abbreviations
  (matches the repo-wide rule).
- Link the fixing commit by hash and the related ADR/runbook where one exists.
- If the fix produced reusable triage steps, add them to
  [`../runbooks/cluster-manual-intervention.md`](../runbooks/cluster-manual-intervention.md)
  and link back.
- Severity: **SEV1** cluster/data down · **SEV2** an app or layer down ·
  **SEV3** degraded / cosmetic.

## Index

| Date | Severity | Incident |
| ---- | -------- | -------- |
| 2026-06-23 | SEV2 | [Wildcard cert blocked — cf-token 1Password property mismatch](2026-06-23-cf-token-1password-property-mismatch.md) |
| 2026-06-23 | SEV2 | [iSCSI PVCs Pending — TrueNAS initiator group ID mismatch](2026-06-23-iscsi-initiator-group-mismatch.md) |
| 2026-06-23 | SEV2 | [FreshRSS volume won't attach — PV volumeHandle / zvol name mismatch](2026-06-23-freshrss-zvol-volumehandle-mismatch.md) |
| 2026-06-23 | SEV3 | [FreshRSS init — missing writable data subdirectories](2026-06-23-freshrss-missing-data-dirs.md) |
