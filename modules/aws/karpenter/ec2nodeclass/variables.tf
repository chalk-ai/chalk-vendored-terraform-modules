# ---------------------------------------------------------------------------------------------------
# Required inputs. No defaults: none of these three can be guessed, and a wrong subnet selector
# produces nodes that never launch rather than a clear error.
# ---------------------------------------------------------------------------------------------------

variable "subnet_selector_terms" {
  description = <<-EOT
    Karpenter `spec.subnetSelectorTerms`, verbatim. Each term sets exactly one of `id` or a
    non-empty `tags` map. Terms are ORed; conditions inside one term are ANDed. Tag values accept
    `*` wildcards, and an empty tag value matches any value for that key.

    This mirrors Karpenter's native term shape rather than taking a `list(string)` of subnet IDs,
    because a flat list can only ever express the `id` form and so can never express
    `karpenter.sh/discovery` tag discovery.
  EOT

  type = list(object({
    id   = optional(string)
    tags = optional(map(string))
  }))

  validation {
    condition     = length(var.subnet_selector_terms) > 0
    error_message = "subnet_selector_terms must contain at least one term. Karpenter requires subnetSelectorTerms on every EC2NodeClass, and an empty list renders a node class that can never launch a node."
  }

  # Exactly one of id / non-empty tags per term. The template branches on `term.id != null`, so this
  # is a structural assumption of THIS module and not merely a restatement of the CRD schema.
  #
  # `alltrue([for ...])` rather than an index: a condition written against
  # `var.subnet_selector_terms[0]` passes every single-element and every all-valid case and fails
  # only on a list whose LAST element is bad. tests/subnet_selector_terms.tftest.hcl pins that.
  #
  # An empty `tags = {}` map is caught here too -- it satisfies neither side -- which is why there
  # is no separate "tags must be non-empty" rule to double-fire in the same run.
  validation {
    condition = alltrue([
      for t in var.subnet_selector_terms :
      (t.id != null) != (t.tags != null && length(coalesce(t.tags, {})) > 0)
    ])
    error_message = "Each subnet selector term must set exactly one of `id` or a non-empty `tags` map. A term that sets both, sets neither, or sets `tags = {}` is ambiguous."
  }

  # Deliberately loose: only the `subnet-` prefix and a non-empty remainder are checked. AWS has
  # already lengthened resource IDs once (8 -> 17 characters) and the remainder is not restricted to
  # hex in every partition, so pinning a length or a hex charset would reject valid IDs. This rule
  # exists to catch the common paste error of a `vpc-` or `sg-` ID in a subnet field.
  validation {
    condition = alltrue([
      for t in var.subnet_selector_terms :
      t.id == null || can(regex("^subnet-[0-9a-z]+$", coalesce(t.id, "")))
    ])
    error_message = "Every subnet selector term `id` must look like `subnet-<identifier>`. A `vpc-` or `sg-` ID, a bare `subnet-`, or an empty string is not a subnet ID."
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Used for the two `securityGroupSelectorTerms` tag terms and for the default `karpenter.sh/discovery` tag, so it must match the cluster Karpenter is running against."
  type        = string

  # EKS cluster names are 1-100 characters, must start alphanumeric, and thereafter allow letters,
  # digits, hyphens and underscores.
  validation {
    condition     = can(regex("^[0-9A-Za-z][0-9A-Za-z_-]*$", var.cluster_name))
    error_message = "cluster_name must start with a letter or digit and contain only letters, digits, hyphens and underscores. An empty string or a leading hyphen is not a valid EKS cluster name."
  }

  # Length only. The regex above already requires at least one character, so keeping the two rules
  # disjoint means a given bad value trips exactly one of them -- `expect_failures` proves rejection
  # but not which rule fired, so overlapping rules would make the tests undiagnosable.
  validation {
    condition     = length(var.cluster_name) <= 100
    error_message = "cluster_name must be at most 100 characters; EKS rejects anything longer."
  }
}

variable "node_role_name" {
  description = "Name of the IAM role the launched nodes assume. This is the role NAME, not an ARN -- Karpenter's `spec.role` takes a name and resolves the instance profile itself."
  type        = string

  # IAM role names allow [\w+=,.@-]. An ARN contains ':' and '/', so passing one fails here rather
  # than at apply -- the single most likely mistake for this field.
  validation {
    condition     = can(regex("^[0-9A-Za-z_+=,.@-]+$", var.node_role_name))
    error_message = "node_role_name must be an IAM role NAME, not an ARN, and may contain only letters, digits and the characters _+=,.@-. Pass `example-cluster-Managed-Node-Role`, not `arn:aws:iam::123456789012:role/example-cluster-Managed-Node-Role`."
  }

  # Length only; the regex above already requires at least one character. See cluster_name.
  validation {
    condition     = length(var.node_role_name) <= 64
    error_message = "node_role_name must be at most 64 characters, the IAM role name limit."
  }
}

# ---------------------------------------------------------------------------------------------------
# Optional inputs
# ---------------------------------------------------------------------------------------------------

variable "name" {
  description = "`metadata.name` of the EC2NodeClass. Consumers reference it through the module's `name` output rather than repeating this value, so that Terraform orders them after the node class exists."
  type        = string
  default     = "al2023"

  # EC2NodeClass is cluster-scoped, so the name is an RFC 1123 DNS subdomain label: lowercase
  # alphanumerics and hyphens, starting and ending alphanumeric, at most 63 characters.
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "name must be a lowercase RFC 1123 label: letters, digits and hyphens only, starting and ending with a letter or digit. `AL2023`, `-al2023` and the empty string are all rejected by the API server."
  }

  validation {
    condition     = length(var.name) <= 63
    error_message = "name must be at most 63 characters, the Kubernetes limit for an RFC 1123 label."
  }
}

variable "ami_alias" {
  description = "`spec.amiSelectorTerms[0].alias`, of the form `family@version`. The alias IMPLIES `amiFamily`, which is why this module never emits `amiFamily`. Pinning `@latest` means every AMI release drifts and replaces every node in the pools using this class; pin a dated version in production."
  type        = string
  default     = "al2023@latest"

  # Alias families accepted by Karpenter v1. `ubuntu` is NOT among them -- Ubuntu must be selected
  # with an id/name/ssm term instead -- and the `@version` half is mandatory.
  validation {
    condition     = can(regex("^(al2|al2023|bottlerocket|windows2019|windows2022)@[0-9A-Za-z][0-9A-Za-z._-]*$", var.ami_alias))
    error_message = "ami_alias must be `family@version` where family is one of al2, al2023, bottlerocket, windows2019, windows2022 -- for example `al2023@latest` or `bottlerocket@v1.20.4`. A bare family with no `@version`, an empty version, or an unknown family such as `ubuntu@latest` is rejected."
  }
}

variable "boot_volume_size" {
  description = "`volumeSize` of the `/dev/xvda` gp3 root volume, as a Kubernetes quantity such as `50Gi`. Defaults to what deployed customer node classes actually run rather than to Chalk's internal 200Gi, because a customer-facing module should not silently quadruple an EBS bill."
  type        = string
  default     = "50Gi"

  validation {
    condition     = can(regex("^[1-9][0-9]*(\\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)$", var.boot_volume_size))
    error_message = "boot_volume_size must be a positive Kubernetes quantity WITH a unit suffix, for example `50Gi` or `1Ti`. A bare number such as `50` is read as bytes, and a negative or non-numeric value is rejected."
  }
}

variable "instance_store_policy" {
  description = "`spec.instanceStorePolicy`. `RAID0` stripes the instance's local NVMe disks and hands them to kubelet for ephemeral storage. Left null the field is not emitted, and instance stores are unused."
  type        = string
  default     = null

  # RAID0 is the only value Karpenter v1 accepts.
  #
  # Deliberately NOT `contains([...], coalesce(var.instance_store_policy, "__unset__"))`: coalesce
  # skips the empty string as well as null, so that form silently accepts "" and renders
  # `instanceStorePolicy: ""`. A plain null guard is safe here even though Terraform does not
  # reliably short-circuit `||`, because `null == "RAID0"` is false rather than an error.
  validation {
    condition     = var.instance_store_policy == null || var.instance_store_policy == "RAID0"
    error_message = "instance_store_policy must be exactly `RAID0`, or null to omit the field. The value is case-sensitive; `raid0`, `RAID1` and the empty string are all rejected."
  }
}

variable "tags" {
  description = "Additional tags applied to every EC2 instance this node class launches, merged over the module's default `karpenter.sh/discovery = cluster_name` tag. A caller-supplied key of the same name wins."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.tags : length(k) <= 128])
    error_message = "Every tag key must be at most 128 characters, the AWS limit."
  }

  validation {
    condition     = alltrue([for k, v in var.tags : length(v) <= 256])
    error_message = "Every tag value must be at most 256 characters, the AWS limit."
  }
}

variable "manifest_path" {
  description = "Path to the manifest template rendered with `templatefile()`. Null uses the template bundled with this module. Override it to render an exotic node class while keeping this module's validation, naming and output contract."
  type        = string
  default     = null

  # Checked here rather than being left to templatefile() so that a typo names the variable in the
  # error rather than surfacing as a bare filesystem message from deep in a local.
  #
  # A validation condition cannot reference path.module, so the bundled default is resolved in
  # locals instead and null simply passes. The inner coalesce is not a null guard -- Terraform does
  # not reliably short-circuit `||` -- but a placeholder that keeps fileexists() from ever being
  # handed "", which is an error rather than a false. An explicit "" is therefore rejected.
  validation {
    condition     = var.manifest_path == null || fileexists(coalesce(var.manifest_path, "./.this-path-never-exists"))
    error_message = "manifest_path must name a file that exists on disk at plan time, or be null to use the template bundled with this module."
  }
}
