# Post-Mortem — ExternalDNS not upserting to UniFi (Gateway API CRD channel mismatch)

- **Date resolved:** 2026-06-23
- **Severity:** SEV2
- **Component:** `networking` — Cilium Gateway API controller → ExternalDNS (UniFi webhook)
- **Fix commit:** `6a34d86`
- **Related:** `.claude/rules/crds.md`; runbook `_docs/runbooks/cluster-manual-intervention.md` (Gateway API section)

## Symptom

ExternalDNS (`external-dns-unifi`) was not upserting any records to the UniFi
router; internal hostnames (`dev.int.*.th0th.dev`) did not resolve. The pod was
healthy (`2/2 Running`), the HelmRelease Ready, and the UniFi host/API key wired
correctly. Its log showed, for every internal route:

```
No endpoints could be generated from HTTPRoute homer/homer-internal
...
All records are already up to date
```

ExternalDNS generated **zero endpoints**, so it had nothing to upsert and never
called the UniFi webhook. The webhook path was never exercised.

## Impact

All internal-access DNS for cluster apps was unpublished — homer, grafana,
gatus, kromgo, authentik, freshrss internal hostnames did not resolve via the
UniFi router. External (Cloudflare) access was unaffected. No data loss.

## Root cause

A four-layer chain, with the real cause at the top:

1. **Gateway API CRDs were the wrong channel/version.** Installed = **standard
   channel v1.4.0**, which lacks `tlsroutes` entirely and serves
   `referencegrants` only at `v1beta1`. Cilium **1.20.0-pre.3** requires Gateway
   API **v1.5.1**, where `tlsroutes` moved into the standard channel and
   `referencegrants` graduated to `v1`. The Cilium operator refused to start its
   Gateway API controller:

   ```
   level=error msg="Required GatewayAPI resources are not found"
   error="customresourcedefinitions ... \"tlsroutes.gateway.networking.k8s.io\" not found
          CRD \"referencegrants.gateway.networking.k8s.io\" does not have version \"v1\""
   ```
2. → GatewayClass `cilium` never `Accepted` ("Waiting for controller").
3. → Gateway `dev-app-gateway` never `Programmed`, got no `status.addresses`, and
   no backing `cilium-gateway-dev-app-gateway` LoadBalancer Service was created.
4. → HTTPRoutes had no parent status and **no target IP**, so ExternalDNS's
   `gateway-httproute` source generated no endpoints → nothing to publish.

**Contributing config gap:** the Gateway API CRDs were **not managed in Git** —
absent from `_global/crds/`, applied out-of-band during bootstrap. That is both
*why* the wrong channel slipped in and *why* it would recur on rebuild.

**Secondary, independent bug:** `cilium-ingress` requested
`loadBalancerIP: 192.168.20.225`, which sits just **below** the LB-IPAM pool
range (`192.168.20.226–.236`), so it could never be assigned and stayed
`<pending>`. Off the ExternalDNS critical path (the Gateway's own LB Service
pulls a pool IP) but a real misconfiguration.

## Fix

`6a34d86`:

1. Vendored the Gateway API **v1.5.1 standard-install** bundle to
   `_global/crds/gateway-api/gateway-api-standard-v1.5.1.yaml` with a
   `kustomization.yaml`, and added `./gateway-api` to `_global/crds/kustomization.yaml`
   so the **`crds` Flux layer** owns it. Standard→standard, v1.4.0→v1.5.1 is a
   permitted upgrade (the bundle's `safe-upgrades` ValidatingAdmissionPolicy only
   blocks experimental-over-standard and pre-v1.5.0 installs).
2. Bumped `cilium-ingress` `loadBalancerIP` `192.168.20.225` → `192.168.20.226`
   (into the pool) in `_lib/networking/cilium/helmrelease.yaml`.

Out-of-band step required: **restart `cilium-operator`** — it checks for the
required Gateway API CRDs only at process start, so it did not pick up the new
CRDs until restarted:

```sh
kube dev -n networking rollout restart deploy/cilium-operator
```

(ExternalDNS was also restarted to force an immediate resync; it would otherwise
have caught up on its 1m interval.)

## Detection & verification

```sh
# CRDs now v1.5.1, referencegrants serves v1, tlsroutes present
kube dev get crd referencegrants.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}'  # v1 v1beta1
# GatewayClass + Gateway healthy
kube dev get gatewayclass cilium -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}'  # Accepted=True
kube dev -n networking get gateway dev-app-gateway -o jsonpath='{.status.addresses}'  # 192.168.20.227
# Backing services have IPs
kube dev -n networking get svc | grep -E 'cilium-ingress|cilium-gateway'  # .226 and .227
# ExternalDNS now generates endpoints
kube dev -n networking logs deploy/external-dns-unifi -c external-dns | grep 'Endpoints generated from HTTPRoute'
```

Confirmed: GatewayClass `Accepted=True`; Gateway `Programmed=True` @
`192.168.20.227`; `cilium-ingress` @ `192.168.20.226`; all six internal
HTTPRoutes generate A records → `192.168.20.227`; the UniFi webhook holds 12
records (6 A + 6 `k8s.` TXT registry); `crds`/`networking`/`dns` Kustomizations
Ready; cilium Helm upgrade succeeded.

## Prevention / follow-up

- **Gateway API CRDs are now Git-managed** in the `crds` layer — survives
  rebuilds and pins the channel/version explicitly (per `.claude/rules/crds.md`).
- **Operator restart on CRD change:** Cilium's operator evaluates required
  Gateway API CRDs only at startup. After adding/upgrading Gateway API CRDs,
  restart `cilium-operator`. Captured in the runbook.
- **Renovate:** the vendored `gateway-api-standard-v1.5.1.yaml` is a pinned raw
  manifest (no upstream CRD-only Helm chart exists) — Renovate won't auto-bump it
  without a tracking annotation. Open follow-up to add one, matching the goal in
  `crds.md`.
- **LB IPs vs pool:** any static `loadBalancerIP` must fall inside a
  `CiliumLoadBalancerIPPool` block, or LB-IPAM silently leaves the Service
  `<pending>`.
