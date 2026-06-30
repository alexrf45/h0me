# Post-Mortem — Coraza WAF CrashLoopBackOff under hardened securityContext

- **Date resolved:** 2026-06-28
- **Severity:** SEV3
- **Component:** `applications` — freshrss-waf (Coraza + OWASP CRS reverse proxy)
- **Fix commits:** `ec7c365`, `b38976d`, `a2f33c4`, `80e240f`
- **Related:** `_lib/applications/freshrss/base/waf-deployment.yaml`,
  `_lib/security/kyverno-policies/app-clusterpolicy.yaml` (`add-default-securitycontext`)

## Symptom

The new `freshrss-waf` Deployment (image `ghcr.io/coreruleset/coraza-crs`,
caddy variant) CrashLoopBackOff'd. The error changed after each fix as a
deeper writable-path requirement surfaced:

1. `mkdir: can't create directory '/tmp/coraza/': Read-only file system`
2. `/entrypoint.sh: line 24: can't create /etc/caddy/Caddyfile: Read-only file system`
3. `/entrypoint.sh: line 25: caddy: Operation not permitted`
4. `sed: can't read /opt/coraza/config/crs-setup.conf: No such file or directory`

## Impact

None to users — the WAF was being introduced in front of FreshRSS for the
first time and never reached service. FreshRSS itself stayed up the whole time
(the HTTPRoute backend flip only matters once the WAF pod is Ready). Dev only.

## Root cause

The WAF container manifest omitted most `securityContext` fields. The cluster's
Kyverno `add-default-securitycontext` policy (`+()` add-if-absent anchors,
applied to pods in `th0th.dev/policy-target: application` namespaces) therefore
injected the hardened defaults — `readOnlyRootFilesystem: true` and
`runAsUser: 65534`. That posture is correct and desired, but the image was not
configured for it, producing four distinct failures:

1. Coraza/Caddy write to `/tmp/coraza`, the Caddy XDG dirs, and the log dirs at
   runtime — all on the now read-only rootfs.
2. The entrypoint **generates** `/etc/caddy/Caddyfile` and
   `/opt/coraza/config/coraza.conf` at startup — also read-only.
3. The `caddy` binary ships with file capability `cap_net_bind_service=+ep`.
   With `allowPrivilegeEscalation: false` (`no_new_privs`) and `drop: [ALL]`,
   the kernel cannot grant the effective file-cap, so `execve` returns EPERM
   ("Operation not permitted") — even though the proxy binds 8080, not a low port.
4. Mounting an **empty** `emptyDir` at `/opt/coraza/config` (needed for write
   access in #2) shadowed the image's baked-in `crs-setup.conf`, which the
   entrypoint then `sed`-edits.

## Fix

All in `_lib/applications/freshrss/base/waf-deployment.yaml`, keeping the
hardened posture (`readOnlyRootFilesystem: true`) rather than weakening it:

- Run as the image's `caddy` user (`runAsUser/runAsGroup: 1000`) with pod
  `fsGroup: 1000` so the emptyDirs are group-writable (`ec7c365`).
- `emptyDir` mounts for every runtime-writable path: `/tmp`, `/config`, `/data`,
  `/var/log/caddy`, `/var/log/coraza` (`ec7c365`); plus `/etc/caddy` and
  `/opt/coraza/config` for the generated configs (`b38976d`).
- `capabilities: drop [ALL]` **add `[NET_BIND_SERVICE]`** so the caddy binary's
  effective file-cap can be honored under `no_new_privs`; keeps
  `allowPrivilegeEscalation: false` (`a2f33c4`). Mirrors the freshrss app container.
- A `seed-coraza-config` initContainer that `cp -a /opt/coraza/config/.` into the
  emptyDir before the main container mounts it, preserving the baked CRS files
  while leaving the dir writable (`80e240f`). Mirrors the freshrss
  `seed-writable-dirs` pattern.

## Detection & verification

```sh
kube dev -n freshrss rollout status deploy/freshrss-waf      # successfully rolled out
kube dev -n freshrss get pods -l app=freshrss-waf            # 1/1 Running
# End-to-end + CRS detection (DetectionOnly), from inside the pod:
kube dev -n freshrss exec deploy/freshrss-waf -c coraza -- \
  wget -q -S -O /dev/null "http://127.0.0.1:8080/?id=1%27%20OR%20%271%27=%271"
kube dev -n freshrss logs deploy/freshrss-waf -c coraza | grep -i coraza
# → 302 to FreshRSS login; CRS rules 942xxx (SQLi) / 941xxx (XSS) /
#   949110 "Inbound Anomaly Score Exceeded (Total Score: 23)".
```

## Prevention / follow-up

- Enumerate **all** writable paths in one pass from the image's Dockerfile +
  entrypoint before deploying under `readOnlyRootFilesystem` — don't discover
  them one crash at a time. Distinguish dirs that can be empty (`/etc/caddy`,
  regenerated wholesale) from dirs that must keep baked content
  (`/opt/coraza/config`) and need a seed initContainer.
- Remember the Caddy/`no_new_privs` file-cap EPERM gotcha: any image whose
  binary has `setcap ...=+ep` needs the matching capability `add`ed back, or it
  cannot exec under `allowPrivilegeEscalation: false`.
- When a workload inherits the `add-default-securitycontext` Kyverno defaults,
  set the full `securityContext` explicitly so the injected values are visible
  in the manifest and can't surprise a future reader.
