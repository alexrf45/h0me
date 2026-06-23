## Flux reconciliation layers (dependency order)

Defined in `_clusters/dev/cluster.yaml`. Each layer depends on the one above it:

1. **cluster-config** — ConfigMap with environment variables (`ENVIRONMENT`, `CLUSTER_NAME`, hostnames, etc.) used by `postBuild.substituteFrom` in downstream Kustomizations
2. **crds** — Global CRDs from `global/crds/`
3. **controllers** — All operators: cert-manager, CloudNativePG, external-secrets, Falco, Kyverno, mariadb-operator, redis-operator, Renovate
4. **pki** — Internal CA keypair, trust-manager, trust bundle
5. **external-secrets-operator** — ESO deployment (depends on controllers + pki for mTLS)
6. **secrets** — 1Password Connect deployment + ClusterSecretStore
7. **networking** — Cilium Gateway, Tailscale operator, ClusterIssuers (Let's Encrypt via Cloudflare DNS-01)
8. **dns** — ExternalDNS (depends on secrets for Cloudflare API key)
9. **storage** — freenas-iscsi CSI, local-path provisioner, Barman Cloud
10. **security** — Cilium NetworkPolicies, Kyverno policies
11. **applications** — App workloads (currently only wallabag, using `_lib/applications/wallabag/overlays/dev`)

## Secrets flow

1Password secrets → 1Password Connect → External Secrets Operator → Kubernetes secrets

SOPS-encrypted secrets are decrypted by Flux using the `sops-age` secret in `flux-system`. The Age key comes from 1Password during bootstrap (see `terraform/dev/main.tf`).

## Application pattern

Apps in `_lib/applications/<app>/` follow kustomize base/overlay structure:

- `base/` — Deployment, Service, HTTPRoute/Ingress, Namespace, ExternalSecret definitions
- `overlays/<env>/` — Environment-specific patches (database config, object backup/recovery)

## Cluster config substitution

The `cluster-config` ConfigMap (at `_clusters/dev/config/cluster-configs.yaml`) provides variables like `${GATEWAY_NAME}`, `${WALLABAG_SUBDOMAIN}`, `${ENVIRONMENT}` that Flux substitutes into manifests at reconcile time via `postBuild.substituteFrom`.
