## Secrets Management

**Secrets (SOPS):** Never modify or re-encrypt `.env` files, SOPS-encrypted files, or secrets without explicit user confirmation. The user manages secrets themselves. SOPS config is at `_clusters/dev/.sops.yaml` — files matching `*values.yaml` are fully encrypted; other YAML files encrypt only `data` and `stringData` fields.

## Secret Handling

- NEVER pipe live credentials through ad-hoc jq/sed redaction filters in conversation
- When discussing secrets, reference 1Password item names only, never values
- If a redaction filter is needed, test it against fake data first
