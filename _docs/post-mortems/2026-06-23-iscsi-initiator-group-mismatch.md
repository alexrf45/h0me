# Post-Mortem — iSCSI PVCs Pending from TrueNAS initiator group mismatch

- **Date resolved:** 2026-06-23
- **Severity:** SEV2
- **Component:** `storage` — democratic-csi (freenas-api-iscsi)
- **Fix commit:** `5d5bb4f`
- **Related:** runbook `_docs/runbooks/cluster-manual-intervention.md` (Storage section); review item N1

## Symptom

Dynamic `iscsi` PVCs stuck `Pending`. The provisioner event on the PVC read:

```
iscsi_target_create.groups.0.initiator: "<N> Initiator not found in database"
```

## Impact

No iSCSI volume could be provisioned — any workload requesting a dynamic PVC on
the freenas-iscsi storage class was blocked.

## Root cause

The driver config built by `_lib/storage/freenas-csi/external-secret.yaml` set
`targetGroupInitiatorGroup: 7`, but TrueNAS had no initiator group with ID `7`.
The correct initiator group ID on the TrueNAS appliance is `34`.

Compounding factor: the democratic-csi controller reads its config file **once at
process start**. Editing the ExternalSecret re-renders the mounted config, but the
running process keeps the stale value until restarted.

## Fix

1. In `_lib/storage/freenas-csi/external-secret.yaml`, changed
   `targetGroupInitiatorGroup` from `7` to `34`. Committed and reconciled the
   `storage` Kustomization.
2. Restarted the controller so it re-read the config:

   ```sh
   kube dev -n storage rollout restart deploy/storage-democratic-csi-freenas-controller
   ```

## Detection & verification

```sh
# Confirm the live mounted config carries the new ID
POD=$(kube dev -n storage get pod -l app.kubernetes.io/component=controller -o name | head -1)
kube dev -n storage exec ${POD##*/} -c csi-driver -- \
  sh -c 'grep -i initiatorgroup /config/driver-config-file.yaml'

# PVC should leave Pending and bind
kube dev get pvc -A | grep -v Bound
```

## Prevention / follow-up

After any change to the democratic-csi config secret, **always restart the
controller** — the on-disk config update is not picked up live. Triage table and
restart procedure are captured in the runbook Storage section.
