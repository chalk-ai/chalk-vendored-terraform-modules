# The chalk_dataplane_version gate.
#
# On dataplane v2 Chalk schedules some of its own workloads without a
# chalk.ai/workload-type toleration, so an untainted fallback pool -- chalk-nap -- has to
# exist for them. On v1 that pool must not exist, and enabling the gate must not perturb
# anything else.

mock_provider "kubectl" {}

variables {
  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx", "subnet-yyyyy"]
}

run "default_creates_no_chalk_nap" {
  command = plan

  assert {
    condition     = length(kubectl_manifest.internal_node_pools) == 3
    error_message = "with chalk_dataplane_version unset there must be exactly 3 internal node pools"
  }
  assert {
    condition     = !contains(keys(kubectl_manifest.internal_node_pools), "chalk-nap")
    error_message = "chalk-nap must not exist unless dataplane v2 is declared"
  }
  assert {
    condition     = output.chalk_nap_enabled == false
    error_message = "chalk_nap_enabled must be false by default"
  }
  assert {
    condition     = !contains(output.node_pool_names, "chalk-nap")
    error_message = "chalk-nap leaked into node_pool_names by default"
  }
}

run "dataplane_v1_creates_no_chalk_nap" {
  command = plan

  variables {
    chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V1"
  }

  assert {
    condition     = length(kubectl_manifest.internal_node_pools) == 3
    error_message = "dataplane v1 must not get the chalk-nap fallback pool"
  }
}

run "an_unrecognised_dataplane_version_creates_no_chalk_nap" {
  command = plan

  variables {
    chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2 "
  }

  # Documented sharp edge: the comparison is an exact string match with no validation
  # behind it, so a near-miss value silently yields nine objects instead of ten rather
  # than failing.
  assert {
    condition     = length(kubectl_manifest.internal_node_pools) == 3
    error_message = "the dataplane gate is no longer an exact string match; if that is intentional, update the README, which documents the near-miss behaviour"
  }
}

run "dataplane_v2_adds_chalk_nap" {
  command = plan

  variables {
    chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
  }

  assert {
    condition     = length(kubectl_manifest.internal_node_pools) == 4
    error_message = "dataplane v2 must add exactly one internal node pool"
  }
  assert {
    condition     = contains(keys(kubectl_manifest.internal_node_pools), "chalk-nap")
    error_message = "dataplane v2 must add chalk-nap"
  }
  assert {
    condition     = output.chalk_nap_enabled == true
    error_message = "chalk_nap_enabled must be true on dataplane v2"
  }
  assert {
    condition = length([
      for taint in yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-nap"].yaml_body)).spec.template.spec.taints :
      taint if taint.key == "chalk.ai/workload-type"
    ]) == 0
    error_message = "chalk-nap must NOT carry a chalk.ai/workload-type taint -- an untainted fallback is the only reason it exists"
  }
}

run "dataplane_v2_changes_nothing_else" {
  command = plan

  variables {
    chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
  }

  # var.chalk_dataplane_version feeds exactly one local, which feeds exactly one for_each,
  # so the three pre-existing internal pools are the only objects that could plausibly be
  # perturbed. They are pinned here in full; the counts below cover the rest.
  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-infrastructure"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-infrastructure"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "infrastructure"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "infrastructure"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
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
            taints = [
              {
                key    = "chalk.ai/workload-type"
                value  = "infrastructure"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "enabling dataplane v2 changed the chalk-infrastructure NodePool; the gate must only ADD chalk-nap"
  }
  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-online"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "online"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "online"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
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
            taints = [
              {
                key    = "chalk.ai/workload-type"
                value  = "online"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "enabling dataplane v2 changed the chalk-online NodePool; the gate must only ADD chalk-nap"
  }
  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-offline"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-offline"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "offline"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "offline"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023-offline-lssd"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
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
              {
                key      = "karpenter.k8s.aws/instance-local-nvme"
                operator = "Gt"
                values   = ["0"]
              },
            ]
            taints = [
              {
                key    = "chalk.ai/workload-type"
                value  = "offline"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "enabling dataplane v2 changed the chalk-offline NodePool; the gate must only ADD chalk-nap"
  }

  assert {
    condition = (
      length(kubectl_manifest.gvisor_node_class) == 1 &&
      length(kubectl_manifest.chalk_compute_node_pool) == 1 &&
      length(kubectl_manifest.gvisor_runtime_class) == 1
    )
    error_message = "the dataplane gate must not affect the gVisor objects"
  }
  assert {
    condition     = output.ec2_node_class_names == ["al2023", "al2023-offline-lssd", "gvisor"]
    error_message = "the dataplane gate must not affect the EC2NodeClass set"
  }
}
