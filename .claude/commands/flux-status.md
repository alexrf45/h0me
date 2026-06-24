Show the current state of all Flux resources in the cluster.

All flux calls MUST go through the `k8sop` wrapper from `~/.zsh/kubeop.sh`
(see CLAUDE.md → "Cluster access").

```bash
k8sop dev flux get kustomizations
k8sop dev flux get helmreleases -A
k8sop dev flux get sources git -A
```

Summarize any resources that are not Ready and surface any errors.
