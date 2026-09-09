# Inputs for one Karpenter v1 NodePool.
#
# Validation policy (RFC INF-2110 section 8.1): every rule below is ALSO enforced server-side by the
# Karpenter CRD. The module restates the cheap, stable, documented kubebuilder markers so a caller
# gets plan-time feedback instead of a mid-apply API rejection, and cites the marker beside each one
# so a future reader can re-sync against upstream rather than guess. Anything Karpenter might
# reasonably loosen later is deliberately left unvalidated and forwarded to the API server.
#
# Null policy: EVERY optional input defaults to null, including the collections. An empty list or map
# is indistinguishable from "the caller set nothing", and this module needs that distinction to
# reject inputs that YAML mode would otherwise ignore. The real template-mode defaults ([] and {})
# are resolved in locals. `name` and `ec2nodeclass_name` also default to null, and their
# "required in template mode" rule is a precondition in main.tf, because per-mode requiredness cannot
# be expressed on a variable and a `validation` block may only reference its own variable.

variable "name" {
  description = "metadata.name of the NodePool. A Kubernetes DNS-1123 label: lowercase alphanumerics and '-', starting and ending alphanumeric, at most 63 characters. Required in template mode; in YAML mode it OVERRIDES metadata.name in the supplied document, and null leaves the document's own name in place."
  type        = string
  default     = null

  validation {
    condition     = var.name == null ? true : (can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name)) && length(var.name) <= 63)
    error_message = "name must be a DNS-1123 label: 1-63 characters of lowercase alphanumerics or '-', starting and ending with an alphanumeric."
  }
}

variable "ec2nodeclass_name" {
  description = "metadata.name of the EC2NodeClass this pool schedules against, rendered into spec.template.spec.nodeClassRef.name. Accepts either a literal name or the `name` output of the ec2nodeclass module; passing the module output is what orders this pool after the node class exists. Required in template mode; in YAML mode it OVERRIDES nodeClassRef.name in the supplied document, and null leaves the document's own reference in place."
  type        = string
  default     = null

  validation {
    condition     = var.ec2nodeclass_name == null ? true : (can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.ec2nodeclass_name)) && length(var.ec2nodeclass_name) <= 63)
    error_message = "ec2nodeclass_name must be a DNS-1123 label: 1-63 characters of lowercase alphanumerics or '-', starting and ending with an alphanumeric."
  }
}

variable "lookup_ec2nodeclass" {
  description = "Read the referenced EC2NodeClass with a data source so a missing node class fails the plan instead of the apply. Set to false when the node class is created elsewhere in the same root module and therefore does not exist yet at plan time; the 2.x kubectl data source has no wait_for to absorb that. In YAML mode the name read is ec2nodeclass_name if set, otherwise the document's own nodeClassRef.name."
  type        = bool
  default     = true
}

variable "requirements" {
  description = "spec.template.spec.requirements, verbatim. Caller-supplied and free-form: this module hardcodes no requirement list. `values` must be empty for Exists/DoesNotExist and a single non-negative integer for Gt/Lt/Gte/Lte. Template mode only; null renders an empty list."
  type = list(object({
    key       = string
    operator  = string
    values    = optional(list(string), [])
    minValues = optional(number)
  }))
  default = null

  # nodeclaim.go: operator enum. Gte and Lte ARE valid in v1 -- do not trim this list to the four
  # set-based operators.
  validation {
    condition = alltrue([
      for r in(var.requirements == null ? [] : var.requirements) :
      contains(["In", "NotIn", "Exists", "DoesNotExist", "Gt", "Lt", "Gte", "Lte"], r.operator)
    ])
    error_message = "Each requirement operator must be one of: In, NotIn, Exists, DoesNotExist, Gt, Lt, Gte, Lte."
  }

  # nodepool.go: "requirements with operator 'In' must have a value defined".
  validation {
    condition     = alltrue([for r in(var.requirements == null ? [] : var.requirements) : r.operator != "In" || length(r.values) > 0])
    error_message = "A requirement with operator In must define at least one value."
  }

  # nodeclaim.go: Exists and DoesNotExist take no values at all.
  validation {
    condition = alltrue([
      for r in(var.requirements == null ? [] : var.requirements) :
      !contains(["Exists", "DoesNotExist"], r.operator) || length(r.values) == 0
    ])
    error_message = "A requirement with operator Exists or DoesNotExist must have an empty values list."
  }

  # nodeclaim.go: Gt/Lt/Gte/Lte take exactly one value, parsed as an integer. try() guards the index
  # because HCL's && does not short-circuit, so values[0] would otherwise error on an empty list
  # instead of failing the validation cleanly.
  validation {
    condition = alltrue([
      for r in(var.requirements == null ? [] : var.requirements) :
      !contains(["Gt", "Lt", "Gte", "Lte"], r.operator) ||
      (length(r.values) == 1 && can(regex("^[0-9]+$", try(r.values[0], ""))))
    ])
    error_message = "A requirement with operator Gt, Lt, Gte or Lte must have exactly one value that is a non-negative integer."
  }

  # nodepool.go: MaxItems=100. Note that labels also propagate as NodeClaim requirements and count
  # toward this same cap; that cross-variable check is a precondition in main.tf.
  validation {
    condition     = length(var.requirements == null ? [] : var.requirements) <= 100
    error_message = "requirements may contain at most 100 entries."
  }

  # nodeclaim.go: minValues must not exceed the number of values it selects from.
  validation {
    condition     = alltrue([for r in(var.requirements == null ? [] : var.requirements) : coalesce(r.minValues, 0) <= length(r.values)])
    error_message = "A requirement's minValues must not exceed the length of its values list."
  }

  # nodeclaim.go: Minimum=1, Maximum=50.
  validation {
    condition = alltrue([
      for r in(var.requirements == null ? [] : var.requirements) :
      coalesce(r.minValues, 1) >= 1 && coalesce(r.minValues, 1) <= 50
    ])
    error_message = "A requirement's minValues must be between 1 and 50."
  }
}

variable "limits" {
  description = "spec.limits, keyed by resource name. Arbitrary resource names are accepted -- cpu, memory, nvidia.com/gpu and nodes are all valid -- so this is a map rather than a fixed cpu/memory/gpu triple. Values are Kubernetes quantities, e.g. \"500\", \"1k\", \"5000Gi\". Template mode only; null emits no limits block."
  type        = map(string)
  default     = null

  validation {
    condition = alltrue([
      for k, v in(var.limits == null ? {} : var.limits) :
      can(regex("^([0-9]+(\\.[0-9]+)?|\\.[0-9]+)(([KMGTPE]i)|[numkKMGTPE]|([eE][-+]?[0-9]+))?$", v))
    ])
    error_message = "Each limits value must be a Kubernetes quantity, e.g. 500, 1k, 2.5, 5000Gi or 1e3."
  }
}

variable "taints" {
  description = "spec.template.spec.taints, verbatim. `value` is optional; `effect` comes from Kubernetes rather than Karpenter, since the CRD embeds corev1.Taint. Template mode only; null emits no taints."
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  default = null

  validation {
    condition = alltrue([
      for t in(var.taints == null ? [] : var.taints) : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)
    ])
    error_message = "Each taint effect must be one of: NoSchedule, PreferNoSchedule, NoExecute."
  }

  validation {
    condition     = alltrue([for t in(var.taints == null ? [] : var.taints) : length(t.key) > 0])
    error_message = "Each taint must set a non-empty key."
  }

  # nodepool.go: MaxItems=50.
  validation {
    condition     = length(var.taints == null ? [] : var.taints) <= 50
    error_message = "taints may contain at most 50 entries."
  }
}

variable "labels" {
  description = "spec.template.metadata.labels. These propagate onto every node as NodeClaim requirements and therefore count toward the same 100-entry cap as `requirements`. Template mode only; null emits no template.metadata block."
  type        = map(string)
  default     = null

  # Kubernetes label key: an optional DNS-subdomain prefix, '/', then a <=63 character name.
  validation {
    condition = alltrue([
      for k, v in(var.labels == null ? {} : var.labels) :
      can(regex("^(([a-z0-9]([-a-z0-9]*[a-z0-9])?\\.)*[a-z0-9]([-a-z0-9]*[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$", k))
      && length(element(split("/", k), length(split("/", k)) - 1)) <= 63
    ])
    error_message = "Each label key must be a valid Kubernetes label key: an optional DNS-subdomain prefix and '/', then a name of at most 63 alphanumeric, '-', '_' or '.' characters."
  }

  # Kubernetes label value: empty, or at most 63 characters starting and ending alphanumeric.
  validation {
    condition = alltrue([
      for k, v in(var.labels == null ? {} : var.labels) :
      v == "" || (length(v) <= 63 && can(regex("^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$", v)))
    ])
    error_message = "Each label value must be empty or at most 63 alphanumeric, '-', '_' or '.' characters starting and ending with an alphanumeric."
  }
}

variable "weight" {
  description = "spec.weight, the pool's scheduling preference relative to other pools. Bounded 1-100. Leave null to omit it, which Karpenter treats as 0; an explicit 0 is rejected by the CRD. Template mode only."
  type        = number
  default     = null

  # nodepool.go: Minimum=1, Maximum=100. coalesce rather than a `var.weight == null ||` guard,
  # because HCL's || evaluates both operands and `null >= 1` is an error rather than false.
  validation {
    condition     = coalesce(var.weight, 1) >= 1 && coalesce(var.weight, 1) <= 100
    error_message = "weight must be between 1 and 100. Omit it (null) rather than passing 0; the CRD rejects an explicit 0."
  }
}

variable "disruption" {
  description = "spec.disruption. Leave null to emit no disruption block at all: Karpenter defaults consolidationPolicy to WhenEmptyOrUnderutilized, consolidateAfter to 0s and budgets to a single {nodes: \"10%\"}, and restating those in the manifest writes server-supplied values into the caller's config. Template mode only."
  type = object({
    consolidationPolicy = optional(string)
    consolidateAfter    = optional(string)
    budgets = optional(list(object({
      nodes    = string
      schedule = optional(string)
      duration = optional(string)
      reasons  = optional(list(string))
    })))
  })
  default = null

  # nodepool.go: enum. WhenUnderutilized is the v1beta1 spelling and is NOT valid in v1.
  validation {
    condition = contains(
      ["WhenEmpty", "WhenEmptyOrUnderutilized", "Balanced"],
      try(coalesce(var.disruption.consolidationPolicy, "WhenEmpty"), "WhenEmpty")
    )
    error_message = "disruption.consolidationPolicy must be one of: WhenEmpty, WhenEmptyOrUnderutilized, Balanced. WhenUnderutilized is the v1beta1 value and is not valid in v1."
  }

  # nodepool.go: Pattern=^(([0-9]+(s|m|h))+|Never)$
  validation {
    condition = can(regex(
      "^(([0-9]+(s|m|h))+|Never)$",
      try(coalesce(var.disruption.consolidateAfter, "Never"), "Never")
    ))
    error_message = "disruption.consolidateAfter must be a duration built from s/m/h components, e.g. 0s, 1h, 1h30m, or the literal Never."
  }

  # nodepool.go: budgets MaxItems=50.
  validation {
    condition     = try(length(var.disruption.budgets) <= 50, true)
    error_message = "disruption.budgets may contain at most 50 entries."
  }

  # nodepool.go: Pattern=^((100|[0-9]{1,2})%|[0-9]+)$
  validation {
    condition = try(alltrue([
      for b in var.disruption.budgets : can(regex("^((100|[0-9]{1,2})%|[0-9]+)$", b.nodes))
    ]), true)
    error_message = "Each disruption budget's nodes must be a whole number or a percentage from 0% to 100%."
  }

  # nodepool.go: schedule and duration are meaningful only together.
  validation {
    condition = try(alltrue([
      for b in var.disruption.budgets : (b.schedule == null) == (b.duration == null)
    ]), true)
    error_message = "A disruption budget must set both schedule and duration, or neither."
  }

  # nodepool.go: the budget duration pattern accepts hours and minutes only -- seconds are rejected,
  # unlike consolidateAfter and expire_after.
  validation {
    condition = try(alltrue([
      for b in var.disruption.budgets : can(regex("^([0-9]+(h|m))+$", coalesce(b.duration, "1h")))
    ]), true)
    error_message = "A disruption budget's duration accepts hours and minutes only, e.g. 10h, 30m, 10h5m. Seconds are not accepted."
  }

  # nodepool.go: reasons enum.
  validation {
    condition = try(alltrue(flatten([
      for b in var.disruption.budgets : [
        for reason in coalesce(b.reasons, []) : contains(["Underutilized", "Empty", "Drifted"], reason)
      ]
    ])), true)
    error_message = "Each disruption budget reason must be one of: Underutilized, Empty, Drifted."
  }
}

variable "expire_after" {
  description = "spec.template.spec.expireAfter, the maximum node lifetime before Karpenter replaces it. Leave null to emit nothing and inherit the Karpenter default of 720h. Accepts s/m/h components or the literal Never. Template mode only."
  type        = string
  default     = null

  # nodepool.go: Pattern=^(([0-9]+(s|m|h))+|Never)$
  validation {
    condition     = can(regex("^(([0-9]+(s|m|h))+|Never)$", coalesce(var.expire_after, "Never")))
    error_message = "expire_after must be a duration built from s/m/h components, e.g. 720h, 1h30m, 720h0m0s, or the literal Never."
  }
}

variable "termination_grace_period" {
  description = "spec.template.spec.terminationGracePeriod, the bound on draining. It has no Karpenter default: left unset, a misconfigured PDB or a karpenter.sh/do-not-disrupt pod can block draining indefinitely. Unlike expire_after this does NOT accept Never. Template mode only."
  type        = string
  default     = null

  # nodepool.go: Pattern=^([0-9]+(s|m|h))+$ -- note the missing |Never alternative, which is the one
  # asymmetry between this field and expireAfter.
  validation {
    condition     = can(regex("^([0-9]+(s|m|h))+$", coalesce(var.termination_grace_period, "1s")))
    error_message = "termination_grace_period must be a duration built from s/m/h components, e.g. 1s, 30m, 2h. Never is valid for expire_after but not here."
  }
}

variable "manifest_path" {
  description = "Path to a replacement NodePool TEMPLATE. Leave null to use the template bundled with this module. The path is resolved relative to the process working directory, not the module directory. Mutually exclusive with manifest_yaml, which supplies a finished document rather than a template."
  type        = string
  default     = null

  validation {
    condition     = var.manifest_path == null ? true : fileexists(var.manifest_path)
    error_message = "manifest_path must point at a file that exists."
  }
}

variable "manifest_yaml" {
  description = "A finished Karpenter v1 NodePool document, as YAML. Setting it selects YAML mode: the module emits the caller's document with only metadata.name and spec.template.spec.nodeClassRef.name overridden, and rejects every input it would otherwise ignore. There is no companion path variable -- pass file(\"$${path.root}/nodepool.yaml\") if the document lives on disk. Mutually exclusive with manifest_path."
  type        = string
  default     = null

  # The five structural rules below get a message each, and each is guarded so that only the most
  # specific applicable one fires: a document that fails to parse reports only that, and is not also
  # accused of missing a kind. Every condition is total -- can()/try() throughout -- because HCL's
  # || evaluates both operands.
  validation {
    condition     = var.manifest_yaml == null ? true : can(yamldecode(var.manifest_yaml))
    error_message = "manifest_yaml must be parseable YAML. An empty string is not a YAML document; pass null to use template mode instead."
  }

  validation {
    condition     = (var.manifest_yaml == null || !can(yamldecode(var.manifest_yaml))) ? true : can(keys(yamldecode(var.manifest_yaml)))
    error_message = "manifest_yaml must decode to a mapping -- one YAML document whose top level is key/value pairs. A scalar or a sequence (a top-level list, e.g. a multi-document file collapsed into one) is not a NodePool."
  }

  validation {
    condition     = (var.manifest_yaml == null || !can(keys(yamldecode(var.manifest_yaml)))) ? true : try(yamldecode(var.manifest_yaml).kind, null) == "NodePool"
    error_message = "manifest_yaml must set kind: NodePool. This module applies exactly one NodePool; an EC2NodeClass belongs to the ec2nodeclass module."
  }

  validation {
    condition     = (var.manifest_yaml == null || !can(keys(yamldecode(var.manifest_yaml)))) ? true : try(yamldecode(var.manifest_yaml).apiVersion, null) != null
    error_message = "manifest_yaml must set apiVersion. For Karpenter v1 that is apiVersion: karpenter.sh/v1."
  }

  # Called out separately from "apiVersion absent" because it is the likely paste: a NodePool copied
  # from a pre-v1 cluster or from v1beta1-era documentation. The check is deliberately narrow -- an
  # unrecognised group is forwarded to the API server rather than rejected here, in line with the
  # module's policy of not second-guessing what Karpenter may add later.
  validation {
    condition     = var.manifest_yaml == null ? true : !can(regex("(^|/)v1beta1$", try(yamldecode(var.manifest_yaml).apiVersion, "")))
    error_message = "manifest_yaml carries a v1beta1 apiVersion. This module applies karpenter.sh/v1 only. v1beta1 is not merely a rename: nodeClassRef takes group/kind/name instead of apiVersion/kind/name, consolidationPolicy WhenUnderutilized became WhenEmptyOrUnderutilized, and kubelet configuration moved to the EC2NodeClass. Convert the document before passing it."
  }

  validation {
    condition     = (var.manifest_yaml == null || !can(keys(yamldecode(var.manifest_yaml)))) ? true : try(yamldecode(var.manifest_yaml).spec, null) != null
    error_message = "manifest_yaml must set spec. A NodePool with no spec has no nodeClassRef and no requirements, and the API server rejects it."
  }
}
