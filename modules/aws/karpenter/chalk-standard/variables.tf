# This module takes two inputs and nothing else. It creates one fixed, opinionated
# set of Karpenter objects, so every shape decision is a `local` in main.tf rather
# than a variable. The only inputs are the two facts that cannot be known ahead of
# time: where nodes go, and what the cluster is called.

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
      * the node role name, derived as `"<cluster_name>-Managed-Node-Role"`.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.cluster_name)) > 0
    error_message = "cluster_name must not be empty. It keys the security-group selector terms and the instance tags; an empty value produces node classes that match no security group."
  }
}
