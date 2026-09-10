# This module is deliberately almost input-free. It creates one fixed, opinionated
# set of Karpenter objects, so every shape decision is a `local` in main.tf rather
# than a variable. Only genuinely per-cluster facts -- where nodes go, and what the
# cluster is called -- are inputs.

variable "subnets" {
  description = <<-EOT
    Subnet IDs Karpenter may launch nodes into. Rendered into every EC2NodeClass as
    `subnetSelectorTerms: [{ id = <subnet> }]`, one term per element.

    This is a plain `list(string)`, not a selector-term object: selecting subnets by
    tag is not part of Chalk's standard shape, and accepting arbitrary selector terms
    is what turns this module back into a generic building block.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnets) > 0
    error_message = "At least one subnet ID is required. An EC2NodeClass with no subnetSelectorTerms can never launch a node, and Karpenter reports it as NotReady rather than failing loudly."
  }
}

variable "cluster_name" {
  description = <<-EOT
    Name of the EKS cluster these nodes join. Used in three places, all of them
    load-bearing:

      * `securityGroupSelectorTerms` -- matched against both the `karpenter.sh/discovery`
        and the `aws:eks:cluster-name` tag, so either tagging convention works.
      * the EC2NodeClass `tags` block, so launched instances carry `karpenter.sh/discovery`.
      * the default value of `node_role_name`.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.cluster_name)) > 0
    error_message = "cluster_name must not be empty. It keys the security-group selector terms and the instance tags; an empty value produces node classes that match no security group."
  }
}

variable "node_role_name" {
  description = <<-EOT
    Name (not ARN) of the IAM role Karpenter assigns to nodes it launches. Defaults to
    `"<cluster_name>-Managed-Node-Role"`, which is the naming convention Chalk's own
    clusters use.

    Override this when the cluster's managed node role was created outside that
    convention. The role must already exist and must be mapped in the cluster's auth
    configuration -- this module does not create or grant anything in IAM.
  EOT
  type        = string
  default     = null

  validation {
    # `role` in the EC2NodeClass schema takes a bare role name; Karpenter resolves the
    # ARN itself. Passing an ARN is accepted by the API server and then fails at node
    # launch time, which is an expensive place to discover a typo.
    condition     = !startswith(coalesce(var.node_role_name, "unset"), "arn:")
    error_message = "node_role_name must be a bare IAM role name, not an ARN. Karpenter's EC2NodeClass `role` field resolves the ARN itself; an ARN here is accepted by the API server and only fails later, at node launch."
  }

  validation {
    condition     = length(trimspace(coalesce(var.node_role_name, "unset"))) > 0
    error_message = "node_role_name must not be blank. Leave it unset to derive \"<cluster_name>-Managed-Node-Role\" instead."
  }
}
