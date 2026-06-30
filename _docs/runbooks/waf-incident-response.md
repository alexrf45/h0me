# Runbook — WAF Incident Response (Coraza + OWASP CRS)

Operating and investigating the in-cluster Web Application Firewall. The pilot
fronts **FreshRSS** (`freshrss-waf` in the `freshrss` namespace):

```
Gateway (networking) → HTTPRoute → svc/freshrss-waf:8080 (Coraza+CRS) → svc/freshrss:80
```

Two layers stack on this path:

1. **Coraza + OWASP CRS** — signature WAF (SQLi/XSS/traversal/RCE, anomaly
   scoring). Engine mode set by `CORAZA_RULE_ENGINE` in
   `_lib/applications/freshrss/base/waf-deployment.yaml` (`On` = block,
   `DetectionOnly` = log-only, `Off`).
2. **Cilium L7 NetworkPolicy** — HTTP method allowlist (`GET/POST/HEAD/OPTIONS`)
   on the app pod's ingress from the WAF
   (`_lib/security/cilium-network-policies/freshrss-allow.yaml`). Disallowed
   methods are dropped at the network layer with verdict `L7 policy`.

All cluster access goes through the `~/.zsh/kubeop.sh` wrappers — **never** raw
`kubectl`/`flux`. In a non-interactive shell, source it first:

```sh
source ~/.zsh/kubeop.sh
```

---

## Verify the WAF is blocking (Coraza, layer 1)

From the LAN (real ingress path through the gateway). A clean request succeeds;
an attack payload is blocked with **403 / "Access Denied"**:

```sh
# Benign — expect 200/302 (FreshRSS login redirect)
curl -k -s -o /dev/null -w "%{http_code}\n" "https://dev.int.freshrss.th0th.dev/"

# SQLi probe — expect 403 when CORAZA_RULE_ENGINE=On
curl -k -s -o /dev/null -w "%{http_code}\n" \
  "https://dev.int.freshrss.th0th.dev/?id=1%27%20OR%20%271%27=%271"

# XSS probe — expect 403
curl -k -s -o /dev/null -w "%{http_code}\n" \
  "https://dev.int.freshrss.th0th.dev/?q=<script>alert(1)</script>"
```

If the gateway LB (`192.168.20.226`) isn't routable from where you are, test the
proxy directly from inside the pod (Coraza still inspects loopback traffic):

```sh
kube dev -n freshrss exec deploy/freshrss-waf -c coraza -- \
  wget -q -S -O /dev/null "http://127.0.0.1:8080/?id=1%27%20OR%20%271%27=%271" 2>&1 \
  | grep -i "HTTP/"
# On=blocking → "HTTP/1.1 403 Forbidden"; DetectionOnly → "HTTP/1.1 302 Found"
```

## Verify the L7 method block (Cilium, layer 2)

```sh
# Disallowed method — dropped by Cilium before reaching the app
curl -k -s -o /dev/null -w "%{http_code}\n" -X DELETE "https://dev.int.freshrss.th0th.dev/"
# → "Access Denied" / no 2xx
```

---

## Query the logs during an incident

### Coraza audit log (which CRS rules fired, on what request)

Audit goes to stdout (`CORAZA_AUDIT_LOG=/dev/stdout`).

```sh
# Live tail
kube dev -n freshrss logs deploy/freshrss-waf -c coraza -f

# Recent CRS matches only
kube dev -n freshrss logs deploy/freshrss-waf -c coraza --tail=500 | grep -i "Coraza:"

# Which rule IDs fired, ranked
kube dev -n freshrss logs deploy/freshrss-waf -c coraza --tail=2000 \
  | grep -oE 'id .\\?"[0-9]{6}\\?"' | grep -oE '[0-9]{6}' | sort | uniq -c | sort -rn

# The blocking decision + anomaly score
kube dev -n freshrss logs deploy/freshrss-waf -c coraza --tail=2000 | grep -i "Anomaly Score Exceeded"
```

Each match line carries `[id "NNNNNN"]`, `[msg "..."]`, `[severity "..."]`,
`[data "..."]`, `[uri "..."]`, `[client "..."]`, `[unique_id "..."]`. Rule
families: **942xxx** SQLi · **941xxx** XSS · **930xxx** LFI/traversal · **932xxx**
RCE · **920xxx** protocol enforcement. Rule **949110** = inbound anomaly score
exceeded (the actual block in anomaly mode; default threshold 5).

### Cilium L7 / network verdicts (Hubble)

```sh
# Drops into the freshrss namespace, with reason
k8sop dev hubble observe -n freshrss --verdict DROPPED --last 200

# L7 HTTP flows (method allowlist enforcement) for the app pod
k8sop dev hubble observe -n freshrss --to-label app=freshrss --protocol http --last 200
```

A blocked method shows `verdict: DROPPED` with the L7 policy reason. Or use the
Hubble UI (`networking` namespace) for the same in a graph.

---

## Triage decision tree (suspected attack / false positive)

1. **Is it a real attack or a false positive?** Pull the offending `unique_id`
   from the Coraza log; inspect `uri`/`data`. Legit FreshRSS workflows that trip
   CRS are FPs.
2. **False positive → tune, don't disable.** Add a targeted exclusion to
   `_lib/applications/freshrss/base/waf-overrides-configmap.yaml`
   (`SecRuleRemoveById <id>` or `SecRuleUpdateTargetById <id> "!ARGS:param"`),
   commit, reconcile. Never blanket-`Off` the engine.
3. **Real attack, need to confirm blocking is active:** run the verify commands
   above; check `CORAZA_RULE_ENGINE` is `On` in the live pod:
   `kube dev -n freshrss get deploy freshrss-waf -o jsonpath='{.spec.template.spec.containers[0].env}'`.
4. **Source attribution:** the `client` field in the Coraza log + Hubble
   `--ip`/`--from-identity` give the origin. (Behind the Cloudflare tunnel,
   prefer `X-Forwarded-For`; for direct gateway/LAN traffic the source IP is real.)
5. **Need to fail open temporarily** (WAF itself is the problem, app must stay
   up): flip `CORAZA_RULE_ENGINE` to `DetectionOnly` (logs, never blocks) via a
   commit + reconcile — this is the controlled "stop blocking" lever, preferable
   to ripping the WAF out of the route.

---

## Change the engine mode (GitOps)

```sh
# Edit _lib/applications/freshrss/base/waf-deployment.yaml:
#   CORAZA_RULE_ENGINE: On | DetectionOnly | Off
# commit + push, then:
k8sop dev flux reconcile source git flux-system
k8sop dev flux reconcile kustomization freshrss
kube dev -n freshrss rollout status deploy/freshrss-waf
```

> Direct `kubectl edit`/`set env` drifts from Git and is reverted on the next
> reconcile — always go through a commit.

## Health / sanity

```sh
kube dev -n freshrss get pods -l app=freshrss-waf          # 1/1 Running
kube dev get ciliumclusterwidenetworkpolicies | grep freshrss   # all Ready
kube dev -n freshrss logs deploy/freshrss-waf -c coraza --tail=5 # "Launching caddy run ..."
```
