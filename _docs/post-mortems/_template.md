# Post-Mortem — <short title>

- **Date resolved:** YYYY-MM-DD
- **Severity:** SEV1 | SEV2 | SEV3
- **Component:** <flux layer / app / node — e.g. `storage` / democratic-csi>
- **Fix commit:** `<hash>`
- **Related:** <ADR / runbook / review item, or none>

## Symptom

What was observed — the exact error string, the resource that was stuck, the
command and output that surfaced it.

## Impact

What was down or degraded, and for whom/how long.

## Root cause

The actual underlying reason (not the symptom). State the verifiable fact, e.g.
"field X referenced value Y; the real value is Z."

## Fix

The concrete change made. File(s) touched, the value/before→after, and any
out-of-band step (TrueNAS change, controller restart, manual reconcile).

## Detection & verification

How it was confirmed fixed — command + expected output.

## Prevention / follow-up

Guardrail, runbook entry, or open item to stop a recurrence. Link tracker item
if one was filed.
