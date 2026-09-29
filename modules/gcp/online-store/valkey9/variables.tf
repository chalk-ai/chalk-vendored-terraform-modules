# ---------------------------------------------------------------------------------------------
# Required: identity and placement
# ---------------------------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project that will hold the Memorystore instance and the connection-URI secret."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  description = "GCP region for the instance, for example \"us-central1\". Memorystore for Valkey is regional; the instance and its service connection policy must share this region."
  type        = string

  validation {
    condition     = length(trimspace(var.region)) > 0
    error_message = "region must not be empty."
  }
}

variable "network" {
  description = <<-EOT
    VPC network the instance's automatically created Private Service Connect endpoint attaches to.

    Accepts any of:
      * a bare network name, resolved inside `project_id` -- for example "example-vpc"
      * a `projects/<project>/global/networks/<name>` path
      * a self-link in either spelling GCP emits, with or without a trailing slash:
        `https://www.googleapis.com/compute/v1/projects/<project>/global/networks/<name>` or
        `https://compute.googleapis.com/compute/v1/projects/<project>/global/networks/<name>`

    Use a path or a self-link for Shared VPC, where the network lives in a host project separate
    from `project_id`.
  EOT
  type        = string

  validation {
    condition     = length(trimspace(var.network)) > 0
    error_message = "network must not be empty."
  }
}

variable "instance_id" {
  description = "Instance ID for the Memorystore instance. Immutable: changing it replaces the instance and discards the cache. Also used to derive the name of the connection-URI secret."
  type        = string

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.instance_id))
    error_message = "instance_id must start with a lowercase letter, contain only lowercase letters, digits and hyphens, not end with a hyphen, and be at most 63 characters."
  }
}

# ---------------------------------------------------------------------------------------------
# Optional: sizing
# ---------------------------------------------------------------------------------------------

variable "shard_count" {
  description = "Number of shards. Usable capacity is shard_count x node_type; `maxmemory` is deliberately left unset so Memorystore's own per-node default applies. Note that the Valkey engine is single-threaded per shard, so a larger node_type raises capacity but not the per-shard write ceiling -- scale out, not just up."
  type        = number
  default     = 3

  validation {
    condition     = var.shard_count >= 1 && floor(var.shard_count) == var.shard_count
    error_message = "shard_count must be a whole number of at least 1."
  }
}

variable "replica_count" {
  description = "Number of replica nodes per shard. Memorystore accepts 0-5; this module requires at least 1 (see the validation message for why)."
  type        = number
  default     = 1

  validation {
    condition     = var.replica_count >= 1 && var.replica_count <= 5 && floor(var.replica_count) == var.replica_count
    error_message = "replica_count must be a whole number between 1 and 5. Memorystore itself accepts 0, but this module rejects it on purpose: the instance is created with MULTI_ZONE distribution, and with no replica there is no second copy to place in another zone -- so the zone spread buys nothing, and a shard whose only node fails loses its slot range outright. If you genuinely want a single-copy online store, fork the module."
  }
}

variable "node_type" {
  description = "Machine type for individual nodes. Only the seven types Memorystore offers for Cluster Mode Enabled instances are accepted; the three CUSTOM_* types are Cluster-Mode-Disabled-only and this module always builds a cluster. SHARED_CORE_NANO has no SLA and is for development and testing only -- see the README."
  type        = string
  default     = "STANDARD_SMALL"

  validation {
    condition = contains([
      "SHARED_CORE_NANO",
      "STANDARD_SMALL",
      "HIGHMEM_MEDIUM",
      "HIGHCPU_MEDIUM",
      "STANDARD_LARGE",
      "HIGHMEM_XLARGE",
      "HIGHMEM_2XLARGE",
    ], var.node_type)
    error_message = "node_type must be one of: SHARED_CORE_NANO, STANDARD_SMALL, HIGHMEM_MEDIUM, HIGHCPU_MEDIUM, STANDARD_LARGE, HIGHMEM_XLARGE, HIGHMEM_2XLARGE. Values are uppercase. CUSTOM_PICO, CUSTOM_MICRO and CUSTOM_MINI exist in the provider enum but Memorystore offers them for Cluster Mode Disabled instances ONLY -- this module always builds a CLUSTER, so those three pass plan and then fail at apply. Google's Cluster-Mode-Enabled capacity table lists the seven above and no others."
  }
}

variable "engine_version" {
  description = "Valkey engine version. Memorystore allows this to change IN PLACE, which is why the module path carries a version suffix: a future engine default ships as a new module path rather than silently upgrading an existing instance on its next apply. The provider enforces no enum, so a typo would otherwise fail at apply rather than at plan. Downgrades are not guarded by this module -- see the README."
  type        = string
  default     = "VALKEY_9_1"

  validation {
    condition     = contains(["VALKEY_7_2", "VALKEY_8_0", "VALKEY_9_0", "VALKEY_9_1"], var.engine_version)
    error_message = "engine_version must be one of: VALKEY_7_2, VALKEY_8_0, VALKEY_9_0, VALKEY_9_1."
  }
}

# ---------------------------------------------------------------------------------------------
# Optional: lifecycle and metadata
# ---------------------------------------------------------------------------------------------

variable "deletion_protection_enabled" {
  description = "Refuse to delete the instance. Defaults to true, which is the opposite of the Memorystore API default: a `terraform destroy` run against a misread plan would otherwise empty the online feature store. Set this to false and apply that change BEFORE attempting to destroy the instance."
  type        = bool
  default     = true
}

variable "kms_key" {
  description = <<-EOT
    Cloud KMS CryptoKey that encrypts the instance's at-rest data -- backups, RDB persistence
    files and the metadata behind the security features. Leave this null, the default, for
    Google-managed encryption, which is what most projects want.

    Give the full CryptoKey resource ID:
    `projects/<project>/locations/<region>/keyRings/<key-ring>/cryptoKeys/<key>`

    The key's `locations/` segment must equal `region`. Google requires the key ring, the key and
    the instance to share a location and rejects the create request when they differ; a `global`
    key ring is therefore never usable here, because it can never equal a Memorystore region.

    The key's PROJECT deliberately is not checked. A central KMS project separate from the
    instance's project is a normal arrangement, and which key projects are permitted is governed
    by `constraints/gcp.restrictCmekCryptoKeyProjects` -- your policy, not this module's.

    Create-only. CMEK can be enabled only on a NEW instance, and the provider marks the attribute
    ForceNew, so adding, removing or repointing it REPLACES the instance and discards the cache.

    Mandatory in some organizations: when the Memorystore for Valkey API appears on the deny list
    of `constraints/gcp.restrictNonCmekServices`, non-CMEK instances cannot be created at all.
    See the README, "Customer-managed encryption keys".
  EOT
  type        = string
  default     = null

  # Shape only. The region comparison needs `var.region` as well, and cross-variable references
  # in a `validation` block require Terraform >= 1.9 (they "could refer only to the variable being
  # validated" before that). This module's floor is >= 1.3, so that check lives in a
  # `lifecycle.precondition` on the instance instead -- the same split already used for the
  # service connection policy subnets.
  validation {
    condition     = var.kms_key == null || can(regex("^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$", var.kms_key))
    error_message = "kms_key must be a full Cloud KMS CryptoKey resource ID of the form projects/<project>/locations/<location>/keyRings/<key-ring>/cryptoKeys/<key>, or null for Google-managed encryption. A key ring name, a bare key name or a key VERSION path will not do."
  }
}

variable "labels" {
  description = "Additional labels applied to the instance, the secret and (when created) the service connection policy. These are merged with the labels the module always sets rather than replacing them; the module's own labels win on a key collision."
  type        = map(string)
  default     = {}
}

variable "strict_location" {
  description = <<-EOT
    Confine everything this module creates to `region`.

    Exactly one resource is affected, because everything else is already regional by
    construction: the connection-URI secret. Secret Manager replicates a secret to EVERY region by
    default, which makes it the only thing here that leaves the region boundary.

    false -- the default -- gives the secret automatic replication, which is what most projects
    want.

    true creates the secret with a single user-managed replica in `region` instead. Set it when
    the organization enforces `constraints/gcp.resourceLocations`, which rejects an automatically
    replicated secret outright, or when a data-residency obligation requires it.

    The replica location is `region` by construction; there is no separate input for it, so the
    two cannot disagree.

    Immutable: Secret Manager does not allow a secret's replication policy to change after
    creation, so flipping this value replaces the secret.

    This does NOT change zone distribution. The instance stays MULTI_ZONE, which spreads nodes
    across zones WITHIN `region` -- that satisfies a regional residency requirement and keeps
    in-region high availability. Single-region and single-zone are different requirements.
  EOT
  type        = bool
  default     = false
}

variable "create_service_connection_policy" {
  description = <<-EOT
    Create the Private Service Connect service connection policy this instance needs.

    PSC service connectivity automation is the only way to reach a Memorystore for Valkey
    instance, and exactly one policy may exist per (project, network, region, service class)
    combination. Leave this false -- the default -- when a policy already exists for that
    combination, which is the usual case when several instances share a VPC. Set it to true, on
    exactly one module instance per combination, to have the module create it.
  EOT
  type        = bool
  default     = false
}

variable "service_connection_policy_subnets" {
  description = "Subnetwork IDs or self-links that Private Service Connect draws endpoint IP addresses from. Required when create_service_connection_policy is true, ignored otherwise. Do not include proxy-only subnets."
  type        = list(string)
  default     = []
}
