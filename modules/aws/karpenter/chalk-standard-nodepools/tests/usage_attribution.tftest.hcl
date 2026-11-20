# Plan-only checks of the rendered Kubernetes manifests. The mocked provider
# never contacts a Kubernetes cluster or launches nodes.
mock_provider "kubectl" {}

variables {
  cluster_name = "chalk-nodepool-test"
  subnets      = ["subnet-test"]
}

run "attributed_nodepools" {
  command = plan

  assert {
    condition = alltrue([
      for name in ["chalk-online", "chalk-offline"] : toset([
        for requirement in yamldecode(kubectl_manifest.internal_node_pools[name].yaml_body).spec.template.spec.requirements :
        requirement.key if requirement.operator == "Exists" && !contains(keys(requirement), "values")
      ]) == toset(["chalk.ai/environment-id", "chalk.ai/resource-group", "chalk.ai/component"])
    ])
    error_message = "Online and offline nodes must derive all three attribution labels from workload constraints, using Exists without values."
  }

  assert {
    condition = toset([
      for requirement in yamldecode(kubectl_manifest.internal_node_pools["chalk-infrastructure"].yaml_body).spec.template.spec.requirements :
      requirement.key if requirement.operator == "Exists" && !contains(keys(requirement), "values")
    ]) == toset(["chalk.ai/component"])
    error_message = "Shared infrastructure must require component attribution without environment or resource-group ownership."
  }

  assert {
    condition = alltrue([
      for pool in kubectl_manifest.internal_node_pools :
      yamldecode(pool.yaml_body).spec.template.spec.startupTaints == [{
        key    = "chalk.ai/usage-attribution-pending"
        value  = "pending"
        effect = "NoSchedule"
      }]
    ])
    error_message = "All three attributed pools must start behind the NoSchedule usage-attribution gate."
  }

  assert {
    condition = alltrue([
      for name, pool in kubectl_manifest.internal_node_pools :
      yamldecode(pool.yaml_body).spec.template.spec.taints == [
        { key = "chalk.ai/workload-type", value = trimprefix(name, "chalk-"), effect = "NoSchedule" },
        { key = "chalk.ai/managed-by", value = "chalk", effect = "NoSchedule" },
        ] && yamldecode(pool.yaml_body).spec.template.metadata.labels == {
        "chalk.ai/managed-by"    = "chalk"
        "chalk.ai/workload-type" = trimprefix(name, "chalk-")
      }
    ])
    error_message = "Usage attribution must preserve existing workload labels and scheduling taints."
  }

  assert {
    condition = alltrue([
      for pool in concat(values(kubectl_manifest.internal_node_pools), kubectl_manifest.chalk_compute_node_pool, [kubectl_manifest.chalk_compute_gpu_node_pool]) :
      yamldecode(pool.yaml_body).spec.template.spec.expireAfter == "Never" &&
      !contains(keys(yamldecode(pool.yaml_body).spec.template.spec), "terminationGracePeriod")
    ])
    error_message = "All internal pools must let protected jobs finish without node expiry or a forced drain deadline."
  }

  assert {
    condition = (
      yamldecode(kubectl_manifest.internal_node_pools["chalk-infrastructure"].yaml_body).spec.disruption == {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "5m"
        budgets             = [{ nodes = "1" }]
        } && alltrue([
          for pool in concat([
            kubectl_manifest.internal_node_pools["chalk-online"],
            kubectl_manifest.internal_node_pools["chalk-offline"],
          ], kubectl_manifest.chalk_compute_node_pool, [kubectl_manifest.chalk_compute_gpu_node_pool]) :
          yamldecode(pool.yaml_body).spec.disruption == {
            consolidationPolicy = "WhenEmptyOrUnderutilized"
            consolidateAfter    = "0s"
          }
      ])
    )
    error_message = "Only infrastructure should use a five-minute consolidation delay and a one-node disruption budget."
  }

  assert {
    condition = alltrue([
      for pool in concat(kubectl_manifest.chalk_compute_node_pool, [kubectl_manifest.chalk_compute_gpu_node_pool]) :
      !contains(keys(yamldecode(pool.yaml_body).spec.template.spec), "startupTaints") &&
      alltrue([for requirement in yamldecode(pool.yaml_body).spec.template.spec.requirements : requirement.operator != "Exists"]) &&
      length(yamldecode(pool.yaml_body).spec.template.spec.taints) == 3
    ])
    error_message = "Compute pools must retain their three scheduling taints without attribution requirements or startup gates."
  }

  assert {
    condition = contains([
      for requirement in yamldecode(kubectl_manifest.internal_node_pools["chalk-offline"].yaml_body).spec.template.spec.requirements :
      jsonencode(requirement)
      ], jsonencode({ key = "karpenter.k8s.aws/instance-local-nvme", operator = "Gt", values = ["0"] })) && (
      yamldecode(kubectl_manifest.internal_node_pools["chalk-offline"].yaml_body).spec.template.spec.nodeClassRef.name == "al2023-offline-lssd"
    )
    error_message = "Offline nodes must keep their local-NVMe requirement and node class."
  }
}

run "startup_gate_can_be_disabled" {
  command = plan

  variables {
    enable_usage_startup_taint = false
  }

  assert {
    condition = alltrue([
      for pool in kubectl_manifest.internal_node_pools :
      !contains(keys(yamldecode(pool.yaml_body).spec.template.spec), "startupTaints")
    ])
    error_message = "Disabling the startup gate must omit startupTaints from all three attributed pools."
  }

  assert {
    condition = alltrue([
      for name, pool in kubectl_manifest.internal_node_pools :
      toset([
        for requirement in yamldecode(pool.yaml_body).spec.template.spec.requirements :
        requirement.key if requirement.operator == "Exists"
        ]) == (name == "chalk-infrastructure" ? toset(["chalk.ai/component"]) : toset([
          "chalk.ai/environment-id", "chalk.ai/resource-group", "chalk.ai/component",
      ]))
    ])
    error_message = "Disabling the startup gate must preserve the attribution requirements."
  }
}
