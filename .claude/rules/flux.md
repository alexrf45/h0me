## Flux reconciliation layers (dependency order)

Defined in `_clusters/dev/cluster.yaml`. Each layer depends on the one above it:

1. **cluster-config** — ConfigMap with environment variables (`ENVIRONMENT`, `CLUSTER_NAME`, hostnames, etc.) used by `postBuild.substituteFrom` in downstream Kustomizations
2. **crds** — Global CRDs from `_global/crds/`
3. **controllers** — All operators: cert-manager, CloudNativePG, external-secrets, Falco, Kyverno, mariadb-operator, redis-operator, Renovate
4. **pki** — Internal CA keypair, trust-manager, trust bundle
5. **external-secrets-operator** — ESO deployment (depends on controllers + pki for mTLS)
6. **secrets** — 1Password Connect deployment + ClusterSecretStore
7. **networking** — Cilium Gateway, Tailscale operator, ClusterIssuers (Let's Encrypt via Cloudflare DNS-01)
8. **dns** — ExternalDNS (depends on secrets for Cloudflare API key)
9. **storage** — freenas-iscsi CSI, local-path provisioner, Barman Cloud
10. **security** — Cilium NetworkPolicies, Kyverno policies
11. **applications** — App workloads (currently only wallabag, using `_lib/applications/wallabag/overlays/dev`)

## Bootstrap (Flux Operator)

Flux is bootstrapped by the **Flux Operator**, not the classic `flux bootstrap` /
`flux_bootstrap_git`. Terraform (`_infra/memphis/main.tf`) installs two Helm releases
once — `flux-operator` and `flux-instance` (the `FluxInstance` CR, name `flux`, whose
`spec.sync` points a GitRepository `flux-system` at `_clusters/dev`) — plus the
`sops-age` and git-auth secrets. Those same releases are then represented in Git
(`_lib/controllers/flux-operator/`, `_lib/controllers/flux-instance/`) so Flux adopts
and self-manages them; Renovate bumps the chart OCIRepository tags. Cilium is likewise
bootstrapped minimally inline by Talos and adopted by `_lib/networking/cilium/`. There
are no `gotk-components.yaml`/`gotk-sync.yaml` files. See
`_docs/migrations/flux-operator-and-cilium-handover.md`.

## Secrets flow

1Password secrets → 1Password Connect → External Secrets Operator → Kubernetes secrets

SOPS-encrypted secrets are decrypted by Flux using the `sops-age` secret in `flux-system`. The Age key comes from 1Password during bootstrap (see `_infra/memphis/main.tf`).

## Application pattern

Apps in `_lib/applications/<app>/` follow kustomize base/overlay structure:

- `base/` — Deployment, Service, HTTPRoute/Ingress, Namespace, ExternalSecret definitions
- `overlays/<env>/` — Environment-specific patches (database config, object backup/recovery)

## Cluster config substitution

The `cluster-config` ConfigMap (at `_clusters/dev/config/cluster-configs.yaml`) provides variables like `${GATEWAY_NAME}`, `${WALLABAG_SUBDOMAIN}`, `${ENVIRONMENT}` that Flux substitutes into manifests at reconcile time via `postBuild.substituteFrom`.
