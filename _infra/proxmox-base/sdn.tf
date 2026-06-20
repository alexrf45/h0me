# Simple (isolated) SDN zone for running workloads on a VNet. Deployed to every
# PVE node so a VM can attach to the vnet on whichever host it lands. Cross-node
# traffic is L3-routed (no stretched L2) — see the constraint note in variables.tf.
resource "proxmox_sdn_zone_simple" "this" {
  id    = var.sdn.zone_id
  nodes = coalesce(var.sdn.nodes, var.pve.hosts)
  ipam  = "pve"
  mtu   = var.sdn.mtu
}

# The VNet — its id becomes the bridge name VMs attach to (network_device.bridge).
resource "proxmox_sdn_vnet" "this" {
  id   = var.sdn.vnet_id
  zone = proxmox_sdn_zone_simple.this.id
}

# Subnet with a Proxmox-owned gateway + SNAT for egress. Static addressing only;
# Talos/cloud-init sets node IPs, so no DHCP range is defined.
resource "proxmox_sdn_subnet" "this" {
  vnet    = proxmox_sdn_vnet.this.id
  cidr    = var.sdn.subnet_cidr
  gateway = var.sdn.gateway
  snat    = var.sdn.snat
}

# Commits pending SDN config (equivalent to Datacenter → SDN → Apply). Without
# it the zone/vnet/subnet stay "pending". replace_triggered_by re-runs the apply
# whenever any SDN object changes.
resource "proxmox_sdn_applier" "this" {
  depends_on = [
    proxmox_sdn_zone_simple.this,
    proxmox_sdn_vnet.this,
    proxmox_sdn_subnet.this,
  ]

  lifecycle {
    replace_triggered_by = [
      proxmox_sdn_zone_simple.this,
      proxmox_sdn_vnet.this,
      proxmox_sdn_subnet.this,
    ]
  }
}
