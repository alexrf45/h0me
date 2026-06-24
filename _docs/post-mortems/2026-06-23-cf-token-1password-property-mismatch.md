# Post-Mortem — Wildcard cert blocked by cf-token property mismatch

- **Date resolved:** 2026-06-23
- **Severity:** SEV2
- **Component:** `networking` — cert-manager ClusterIssuer / ExternalSecret `cf-token`
- **Fix commit:** `3ccae18`
- **Related:** review item N3 in `_docs/reviews/h0me-review-2026-06-23.md`

## Symptom

The Cloudflare DNS-01 ClusterIssuer could not issue the wildcard certificate.
The `cf-token` ExternalSecret in `_lib/networking/clusterissuers/cf-secrets.yaml`
failed to sync because the requested 1Password property did not exist on the item.

## Impact

Wildcard TLS unavailable until resolved — any HTTPRoute relying on the issued
cert had no valid certificate.

## Root cause

The ExternalSecret `remoteRef` pointed at item `cf_token_th0th.dev` with
`property: cloudflare-token`. The 1Password item exposes the token under the
field named `credential`, not `cloudflare-token`. The `secretKey` (the Kubernetes
side) was already `cloudflare-token`; only the remote property name was wrong.

## Fix

In `_lib/networking/clusterissuers/cf-secrets.yaml`, changed
`remoteRef.property` from `cloudflare-token` to `credential`. The Kubernetes
`secretKey` was left as `cloudflare-token`.

## Detection & verification

```sh
kube dev -n <ns> get externalsecret cf-token
# STATUS should be SecretSynced / Ready=True
```

## Prevention / follow-up

When wiring an ExternalSecret, confirm the **remote field name** against the
1Password item itself — the Kubernetes `secretKey` and the 1Password `property`
are independent and frequently differ. Reference 1Password item/field names only,
never values.
