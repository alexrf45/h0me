# locals.tf - Local values for Cilium LB and node name resolution

locals {
  # Shared machine config fragment, identical for control plane and workers.
  # Interpolated into both data.talos_machine_configuration.* patches as
  # ${chomp(local.machine_common)}. Depends ONLY on global vars (var.talos.*,
  # never the node set), so adding/removing a worker re-renders only that node's
  # config and never touches existing nodes. Keep it that way.
  machine_common = <<-EOT
      systemDiskEncryption:
        ephemeral:
          provider: luks2
          keys:
            - nodeID: {}
              slot: 0
              tpm: {}
        state:
          provider: luks2
          keys:
            - nodeID: {}
              slot: 0
              tpm: {}
      sysctls:
        vm.nr_hugepages: "1024"
      kernel:
        modules:
          - name: nvme_tcp
          - name: vfio_pci
      files:
        - path: /etc/cri/conf.d/20-customization.part
          op: create
          content: |
            [plugins."io.containerd.cri.v1.images"]
              discard_unpacked_layers = false
            [plugins."io.containerd.cri.v1.runtime"]
              device_ownership_from_security_context = true
      time:
        servers:
%{for s in var.talos.ntp_servers~}
          - ${s}
%{endfor~}
      kubelet:
        extraArgs:
          rotate-server-certificates: true
        clusterDNS:
          - ${var.talos.cluster_dns_ip}
        extraMounts:
          - destination: ${var.talos.storage_disk}
            type: bind
            source: ${var.talos.storage_disk}
            options:
              - rbind
              - rshared
              - rw
      disks:
        - device: ${var.talos.storage_device}
          partitions:
            - mountpoint: ${var.talos.storage_disk}
  EOT

  # Cilium L2 announcement policy and LB IP pool manifests
  cilium_external_lb_manifests = [
    {
      apiVersion = "cilium.io/v2alpha1"
      kind       = "CiliumL2AnnouncementPolicy"
      metadata = {
        name = "external"
      }
      spec = {
        loadBalancerIPs = true
        interfaces = [
          "eth0",
        ]
        nodeSelector = {
          matchExpressions = [
            {
              key      = "node-role.kubernetes.io/control-plane"
              operator = "DoesNotExist"
            },
          ]
        }
      }
    },
    {
      apiVersion = "cilium.io/v2alpha1"
      kind       = "CiliumLoadBalancerIPPool"
      metadata = {
        name = "external"
      }
      spec = {
        blocks = [
          {
            start = cidrhost(var.cilium_config.node_network, var.cilium_config.load_balancer_start)
            stop  = cidrhost(var.cilium_config.node_network, var.cilium_config.load_balancer_stop)
          },
        ]
      }
    },
  ]
  cilium_lb_manifest = join("---\n", [for d in local.cilium_external_lb_manifests : yamlencode(d)])

  # Worker node hostname map: key => hostname
  # Used by kubernetes_labels to target nodes by their Talos-assigned hostname
  worker_node_names = {
    for k, v in var.worker_nodes : k => format("${var.env}-${var.talos.name}-node-${random_id.this[k].hex}")
  }
}
