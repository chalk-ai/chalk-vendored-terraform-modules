# The requirement lists decide what instance types Chalk will actually get. They are
# pinned here field by field, in addition to the whole-manifest pins in
# tests/manifests.tftest.hcl, because these are the values most likely to be "tidied"
# by someone who does not know why they are what they are.

mock_provider "kubectl" {}

variables {
  cluster_name            = "example-cluster"
  subnets                 = ["subnet-xxxxx"]
  chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
}

run "workload_requirements_match_the_source" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)).spec.template.spec.requirements == [
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
      },
    ]
    error_message = "the shared Chalk workload requirement list changed"
  }
}

run "all_workload_pools_share_one_requirement_list" {
  command = plan

  # chalk-infrastructure, chalk-online and chalk-nap must be interchangeable in what
  # they can launch; only chalk-offline differs, and only by the NVMe term.
  assert {
    condition = (
      yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-infrastructure"].yaml_body)).spec.template.spec.requirements ==
      yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)).spec.template.spec.requirements
    )
    error_message = "chalk-infrastructure and chalk-online requirements diverged"
  }
  assert {
    condition = (
      yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-nap"].yaml_body)).spec.template.spec.requirements ==
      yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)).spec.template.spec.requirements
    )
    error_message = "chalk-nap must be able to launch exactly what chalk-online can, or it is not a usable fallback"
  }
}

run "generation_five_is_still_permitted_for_workloads" {
  command = plan

  # Deliberate: generation 5 stays in the workload list even though chalk-compute is
  # 6+. Some regions do not have enough gen-6+ capacity in every AZ, and dropping 5
  # here would turn that into unschedulable pods.
  assert {
    condition = [
      for requirement in yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)).spec.template.spec.requirements :
      requirement.values if requirement.key == "karpenter.k8s.aws/instance-generation"
    ] == [["5", "6", "7", "8"]]
    error_message = "instance-generation on the workload pools must remain In [5, 6, 7, 8]"
  }
  assert {
    condition = [
      for requirement in yamldecode(nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body)).spec.template.spec.requirements :
      requirement.values if requirement.key == "karpenter.k8s.aws/instance-generation"
    ] == [["6", "7", "8"]]
    error_message = "instance-generation on chalk-compute must remain In [6, 7, 8]"
  }
}

run "nitro_hypervisor_is_required_everywhere" {
  command = plan

  assert {
    condition = alltrue([
      for body in concat(
        [
          nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body),
        ],
        [for m in kubectl_manifest.internal_node_pools : nonsensitive(m.yaml_body)],
        ) : [
        for requirement in yamldecode(body).spec.template.spec.requirements :
        requirement.values if requirement.key == "karpenter.k8s.aws/instance-hypervisor"
      ] == [["nitro"]]
    ])
    error_message = "every Chalk pool must require the nitro hypervisor"
  }
}

run "offline_requirements_are_workload_plus_local_nvme" {
  command = plan

  # Expressed as a relationship rather than a second literal list: the point of the
  # offline set is that it is the workload set plus one term, and this fails if either
  # list is edited independently.
  assert {
    condition = (
      yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-offline"].yaml_body)).spec.template.spec.requirements ==
      concat(
        yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)).spec.template.spec.requirements,
        [{
          key      = "karpenter.k8s.aws/instance-local-nvme"
          operator = "Gt"
          values   = ["0"]
        }]
      )
    )
    error_message = "chalk-offline requirements must be the workload list plus instance-local-nvme Gt [0], appended last"
  }
  assert {
    condition = [
      for requirement in yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-offline"].yaml_body)).spec.template.spec.requirements :
      requirement if requirement.key == "karpenter.k8s.aws/instance-local-nvme"
      ] == [{
        key      = "karpenter.k8s.aws/instance-local-nvme"
        operator = "Gt"
        values   = ["0"]
    }]
    error_message = "the offline NVMe requirement must be Gt [\"0\"] -- an In or Exists operator here silently allows instances with no local disk, and the offline node class RAID0s a device that will not exist"
  }
}

run "only_the_offline_pool_requires_local_nvme" {
  command = plan

  assert {
    condition = alltrue([
      for name, m in kubectl_manifest.internal_node_pools : length([
        for requirement in yamldecode(nonsensitive(m.yaml_body)).spec.template.spec.requirements :
        requirement if requirement.key == "karpenter.k8s.aws/instance-local-nvme"
      ]) == (name == "chalk-offline" ? 1 : 0)
    ])
    error_message = "local NVMe must be required by chalk-offline and by no other pool"
  }
}

run "gpu_pool_requires_nvidia" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body)).spec.template.spec.requirements == [
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
    error_message = "the GPU pool requirement list changed"
  }
}

run "every_pool_is_on_demand_only" {
  command = plan

  # No spot anywhere. The source hardcoded this and never exposed it.
  assert {
    condition = alltrue([
      for body in concat(
        [
          nonsensitive(kubectl_manifest.oss_controllers_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body),
        ],
        [for m in kubectl_manifest.internal_node_pools : nonsensitive(m.yaml_body)],
        ) : [
        for requirement in yamldecode(body).spec.template.spec.requirements :
        requirement.values if requirement.key == "karpenter.sh/capacity-type"
      ] == [["on-demand"]]
    ])
    error_message = "a pool no longer restricts capacity-type to on-demand"
  }
}
