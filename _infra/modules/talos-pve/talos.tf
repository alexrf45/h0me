
resource "talos_machine_secrets" "this" {
  talos_version = var.talos.version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.talos.name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes = [
    for k, v in merge(var.worker_nodes, var.controlplane_nodes) : v.ip
  ]
  endpoints = [for k, v in var.controlplane_nodes : v.ip]
}


data "talos_machine_configuration" "controlplane" {
  for_each           = var.controlplane_nodes
  cluster_name       = var.talos.name
  cluster_endpoint   = "https://${var.talos.endpoint}:6443"
  talos_version      = var.talos.version
  kubernetes_version = trimprefix(var.kubernetes_version, "v")
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  config_patches = [
    <<-EOT
    version: v1alpha1
    machine:
${chomp(local.machine_common)}
      install:
        disk: ${var.talos.install_disk}
        image: ${data.talos_image_factory_urls.controlplane.urls.installer}
        wipe: true
        extraKernelArgs:
          - console=ttyS1
          - panic=10
          - cpufreq.default_governor=performance
          - intel_idle.max_cstate=0
          - disable_ipv6=1
      network:
        nameservers:
          - ${var.nameservers.primary}
          - ${var.nameservers.secondary}
        interfaces:
          - interface: eth0
            dhcp: false
            vip:
              ip: ${var.talos.vip_ip}
    cluster:
      apiServer:
        auditPolicy:
          apiVersion: audit.k8s.io/v1
          kind: Policy
          rules:
            - level: Metadata
        admissionControl:
          - name: PodSecurity
            configuration:
              apiVersion: pod-security.admission.config.k8s.io/v1beta1
              kind: PodSecurityConfiguration
              exemptions:
                namespaces:
                  - networking
                  - storage
      network:
        cni:
          name: none
        podSubnets:
          - ${var.talos.pod_subnet}
        serviceSubnets:
          - ${var.talos.service_subnet}
      proxy:
        disabled: true
      extraManifests:
%{for m in var.talos.extra_manifests~}
        - ${m}
%{endfor~}
      inlineManifests:
        - name: namespace-flux
          contents: |
            apiVersion: v1
            kind: Namespace
            metadata:
              name: flux-system
        - name: namespace-networking
          contents: |
            apiVersion: v1
            kind: Namespace
            metadata:
              name: networking
              labels:
                pod-security.kubernetes.io/enforce: "privileged"
                app: "networking"
        - name: namespace-storage
          contents: |
            apiVersion: v1
            kind: Namespace
            metadata:
              name: storage
              labels:
                pod-security.kubernetes.io/enforce: "privileged"
                app: "storage"
    EOT
    ,
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            name = "cilium"
            contents = join("---\n", [
              local.cilium_owned_manifest,
              "# Source cilium.tf\n${local.cilium_lb_manifest}",
            ])
          }
        ]
      }
    }),
    # Per-node hostname + scheduling. Moved here from the former
    # talos_machine_configuration_apply (talos_machine has no config_patches).
    <<-EOT
    ---
    apiVersion: v1alpha1
    kind: HostnameConfig
    auto: off
    hostname: ${var.env}-${var.talos.name}-cp-${random_id.this[each.key].hex}
    ---
    version: v1alpha1
    cluster:
      allowSchedulingOnControlPlanes: ${each.value.allow_scheduling}
    EOT
  ]
}


data "talos_machine_configuration" "worker" {
  for_each           = var.worker_nodes
  cluster_name       = var.talos.name
  cluster_endpoint   = "https://${var.talos.endpoint}:6443"
  talos_version      = var.talos.version
  kubernetes_version = trimprefix(var.kubernetes_version, "v")
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  config_patches = [
    <<-EOT
    version: v1alpha1
    cluster:
      network:
        podSubnets:
          - ${var.talos.pod_subnet}
        serviceSubnets:
          - ${var.talos.service_subnet}
    machine:
${chomp(local.machine_common)}
      install:
        disk: ${var.talos.install_disk}
        image: ${data.talos_image_factory_urls.worker.urls.installer}
        wipe: true
        extraKernelArgs:
          - console=ttyS1
          - panic=10
          - cpufreq.default_governor=performance
          - intel_idle.max_cstate=0
          - disable_ipv6=1
      network:
        nameservers:
          - ${var.nameservers.primary}
          - ${var.nameservers.secondary}
        interfaces:
          - interface: eth0
            dhcp: false
    EOT
    ,
    # Per-node hostname. Moved here from the former
    # talos_machine_configuration_apply (talos_machine has no config_patches).
    <<-EOT
    ---
    apiVersion: v1alpha1
    kind: HostnameConfig
    auto: off
    hostname: ${var.env}-${var.talos.name}-node-${random_id.this[each.key].hex}
    EOT
  ]
}


# Ephemeral kubeconfig derived from machine_secrets only (no running-cluster
# dependency), used solely to satisfy talos_machine.drain_on_upgrade without a
# kubeconfig -> cluster -> machine cycle. Drain only fires on upgrades.
ephemeral "talos_cluster_kubeconfig" "this" {
  cluster_name    = var.talos.name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = "https://${var.talos.endpoint}:6443"
}


resource "talos_machine" "controlplane" {
  for_each = var.controlplane_nodes
  depends_on = [
    proxmox_virtual_environment_vm.controlplane,
    data.talos_machine_configuration.controlplane,
  ]

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.controlplane[each.key].machine_configuration

  # installer image drives in-place OS upgrades + drift detection (decoupled
  # from the Proxmox VM disk, which is boot media only).
  image            = data.talos_image_factory_urls.controlplane.urls.installer
  drain_on_upgrade = true
  kubeconfig_wo    = ephemeral.talos_cluster_kubeconfig.this.kubeconfig_raw

  # graceful etcd leave on node removal (fixes README scale-down caveat).
  on_destroy = {
    reset    = true
    graceful = true
  }

  timeouts = {
    create = "10m"
    update = "10m"
  }
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.controlplane[each.key]]
  }
}

resource "talos_machine" "worker" {
  for_each = var.worker_nodes
  depends_on = [
    proxmox_virtual_environment_vm.worker,
    data.talos_machine_configuration.worker,
    talos_machine.controlplane,
  ]

  node                  = each.value.ip
  client_configuration  = talos_machine_secrets.this.client_configuration
  machine_configuration = data.talos_machine_configuration.worker[each.key].machine_configuration

  image            = data.talos_image_factory_urls.worker.urls.installer
  drain_on_upgrade = true
  kubeconfig_wo    = ephemeral.talos_cluster_kubeconfig.this.kubeconfig_raw

  on_destroy = {
    reset    = true
    graceful = true
  }

  timeouts = {
    create = "10m"
    update = "10m"
  }
  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.worker[each.key]]
  }
}


# Bootstraps etcd and gates on Talos-layer health (idempotent on an
# already-bootstrapped cluster — replaces talos_machine_bootstrap + the two
# fixed time_sleep waits). kubernetes_version is authoritative for k8s upgrades.
resource "talos_cluster" "this" {
  depends_on = [
    talos_machine.controlplane,
    talos_machine.worker,
  ]

  node                 = values(var.controlplane_nodes)[0].ip
  control_plane_nodes  = [for k, v in var.controlplane_nodes : v.ip]
  kubernetes_version   = var.kubernetes_version
  client_configuration = talos_machine_secrets.this.client_configuration

  timeouts = {
    create = "10m"
    update = "10m"
  }
}


resource "talos_cluster_kubeconfig" "this" {
  depends_on = [
    talos_cluster.this
  ]
  node                 = var.talos.endpoint
  endpoint             = var.talos.endpoint
  client_configuration = talos_machine_secrets.this.client_configuration
  timeouts = {
    read   = "1m"
    create = "5m"
  }
}
