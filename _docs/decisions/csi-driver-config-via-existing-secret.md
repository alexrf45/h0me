# Decision: democratic-csi driver config via existingConfigSecret + ESO

Date: 2026-06-23 · Status: accepted — implemented in `_lib/storage/freenas-csi/`

## Problem

The TrueNAS API key was injected into the democratic-csi HelmRelease with
`valuesFrom` → `targetPath: driver.config.httpConnection.apiKey`. That bakes the
key into Helm release state: it shows in `helm get values` and is base64'd in the
`sh.helm.release.v1.*` secret — secret-in-Helm-values sprawl.

A related point of confusion: the source `truenas-api-creds` ExternalSecret lived
in `flux-system`. That was **correct, not a misconfiguration** — helm-controller
resolves `valuesFrom` only from the HelmRelease's own namespace. The CSI pods never
read it directly; helm-controller baked the key into the chart-rendered config.

## Decision

Supply the **entire** driver config as a pre-built Secret via the chart's
`driver.existingConfigSecret`, assembled by an ExternalSecret with an ESO template.

- `external-secret.yaml` — ExternalSecret in the **`storage`** namespace, target
  Secret `democratic-csi-freenas-config`, key **`driver-config-file.yaml`** (the
  exact key the chart mounts). Static fields use Flux `${...}` vars (substituted by
  the `storage` Kustomization's `postBuild.substituteFrom`); the apiKey uses ESO
  `{{ .TRUENAS_API_KEY }}` templating. The two syntaxes do not collide.
- `helmrelease.yaml` — drops `valuesFrom` and the inline `driver.config`
  http/zfs/iscsi blocks; sets `driver.existingConfigSecret:
  democratic-csi-freenas-config` and keeps only `driver.config.driver:
  freenas-api-iscsi` inline (chart still requires the driver type inline).

The secret now lives in `storage` (the CSI pods' namespace) because
`existingConfigSecret` is mounted from the HR `targetNamespace`, not the HR's own
namespace — the opposite of the `valuesFrom` requirement.

## Chart contract (verified against democratic-csi chart 0.15.0)

- `templates/driver-config-secret.yaml`: data key is `driver-config-file.yaml`;
  guarded by `{{- if not .Values.driver.existingConfigSecret }}` (chart skips
  creating its own secret when `existingConfigSecret` is set).
- `templates/controller.yaml`: volume `config` → `secretName:
  {{ .Values.driver.existingConfigSecret }}` when set, mounted at `/config`;
  container reads `/config/driver-config-file.yaml`.
- values.yaml note: "if setting an existing secret you must still set
  `driver.config.driver`".

## Benefits / tradeoffs

- **+** API key never transits Helm values or release state; absent from
  `helm get values`. Single source of truth for the whole driver config.
- **+** Secret co-located with the CSI workload (`storage`).
- **−** Static config (host/port/datasets/iscsi) moves from the HR into the ESO
  `template`; keep it in sync with what the chart would otherwise render.

## Verify

- `kube dev -n storage get secret democratic-csi-freenas-config` exists, key
  `driver-config-file.yaml`.
- `kube dev -n storage get pods` controller 5/5 Ready; `helm get values` (via
  `k8sop dev helm -n storage get values democratic-csi-freenas`) shows no apiKey.
