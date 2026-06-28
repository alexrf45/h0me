# Configuration Management Checklist — Adding an App or Service

Reference checklist for wiring a new app/service (or a sidecar like a WAF) into
the `h0me` cluster. The goal: confirm **every** requirement up front so nothing
is discovered one crash at a time. Born from real misses — see the linked
post-mortems.

> Rule of thumb: before writing manifests, **survey the upstream image and the
> target namespace**. Read the image's Dockerfile + entrypoint and the namespace's
> existing quota/policies. Enumerate requirements in one pass.

## 1. Pre-deploy survey (do this first)

- [ ] **Image facts** — read the upstream Dockerfile/entrypoint: `USER`/uid,
      `WORKDIR`, `ENV`, exposed port, and **every path written at runtime**
      (configs generated at start, tmp/cache/log/data dirs). Note baked-in files
      a volume mount might shadow.
- [ ] **Resource requirements** — the app's documented/observed CPU+memory
      (requests and limits). Include sidecars/initContainers.
- [ ] **Required configuration files** — what must exist (ConfigMap-mounted) vs.
      what the entrypoint generates at runtime (needs a writable dir).
- [ ] **HTTP methods + API endpoints** — which methods the app actually uses
      (drives the L7 allowlist), health/readiness paths, metrics path, any API
      routes, websockets.
- [ ] **Egress needs** — DB, DNS, external APIs (`world`), in-cluster services,
      object storage.
- [ ] **Secrets** — which credentials, and the 1Password item/fields backing them.
- [ ] **Persistent storage** — does it need a PV? (TrueNAS zvol/iSCSI is a manual
      pre-step — see MN1.)

## 2. Resource governance (namespace fit)

- [ ] Container `resources.requests` + `resources.limits` set (Kyverno
      `require-pod-resources` expects both).
- [ ] **ResourceQuota headroom** — confirm the namespace `ResourceQuota` can fit
      the new pod's effective requests/limits (effective = `max(initContainers,
      sum(containers))` per resource). **Bump the quota if needed** — a too-tight
      quota yields `FailedCreate / exceeded quota` and the ReplicaSet gets stuck
      in backoff. (Lesson: homer-waf.) Files:
      `_lib/applications/<app>/base/resourcequota.yaml`, `limitrange.yaml`.
- [ ] `PodDisruptionBudget` present (`maxUnavailable: 1`) — exclude DB pods.

## 3. Security context (Kyverno will mutate — be explicit)

The `add-default-securitycontext` ClusterPolicy
(`_lib/security/kyverno-policies/app-clusterpolicy.yaml`) injects, via `+()`
add-if-absent anchors, on pods in `th0th.dev/policy-target: application`
namespaces: `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`,
`readOnlyRootFilesystem:true`, `runAsNonRoot:true`, `runAsUser:65534`,
`seccompProfile:RuntimeDefault`, and `enableServiceLinks:false`.

- [ ] **Set the full `securityContext` explicitly** so injected defaults can't
      surprise you (and are visible in the manifest).
- [ ] Under `readOnlyRootFilesystem:true`, mount a writable `emptyDir` for
      **every** runtime-written path (from the §1 survey). Set pod `fsGroup` =
      the run uid so the emptyDirs are group-writable.
- [ ] If a baked image dir must stay populated **and** be writable, use a **seed
      initContainer** (`cp -a <dir>/. /seed/`) — an empty emptyDir hides baked
      files. (Lesson: coraza `/opt/coraza/config`.)
- [ ] If the binary has file capabilities (`setcap ...=+ep`, e.g. caddy
      `cap_net_bind_service`), **add that capability back** — under `no_new_privs`
      (`allowPrivilegeEscalation:false`) `execve` returns EPERM otherwise, even on
      a high port. (Lesson: caddy.)
- [ ] Pick the right uid — prefer the image's intended user over the injected
      `65534` when the image chowned dirs to it.

## 4. Networking & policy (default-deny model)

- [ ] `Service` (ClusterIP) — correct port/targetPort/selector.
- [ ] `HTTPRoute` — `parentRefs` to `${GATEWAY_NAME}`, hostname, backend
      service+port. Namespace has the gateway label (`${GATEWAY_NAME}: "true"`)
      if attaching to the HTTPS listener.
- [ ] `CiliumClusterwideNetworkPolicy` **default-deny** + **allow** for the app:
  - [ ] ingress sources: gateway (`fromEntities: [ingress]`), kubelet probes
        (`host`, `remote-node`), and any direct callers (Prometheus from
        `monitoring`, `cloudflared` for public tunnel).
  - [ ] egress: `kube-dns` (53), DB pod, `world`/`cluster` as needed.
- [ ] **L7 method allowlist** (defense-in-depth) on the app pod ingress —
      restrict to the methods from §1; keep kubelet probes on a separate L4-only
      rule so the L7 filter doesn't apply to them.
- [ ] Register every new policy file in
      `_lib/security/cilium-network-policies/kustomization.yaml`.

## 5. Secrets & storage

- [ ] `ExternalSecret` → 1Password Connect → ESO (never hand-edit SOPS).
- [ ] PV/PVC if needed — TrueNAS zvol + iSCSI target/extent created manually
      first (MN1); CNPG = single-instance cluster on a static PV.

## 6. Image / supply chain

- [ ] Pin a specific tag (dated/digest, no `:latest`) so Renovate's docker
      manager tracks it; `imagePullPolicy: Always`. If the tag appears in more
      than one place (e.g. main + seed initContainer), confirm Renovate bumps all.

## 7. Flux wiring

- [ ] Files registered in `base/kustomization.yaml` **and** the overlay.
- [ ] Any new `${VARS}` added to `_clusters/dev/config/cluster-configs.yaml`
      (Flux `postBuild.substituteFrom`).
- [ ] Correct Flux layer / `dependsOn` order (`_clusters/dev/cluster.yaml`).

## 8. Observability

- [ ] `ServiceMonitor`/`PodMonitor` if it exports metrics.
- [ ] Gatus endpoint for health, dashboard/route as appropriate.

## 9. Validate, deploy, verify

- [ ] Render: `kube dev kustomize _lib/applications/<app>/overlays/dev`
      (literal `${...}` is expected).
- [ ] Lint: `/lint`.
- [ ] Commit + push (GitOps — never `kubectl apply` ad hoc; it drifts).
- [ ] Reconcile in order: `k8sop dev flux reconcile source git flux-system`,
      then `... kustomization security`, then `... kustomization <app>`.
      **Reconciles take ~1–3 min — poll patiently.**
- [ ] Confirm: pod `1/1 Running`; policies Ready; quota not exceeded.
- [ ] End-to-end test (benign request works) + negative test (attack blocked /
      disallowed method dropped). Capture logs.
- [ ] Note the rollback path before flipping anything to enforce/block.

## References

- Post-mortems: `_docs/post-mortems/2026-06-28-coraza-waf-readonly-rootfs-crashloop.md`
  (securityContext/writable-paths/caddy-cap), `2026-06-23-freshrss-missing-data-dirs.md`
  (enumerate writable paths).
- Runbook: `_docs/runbooks/waf-incident-response.md`.
- Rules: `.claude/rules/` (kube-wrapper, secrets, storage, crds, flux, code).
