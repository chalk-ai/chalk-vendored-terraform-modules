# This module is Karpenter v1 only. There is no way to render a v1beta1 manifest, so a
# v1beta1 fragment surviving anywhere is a mistake rather than a configuration this
# module allows.
#
# Every run here sweeps ALL rendered manifests, with chalk_dataplane_version set to v2 so
# that chalk-nap is in the sweep too.

mock_provider "kubectl" {}

variables {
  cluster_name            = "example-cluster"
  subnets                 = ["subnet-xxxxx", "subnet-yyyyy"]
  chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
}

run "no_manifest_mentions_v1beta1" {
  command = plan

  assert {
    condition = alltrue([
      for body in concat(
        [
          nonsensitive(kubectl_manifest.al2023_node_class.yaml_body),
          nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body),
          nonsensitive(kubectl_manifest.oss_controllers_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body),
        ],
        [for m in kubectl_manifest.gvisor_node_class : nonsensitive(m.yaml_body)],
        [for m in kubectl_manifest.chalk_compute_node_pool : nonsensitive(m.yaml_body)],
        [for m in kubectl_manifest.gvisor_runtime_class : nonsensitive(m.yaml_body)],
        [for m in kubectl_manifest.internal_node_pools : nonsensitive(m.yaml_body)],
      ) : !strcontains(body, "v1beta1")
    ])
    error_message = "a rendered manifest still contains the substring v1beta1"
  }
}

run "no_manifest_emits_amiFamily" {
  command = plan

  # amiFamily and amiSelectorTerms are mutually redundant under v1: the alias
  # al2023@latest already implies the family, and emitting both is rejected outright by
  # some Karpenter versions.
  assert {
    condition = alltrue([
      for body in [
        nonsensitive(kubectl_manifest.al2023_node_class.yaml_body),
        nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body),
        nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body),
      ] : !strcontains(body, "amiFamily")
    ])
    error_message = "an EC2NodeClass still emits amiFamily; under v1 the amiSelectorTerms alias implies it"
  }
  assert {
    condition = alltrue([
      for body in [
        nonsensitive(kubectl_manifest.al2023_node_class.yaml_body),
        nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body),
        nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body),
      ] : yamldecode(body).spec.amiSelectorTerms == [{ alias = "al2023@latest" }]
    ])
    error_message = "amiSelectorTerms must be present on every node class and pin the al2023@latest alias"
  }
}

run "node_class_api_versions_are_v1" {
  command = plan

  assert {
    condition = alltrue([
      for body in [
        nonsensitive(kubectl_manifest.al2023_node_class.yaml_body),
        nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body),
        nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body),
      ] : yamldecode(body).apiVersion == "karpenter.k8s.aws/v1"
    ])
    error_message = "every EC2NodeClass must be karpenter.k8s.aws/v1"
  }
}

run "node_pool_api_versions_are_v1" {
  command = plan

  assert {
    condition = alltrue([
      for body in concat(
        [
          nonsensitive(kubectl_manifest.oss_controllers_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body),
        ],
        [for m in kubectl_manifest.internal_node_pools : nonsensitive(m.yaml_body)],
      ) : yamldecode(body).apiVersion == "karpenter.sh/v1"
    ])
    error_message = "every NodePool must be karpenter.sh/v1"
  }
}

run "every_node_class_ref_carries_group_and_kind" {
  command = plan

  # Under v1beta1 the nodeClassRef had apiVersion+kind+name; under v1 it is
  # group+kind+name. A ref missing group is accepted by the API server and then never
  # resolves, so the pool sits Ready=False forever.
  assert {
    condition = alltrue([
      for body in concat(
        [
          nonsensitive(kubectl_manifest.oss_controllers_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body),
        ],
        [for m in kubectl_manifest.internal_node_pools : nonsensitive(m.yaml_body)],
        ) : (
        yamldecode(body).spec.template.spec.nodeClassRef.group == "karpenter.k8s.aws" &&
        yamldecode(body).spec.template.spec.nodeClassRef.kind == "EC2NodeClass" &&
        length(yamldecode(body).spec.template.spec.nodeClassRef.name) > 0 &&
        length(keys(yamldecode(body).spec.template.spec.nodeClassRef)) == 3
      )
    ])
    error_message = "every nodeClassRef must carry exactly group, kind and name"
  }
}

run "every_pool_bounds_expiry_and_drain" {
  command = plan

  # v1 leaves node draining unbounded unless terminationGracePeriod is set, so a pool
  # missing it can block a rollout indefinitely on a single undrainable pod.
  assert {
    condition = alltrue([
      for body in concat(
        [
          nonsensitive(kubectl_manifest.oss_controllers_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body),
          nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body),
        ],
        [for m in kubectl_manifest.internal_node_pools : nonsensitive(m.yaml_body)],
        ) : (
        yamldecode(body).spec.template.spec.expireAfter == "720h" &&
        yamldecode(body).spec.template.spec.terminationGracePeriod == "30m" &&
        yamldecode(body).spec.disruption == {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
      )
    ])
    error_message = "every NodePool must carry expireAfter 720h, terminationGracePeriod 30m and the v1 consolidation policy"
  }
}
