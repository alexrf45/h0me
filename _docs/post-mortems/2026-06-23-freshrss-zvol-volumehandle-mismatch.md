# Post-Mortem — FreshRSS volume won't attach (volumeHandle / zvol name mismatch)

- **Date resolved:** 2026-06-23
- **Severity:** SEV2
- **Component:** `applications` — FreshRSS static PersistentVolume (freenas-api-iscsi)
- **Fix commit:** `3d81229`
- **Related:** runbook `_docs/runbooks/cluster-manual-intervention.md`

## Symptom

The FreshRSS static PV would not attach / the volume failed to resolve against
TrueNAS — the CSI `volumeHandle` did not correspond to an existing zvol.

## Impact

FreshRSS could not mount its data volume; the app could not start with persistent
storage.

## Root cause

In `_lib/applications/freshrss/overlays/dev/volume.yaml` the PV's
`csi.volumeHandle` was `dev-freshrss-pvc`, but the manually created zvol on
TrueNAS is named `dev-freshrss-pv`. The `volumeHandle` must match the zvol name
exactly; the `-pvc` suffix was wrong.

## Fix

Changed `csi.volumeHandle` from `dev-freshrss-pvc` to `dev-freshrss-pv` in
`_lib/applications/freshrss/overlays/dev/volume.yaml`.

## Detection & verification

```sh
kube dev -n freshrss describe pv <pv-name> | grep -A8 Events
kube dev -n freshrss get pvc
# PVC bound, pod able to mount the volume
```

## Prevention / follow-up

For statically provisioned iSCSI PVs, the PV `volumeHandle` is the zvol name on
TrueNAS — spell out the full dataset/zvol segment and copy it verbatim from
TrueNAS. Do not assume a `-pvc`/`-pv` suffix convention.
