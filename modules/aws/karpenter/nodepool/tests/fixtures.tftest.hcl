# Replay of two NodePools captured from live customer clusters (anonymised; server metadata and
# status stripped). Each fixture's authored values go in as module inputs, and the rendered manifest
# must parse to exactly the fixture.
#
# The two fixtures disagree sharply and that is the point. Fixture A pins an instance family with
# four requirements, no taints and a cpu-only limit; fixture B has two requirements, a taint and both
# cpu and memory limits. If one hardcoded requirement list satisfied both, the input shape would be
# wrong -- requirements has to be caller-supplied and free-form, and limits has to be a map.
#
# Both fixtures carry disruption and expireAfter, which are Karpenter DEFAULTS the API server wrote
# back rather than values those callers authored. They are passed in explicitly here precisely
# because the module does not emit them on its own.
#
# file() resolves relative paths against the process working directory, so run `tofu test` from the
# module directory.

mock_provider "kubectl" {}

variables {
  name              = "example-pool"
  ec2nodeclass_name = "al2023"
}

# --------------------------------------------------------------------------------------------------
# Fixture A -- instance-family pinned. The machine-type pinning case, already in production.
# --------------------------------------------------------------------------------------------------

run "fixture_a_instance_family_pinned" {
  command = plan

  variables {
    name              = "default-al2023"
    ec2nodeclass_name = "al2023"

    labels = {
      "chalk.ai/managed-by"     = "chalk"
      "chalk.ai/resource-group" = "default"
    }

    requirements = [
      { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] },
      { key = "karpenter.k8s.aws/instance-hypervisor", operator = "In", values = ["nitro"] },
      { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
      { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
    ]

    limits       = { cpu = "1k" }
    weight       = 12
    expire_after = "720h0m0s"

    disruption = {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "0s"
      budgets             = [{ nodes = "10%" }]
    }
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(
      file("./tests/fixtures/nodepool-instance-family-pinned.yaml")
    )
    error_message = "the rendered manifest no longer reproduces the captured instance-family-pinned NodePool"
  }
}

# --------------------------------------------------------------------------------------------------
# Fixture B -- a taint, two limits, and a deliberately minimal requirements set.
# --------------------------------------------------------------------------------------------------

run "fixture_b_taints_and_limits" {
  command = plan

  variables {
    name              = "chalk-nodepool-al2023"
    ec2nodeclass_name = "al2023"

    labels = {
      "chalk.ai/managed-by" = "chalk"
    }

    requirements = [
      { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
      { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
    ]

    taints = [
      { key = "chalk.ai/managed-by", value = "chalk", effect = "NoSchedule" },
    ]

    limits       = { cpu = "500", memory = "5000Gi" }
    weight       = 20
    expire_after = "720h0m0s"

    disruption = {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "0s"
      budgets             = [{ nodes = "10%" }]
    }
  }

  assert {
    condition = yamldecode(output.rendered_manifest) == yamldecode(
      file("./tests/fixtures/nodepool-taints-and-limits.yaml")
    )
    error_message = "the rendered manifest no longer reproduces the captured taints-and-limits NodePool"
  }
}

# --------------------------------------------------------------------------------------------------
# The two fixtures really are different shapes -- guard against a future edit that quietly makes one
# a copy of the other and lets a hardcoded requirement list satisfy both. Every condition compares
# fixture A, rendered through the module, against fixture B read from disk: an assert must reference
# something from the configuration, so a fixture-versus-fixture comparison alone is not accepted.
# --------------------------------------------------------------------------------------------------

run "the_two_fixtures_disagree_on_shape" {
  command = plan

  variables {
    name              = "default-al2023"
    ec2nodeclass_name = "al2023"

    labels = {
      "chalk.ai/managed-by"     = "chalk"
      "chalk.ai/resource-group" = "default"
    }

    requirements = [
      { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] },
      { key = "karpenter.k8s.aws/instance-hypervisor", operator = "In", values = ["nitro"] },
      { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
      { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
    ]

    limits       = { cpu = "1k" }
    weight       = 12
    expire_after = "720h0m0s"

    disruption = {
      consolidationPolicy = "WhenEmptyOrUnderutilized"
      consolidateAfter    = "0s"
      budgets             = [{ nodes = "10%" }]
    }
  }

  assert {
    condition = length(
      yamldecode(output.rendered_manifest).spec.template.spec.requirements
      ) != length(
      yamldecode(file("./tests/fixtures/nodepool-taints-and-limits.yaml")).spec.template.spec.requirements
    )
    error_message = "the two fixtures now carry the same number of requirements, so they no longer prove requirements must be caller-supplied and free-form"
  }
  assert {
    condition = length(keys(yamldecode(output.rendered_manifest).spec.limits)) != length(
      keys(yamldecode(file("./tests/fixtures/nodepool-taints-and-limits.yaml")).spec.limits)
    )
    error_message = "the two fixtures now carry the same number of limit keys, so they no longer prove limits must be a map rather than a fixed cpu/memory/gpu triple"
  }
  assert {
    condition = !can(yamldecode(output.rendered_manifest).spec.template.spec.taints) && can(
      yamldecode(file("./tests/fixtures/nodepool-taints-and-limits.yaml")).spec.template.spec.taints
    )
    error_message = "the pair no longer covers both the with-taints and without-taints shapes"
  }
}
