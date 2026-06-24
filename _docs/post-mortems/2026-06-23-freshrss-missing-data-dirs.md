# Post-Mortem — FreshRSS init missing writable data subdirectories

- **Date resolved:** 2026-06-23
- **Severity:** SEV3
- **Component:** `applications` — FreshRSS init container
- **Fix commit:** `4f94935`
- **Related:** `_lib/applications/freshrss/base/deployment.yaml`

## Symptom

FreshRSS failed to operate correctly on a fresh persistent volume — the app
expects a set of data subdirectories under `/var/www/FreshRSS/data` that did not
exist on the empty iSCSI volume, and could not write to them.

## Impact

FreshRSS degraded — caching, favicons, tokens, and user data had no writable
home. App-level failures rather than a hard crash.

## Root cause

The init container created the seed/config trees and chowned
`/var/www/FreshRSS/data`, but did not pre-create the required data
subdirectories. On a brand-new zvol the directories are absent, so the app had
nowhere to write. This is the enumerate-all-writable-paths class of init bug.

## Fix

Added the missing directory creation to the init container in
`_lib/applications/freshrss/base/deployment.yaml`, before the chown/chmod:

```sh
mkdir -p /var/www/FreshRSS/data/cache \
         /var/www/FreshRSS/data/favicons \
         /var/www/FreshRSS/data/files \
         /var/www/FreshRSS/data/tokens \
         /var/www/FreshRSS/data/PubSubHubbub \
         /var/www/FreshRSS/data/users/_
```

The existing `chown -R 100:82` / `chmod -R g+rX,g+w` then apply to the new dirs.

## Detection & verification

```sh
kube dev -n freshrss logs deploy/freshrss -c <init-container>
kube dev -n freshrss rollout status deploy/freshrss
```

## Prevention / follow-up

For permission/init issues, enumerate **all** writable paths an app needs (run,
log, cache, data) in one pass rather than discovering them one crash at a time.
