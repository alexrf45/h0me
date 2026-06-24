# ---------------------------------------------------------------------------
# Human day-to-day admin (@pve realm). Password read from a pre-created 1P item
# (same data-source pattern as terraform/dev/providers.tf:42-45), so it never
# lands in HCL/state-as-literal and stays rotatable.
# ---------------------------------------------------------------------------
data "onepassword_item" "admin" {
  vault = var.op_vault_id
  title = var.admin.op_item_title
}

resource "proxmox_virtual_environment_user" "admin" {
  user_id  = var.admin.user_id
  password = data.onepassword_item.admin.password
  comment  = var.admin.comment
  enabled  = true
}

# Built-in PVEAdmin role at / — full management EXCEPT realm/permission editing,
# the intended boundary vs root@pam.
resource "proxmox_acl" "admin" {
  user_id   = proxmox_virtual_environment_user.admin.user_id
  role_id   = "PVEAdmin"
  path      = "/"
  propagate = true
}

# ---------------------------------------------------------------------------
# Terraform automation principal (@pve) + custom role + API token.
# Privilege list is the bpg-recommended set for the provider (docs/index.md,
# v0.107.0), which includes the SDN.* and Permissions/Realm/User/Group privs
# this root needs to manage SDN + users itself.
# ---------------------------------------------------------------------------
resource "proxmox_virtual_environment_role" "automation" {
  role_id = var.automation.role_id
  privileges = [
    "Datastore.Allocate",
    "Datastore.AllocateSpace",
    "Datastore.AllocateTemplate",
    "Datastore.Audit",
    "Group.Allocate",
    "Mapping.Audit",
    "Mapping.Modify",
    "Mapping.Use",
    "Permissions.Modify",
    "Pool.Allocate",
    "Pool.Audit",
    "Realm.Allocate",
    "Realm.AllocateUser",
    "SDN.Allocate",
    "SDN.Audit",
    "SDN.Use",
    "Sys.AccessNetwork",
    "Sys.Audit",
    "Sys.Console",
    "Sys.Incoming",
    "Sys.Modify",
    "Sys.PowerMgmt",
    "Sys.Syslog",
    "User.Modify",
    "VM.Allocate",
    "VM.Audit",
    "VM.Backup",
    "VM.Clone",
    "VM.Config.CDROM",
    "VM.Config.CPU",
    "VM.Config.Cloudinit",
    "VM.Config.Disk",
    "VM.Config.HWType",
    "VM.Config.Memory",
    "VM.Config.Network",
    "VM.Config.Options",
    "VM.Console",
    "VM.GuestAgent.Audit",
    "VM.GuestAgent.FileRead",
    "VM.GuestAgent.FileSystemMgmt",
    "VM.GuestAgent.FileWrite",
    "VM.GuestAgent.Unrestricted",
    "VM.Migrate",
    "VM.PowerMgmt",
    "VM.Replicate",
    "VM.Snapshot",
    "VM.Snapshot.Rollback",
  ]
}

resource "proxmox_virtual_environment_user" "automation" {
  user_id = var.automation.user_id
  comment = var.automation.comment
  enabled = true
}

resource "proxmox_acl" "automation" {
  user_id   = proxmox_virtual_environment_user.automation.user_id
  role_id   = proxmox_virtual_environment_role.automation.role_id
  path      = "/"
  propagate = true
}

# privileges_separation = false → the token inherits the user's role (the / ACL
# above) rather than needing its own ACLs. `value` is only available at create
# time, so it is captured straight into 1Password below.
resource "proxmox_user_token" "automation" {
  user_id               = proxmox_virtual_environment_user.automation.user_id
  token_name            = var.automation.token_name
  comment               = var.automation.comment
  privileges_separation = false

  depends_on = [proxmox_acl.automation]
}

# Publish the token to 1Password (mirrors terraform/cloudflare-tunnel/main.tf).
# IMPORTANT: bpg's `.value` is ALREADY the full, ready-to-use provider token
# (`user@realm!tokenname=uuid`) — the client returns `FullTokenID + "=" + Value`
# (proxmox/access/user_token.go:40), NOT a bare UUID secret. So `api-token` must
# be `.value` verbatim. Prefixing it with `.id` again doubles the
# `user@realm!tokenname=` segment and the provider rejects it with HTTP 401.
resource "onepassword_item" "automation_token" {
  vault    = var.op_vault_id
  title    = var.automation.op_item_title
  category = "password"

  section {
    label = "proxmox"

    field {
      label = "token-id"
      type  = "STRING"
      value = proxmox_user_token.automation.id
    }
    # Full provider token: terraform@pve!tf=<uuid>. Use this for TF_VAR_pve_api_token.
    field {
      label = "api-token"
      type  = "CONCEALED"
      value = proxmox_user_token.automation.value
    }
  }
}
