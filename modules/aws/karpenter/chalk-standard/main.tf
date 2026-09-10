################################################################################
# Karpenter - Chalk standard node classes, node pools and runtime class
#
# Creates the standard set of Karpenter objects a Chalk deployment expects --
# three EC2NodeClass objects, six NodePool objects and one RuntimeClass -- on an
# EKS cluster that Chalk does NOT manage. On a Chalk-managed cluster these
# objects already exist; on a self-managed cluster nothing creates them, and the
# Chalk UI cannot fill the gap -- it creates NodePools only, requires an
# EC2NodeClass to already exist, and cannot create a RuntimeClass at all.
#
# This module manages node *shape* only. It does NOT install the Karpenter
# controller or its CRDs, does NOT create the controller's IAM role or policy,
# and does NOT create the spot-interruption queue or the CloudWatch event rules
# that feed it. All of that must already exist on the cluster: installing and
# empowering the Karpenter controller stays with the cluster's owner.
################################################################################

locals {
  # ---------------------------------------------------------------------------
  # Values this module fixes deliberately. These are locals, not variables:
  # this module exists to be opinionated, and every one of these promoted to an
  # input turns it back into a generic node-pool builder. Change one by editing
  # this file, which puts the change through review.
  # ---------------------------------------------------------------------------

  # Ceiling on aggregate vCPU per Chalk node pool. Large enough not to bind in
  # practice; present so a runaway workload cannot scale a pool without limit.
  max_cpu = 128000

  # The gVisor node class, its compute pool and the RuntimeClass travel together:
  # each is useless without the other two, so all three are always created.
  create_gvisor_nodeclass = true

  # Karpenter v1 sizing. v1 nodes get a larger boot disk than the v1beta1 ones did.
  boot_volume_size         = "200Gi"
  offline_boot_volume_size = "200Gi"

  # v1 leaves node draining unbounded unless terminationGracePeriod is set, so it
  # is always set here. expireAfter and the disruption settings match the current
  # Karpenter CRD defaults but are emitted anyway, so the applied object states
  # them outright; see README "Behaviour worth knowing".
  node_pool_common = {
    expire_after             = "720h"
    termination_grace_period = "30m"
    consolidation_policy     = "WhenEmptyOrUnderutilized"
    consolidate_after        = "0s"
    weight                   = 10
    max_cpu                  = local.max_cpu
  }

  # The node role naming convention Chalk-managed clusters follow. Override
  # var.node_role_name when the cluster's role was created outside it.
  node_role_name = coalesce(var.node_role_name, "${var.cluster_name}-Managed-Node-Role")

  # A plain list of subnet IDs, one selector term each. Selecting subnets by tag
  # is not part of Chalk's standard shape, so no other term shape is rendered.
  subnet_selector_terms = [for net in var.subnets : { id = net }]

  # ---------------------------------------------------------------------------
  # Requirement sets
  # ---------------------------------------------------------------------------

  # Standard Chalk workload nodes: general purpose / memory / compute optimised,
  # Nitro only, on-demand only, x86 Linux. Generation 5 is still permitted because
  # some regions do not offer enough gen-6+ capacity in every AZ.
  chalk_workload_requirements = [
    {
      key      = "karpenter.k8s.aws/instance-category"
      operator = "In"
      values   = ["m", "r", "c"]
    },
    {
      key      = "karpenter.k8s.aws/instance-generation"
      operator = "In"
      values   = ["5", "6", "7", "8"]
    },
    {
      key      = "karpenter.k8s.aws/instance-hypervisor"
      operator = "In"
      values   = ["nitro"]
    },
    {
      key      = "karpenter.sh/capacity-type"
      operator = "In"
      values   = ["on-demand"]
    },
    {
      key      = "kubernetes.io/arch"
      operator = "In"
      values   = ["amd64"]
    },
    {
      key      = "kubernetes.io/os"
      operator = "In"
      values   = ["linux"]
    }
  ]

  # Offline nodes additionally require local NVMe, which the al2023-offline-lssd
  # node class RAID0s and mounts for scratch space.
  chalk_offline_requirements = concat(local.chalk_workload_requirements, [
    {
      key      = "karpenter.k8s.aws/instance-local-nvme"
      operator = "Gt"
      values   = ["0"]
    }
  ])

  # ---------------------------------------------------------------------------
  # Node pool definitions
  # ---------------------------------------------------------------------------

  internal_node_pools = {
    chalk-infrastructure = {
      node_class_name     = "al2023"
      workload_type       = "infrastructure"
      requirements        = local.chalk_workload_requirements
      taint_workload_type = true
    }
    chalk-online = {
      node_class_name     = "al2023"
      workload_type       = "online"
      requirements        = local.chalk_workload_requirements
      taint_workload_type = true
    }
    chalk-offline = {
      node_class_name     = "al2023-offline-lssd"
      workload_type       = "offline"
      requirements        = local.chalk_offline_requirements
      taint_workload_type = true
    }
  }

  # Dataplane v2 gets an online-compatible fallback pool for Chalk-managed
  # workloads that do not carry a workload-type toleration. Note it is NOT tainted
  # with chalk.ai/workload-type -- that is the whole point of it.
  dataplane_v2_node_pools = var.chalk_dataplane_version == "CHALK_DATAPLANE_VERSION_V2" ? {
    chalk-nap = {
      node_class_name     = "al2023"
      workload_type       = "online"
      requirements        = local.chalk_workload_requirements
      taint_workload_type = false
    }
  } : {}

  all_internal_node_pools = merge(local.internal_node_pools, local.dataplane_v2_node_pools)
}

################################################################################
# EC2NodeClass - AL2023 Standard
################################################################################

resource "kubectl_manifest" "al2023_node_class" {
  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/ec2nodeclass-al2023.yaml.tftpl", {
    name                  = "al2023"
    role                  = local.node_role_name
    cluster_name          = var.cluster_name
    subnets               = var.subnets
    volume_size           = local.boot_volume_size
    instance_store_policy = null
  })

  wait                = true
  wait_for_rollout    = true
  upgrade_api_version = true
}

################################################################################
# EC2NodeClass - AL2023 with Local SSD (RAID0)
################################################################################

resource "kubectl_manifest" "al2023_lssd_node_class" {
  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/ec2nodeclass-al2023.yaml.tftpl", {
    name                  = "al2023-offline-lssd"
    role                  = local.node_role_name
    cluster_name          = var.cluster_name
    subnets               = var.subnets
    volume_size           = local.offline_boot_volume_size
    instance_store_policy = "RAID0"
  })

  wait                = true
  wait_for_rollout    = true
  upgrade_api_version = true
}

################################################################################
# EC2NodeClass - gVisor Container Runtime
#
# Same base image as al2023, plus MIME-multipart user data that installs runsc
# and registers it as a containerd runtime. The install waits for nodeadm to
# write /etc/containerd/config.toml before appending to it, so ordering against
# the AL2023 bootstrap is not left to chance.
################################################################################

resource "kubectl_manifest" "gvisor_node_class" {
  count = local.create_gvisor_nodeclass ? 1 : 0

  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/ec2nodeclass-gvisor.yaml.tftpl", {
    role         = local.node_role_name
    cluster_name = var.cluster_name
    subnets      = var.subnets
    volume_size  = local.boot_volume_size
  })

  wait                = true
  wait_for_rollout    = true
  upgrade_api_version = true
}

################################################################################
# NodePool - OSS Controllers
#
# Small, untainted pool that open-source controllers land on. Its 6 vCPU limit is
# the one place this module does not use local.max_cpu.
################################################################################

resource "kubectl_manifest" "oss_controllers_node_pool" {
  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/nodepool.yaml.tftpl", merge(local.node_pool_common, {
    name = "oss-controllers"
    labels = {
      "chalk.ai/visibility" = "internal"
    }
    node_labels     = {}
    node_class_name = "al2023"
    requirements = [
      {
        key      = "node.kubernetes.io/instance-type"
        operator = "In"
        values   = ["t3.medium"]
      },
      {
        key      = "karpenter.sh/capacity-type"
        operator = "In"
        values   = ["on-demand"]
      }
    ]
    taints  = []
    max_cpu = 6
  }))

  upgrade_api_version = true

  # NodePool specs carry no secrets; show the full diff in plans rather than the
  # provider default of redacting "spec".
  sensitive_fields = []

  # A NodePool whose nodeClassRef does not resolve yet goes Ready=False rather
  # than failing, so this ordering is not enforced by Karpenter itself. It is
  # declared here so a fresh apply never leaves this pool briefly unusable.
  depends_on = [
    kubectl_manifest.al2023_node_class
  ]
}

################################################################################
# NodePools - Chalk Internal Workloads
#
# chalk-infrastructure / chalk-online / chalk-offline, plus chalk-nap on
# dataplane v2. All but chalk-nap carry a chalk.ai/workload-type taint in addition
# to the chalk.ai/managed-by taint every pool here carries.
################################################################################

resource "kubectl_manifest" "internal_node_pools" {
  for_each = local.all_internal_node_pools

  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/nodepool.yaml.tftpl", merge(local.node_pool_common, {
    name = each.key
    labels = {
      "chalk.ai/visibility"    = "internal"
      "chalk.ai/workload-type" = each.value.workload_type
    }
    node_labels = {
      "chalk.ai/managed-by"    = "chalk"
      "chalk.ai/workload-type" = each.value.workload_type
    }
    node_class_name = each.value.node_class_name
    requirements    = each.value.requirements
    taints = concat(
      each.value.taint_workload_type ? [
        {
          key    = "chalk.ai/workload-type"
          value  = each.value.workload_type
          effect = "NoSchedule"
        }
      ] : [],
      [
        {
          key    = "chalk.ai/managed-by"
          value  = "chalk"
          effect = "NoSchedule"
        }
      ]
    )
  }))

  upgrade_api_version = true
  wait                = true
  wait_for_rollout    = true

  # NodePool specs carry no secrets; show the full diff in plans rather than the
  # provider default of redacting "spec".
  sensitive_fields = []

  depends_on = [
    kubectl_manifest.al2023_node_class,
    kubectl_manifest.al2023_lssd_node_class
  ]
}

################################################################################
# NodePool - Chalk Compute (gVisor)
#
# Sandboxed compute. Triple-tainted so nothing lands here that has not opted in
# to the gVisor runtime; the RuntimeClass below carries the matching tolerations.
################################################################################

resource "kubectl_manifest" "chalk_compute_node_pool" {
  count = local.create_gvisor_nodeclass ? 1 : 0

  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/nodepool.yaml.tftpl", merge(local.node_pool_common, {
    name = "chalk-compute"
    labels = {
      "chalk.ai/visibility" = "internal"
    }
    node_labels = {
      "chalk.ai/container-runtime" = "gvisor"
      "chalk.ai/managed-by"        = "chalk"
      "chalk.ai/workload-type"     = "compute"
    }
    node_class_name = "gvisor"
    requirements = [
      {
        key      = "karpenter.k8s.aws/instance-category"
        operator = "In"
        values   = ["m", "r", "c"]
      },
      {
        key      = "karpenter.k8s.aws/instance-generation"
        operator = "In"
        values   = ["6", "7", "8"]
      },
      {
        key      = "karpenter.k8s.aws/instance-hypervisor"
        operator = "In"
        values   = ["nitro"]
      },
      {
        key      = "kubernetes.io/arch"
        operator = "In"
        values   = ["amd64"]
      },
      {
        key      = "kubernetes.io/os"
        operator = "In"
        values   = ["linux"]
      },
      {
        key      = "karpenter.sh/capacity-type"
        operator = "In"
        values   = ["on-demand"]
      },
    ]
    taints = [
      {
        key    = "chalk.ai/container-runtime"
        value  = "gvisor"
        effect = "NoSchedule"
      },
      {
        key    = "chalk.ai/workload-type"
        value  = "compute"
        effect = "NoSchedule"
      },
      {
        key    = "chalk.ai/managed-by"
        value  = "chalk"
        effect = "NoSchedule"
      }
    ]
  }))

  upgrade_api_version = true
  wait                = true
  wait_for_rollout    = true

  # NodePool specs carry no secrets; show the full diff in plans rather than the
  # provider default of redacting "spec".
  sensitive_fields = []

  depends_on = [
    kubectl_manifest.gvisor_node_class
  ]
}

################################################################################
# NodePool - Chalk Compute (GPU)
#
# Internal compute pool backed by NVIDIA GPU instances (g/p families) on the
# shared AL2023 node class. The nvidia.com/gpu taint keeps non-GPU workloads off
# these nodes. This module does NOT install the NVIDIA device plugin -- without a
# device plugin DaemonSet that tolerates nvidia.com/gpu, these nodes will never
# advertise the nvidia.com/gpu resource.
################################################################################

resource "kubectl_manifest" "chalk_compute_gpu_node_pool" {
  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/nodepool.yaml.tftpl", merge(local.node_pool_common, {
    name = "chalk-compute-gpu"
    labels = {
      "chalk.ai/visibility" = "internal"
    }
    node_labels = {
      "chalk.ai/managed-by"    = "chalk"
      "chalk.ai/workload-type" = "compute"
      "nvidia.com/gpu.present" = "true"
    }
    node_class_name = "al2023"
    requirements = [
      {
        key      = "karpenter.k8s.aws/instance-category"
        operator = "In"
        values   = ["g", "p"]
      },
      {
        key      = "karpenter.k8s.aws/instance-gpu-manufacturer"
        operator = "In"
        values   = ["nvidia"]
      },
      {
        key      = "karpenter.k8s.aws/instance-generation"
        operator = "In"
        values   = ["4", "5", "6"]
      },
      {
        key      = "karpenter.k8s.aws/instance-hypervisor"
        operator = "In"
        values   = ["nitro"]
      },
      {
        key      = "kubernetes.io/arch"
        operator = "In"
        values   = ["amd64"]
      },
      {
        key      = "kubernetes.io/os"
        operator = "In"
        values   = ["linux"]
      },
      {
        key      = "karpenter.sh/capacity-type"
        operator = "In"
        values   = ["on-demand"]
      },
    ]
    taints = [
      {
        key    = "nvidia.com/gpu"
        value  = "true"
        effect = "NoSchedule"
      },
      {
        key    = "chalk.ai/workload-type"
        value  = "compute"
        effect = "NoSchedule"
      },
      {
        key    = "chalk.ai/managed-by"
        value  = "chalk"
        effect = "NoSchedule"
      },
    ]
  }))

  upgrade_api_version = true
  wait                = true
  wait_for_rollout    = true

  # NodePool specs carry no secrets; show the full diff in plans rather than the
  # provider default of redacting "spec".
  sensitive_fields = []

  depends_on = [
    kubectl_manifest.al2023_node_class,
  ]
}

################################################################################
# RuntimeClass - gVisor
#
# Pods that set runtimeClassName: gvisor inherit the node selector and the three
# tolerations needed to land on the chalk-compute pool. Karpenter's UI cannot
# create this object at all, which is a large part of why this module exists.
################################################################################

resource "kubectl_manifest" "gvisor_runtime_class" {
  count = local.create_gvisor_nodeclass ? 1 : 0

  timeouts {
    delete = "45m"
  }

  yaml_body = templatefile("${path.module}/templates/runtimeclass-gvisor.yaml.tftpl", {})
}
