## Rendering kustomize overlays

The standalone `kustomize` binary is **not installed** in this environment, so
`k8sop dev kustomize build <dir>` fails with `kustomize: command not found`.
Use kubectl's built-in kustomize through the `kube` wrapper instead:

```
kube dev kustomize <dir>
```

This runs `kubectl kustomize <dir>`. Note the syntax difference from standalone
kustomize: **there is no `build` subcommand** — pass the directory directly.

Examples:

```
kube dev kustomize _lib/applications/authentik/overlays/dev
kube dev kustomize _lib/applications/freshrss/base
```

Notes:

- **It renders locally** — `kubectl kustomize` does not contact the cluster, so
  it's safe for offline validation. (The wrapper still injects the kubeconfig;
  that's harmless here.)
- **Flux `postBuild.substituteFrom` variables are NOT expanded.** `${ENVIRONMENT}`,
  `${GATEWAY_NAME}`, `${HOMER_VERSION}`, etc. stay as literal `${...}` in the
  output — Flux substitutes them at reconcile, not kustomize. This is expected;
  the render validates kustomization wiring and manifest structure, not the
  substituted values. Don't treat leftover `${...}` as a failure.
- **HelmRelease `values:` blocks are not rendered by kustomize** (Flux/Helm does
  that). Validate those files with `yamllint` instead.
