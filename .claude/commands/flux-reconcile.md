Reconcile Flux kustomizations. If a kustomization name is provided as an argument, reconcile that specific one. Otherwise, reconcile all kustomizations and report their status.

All flux calls MUST go through the `k8sop` wrapper from `~/.zsh/kubeop.sh`
(see CLAUDE.md → "Cluster access").

For a specific kustomization:
```bash
k8sop dev flux reconcile kustomization $ARGUMENTS --with-source
```

For all kustomizations:
```bash
k8sop dev flux get kustomizations
```

After reconciling, show the current status and flag any that are not Ready.
