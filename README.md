# h0me

The goal is simple:

1. reproducible
2. version controlled
3. learn something new

## Cluster stats

Live stats, rendered by [shields.io](https://shields.io) from each cluster's
[kromgo](https://github.com/kashalls/kromgo) Prometheus proxy. Values refresh on
cache expiry (shields.io + GitHub's image cache), so they lag a live query by a
few minutes.

### dev — memphis

![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Ftalos_version&style=flat)
![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fkubernetes_version&style=flat)
![Flux](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fflux_version&style=flat)

![CPU](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_cpu_usage&style=flat)
![Memory](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_memory_usage&style=flat)
![Pods](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_pod_count&style=flat)
![Nodes](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_node_count&style=flat)
![Uptime](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_uptime_days&style=flat)
![Alerts](https://img.shields.io/endpoint?url=https%3A%2F%2Fdev-kromgo.th0th.dev%2Fcluster_alert_count&style=flat)

<!--
Per-cluster rows: add a new "### <env> — <cluster>" block per cluster as staging
and prod come online, pointing the badges at https://<env>-kromgo.th0th.dev/<metric>.

### staging — staging
![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fstaging-kromgo.th0th.dev%2Ftalos_version&style=flat)
... (versions row)

![CPU](https://img.shields.io/endpoint?url=https%3A%2F%2Fstaging-kromgo.th0th.dev%2Fcluster_cpu_usage&style=flat)
... (resources row)
-->
