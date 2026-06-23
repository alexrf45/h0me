Check overall cluster and node health.

All kubectl calls MUST go through the `kube` wrapper from `~/.zsh/kubeop.sh`
(see CLAUDE.md → "Cluster access"). `talosctl` is the documented exception
and runs without the wrapper.

```bash
kube dev get pods -A | grep -v Running | grep -v Completed
talosctl health
```

Report any pods not in Running/Completed state and surface any Talos node issues.
