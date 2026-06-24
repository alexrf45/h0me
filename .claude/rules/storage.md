---
description: "Persistent storage requirments and considerations"
---

## Data persistent and governance

- Databases will consist of a single instance cnpg cluster backed by a manually created TrueNAS zvol, iscsi target and extent.

- Configurations should be defined in manifests as much as possible to avoid persistent storage for those volumes.

- Logs should be stored locally and exported as specified per app/service.
