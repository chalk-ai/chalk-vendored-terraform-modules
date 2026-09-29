/**
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Derived from terraform-google-modules/terraform-google-memorystore (modules/valkey),
 * Apache-2.0. Substantially modified by Chalk -- see versions.tf and the README.
 */

# ---------------------------------------------------------------------------------------------
# Naming and network normalisation
# ---------------------------------------------------------------------------------------------

locals {
  secret_id = "${var.instance_id}-redis-uri"

  # `network` may arrive as a bare name, a resource path, or a full self-link. Normalise to the
  # `projects/<project>/global/networks/<name>` form the Memorystore endpoint argument wants.
  #
  # Both self-link spellings GCP emits are accepted -- `www.googleapis.com/compute/v1/...` and
  # `compute.googleapis.com/compute/v1/...` -- along with any API version and a trailing slash,
  # because all of those are things `gcloud`, the console and other providers hand you. Matching
  # only one literal prefix silently produced a malformed network id for the others.
  network_path = replace(
    trimsuffix(trimspace(var.network), "/"),
    "/^https?://[^/]+/compute/[^/]+//",
    "",
  )
  network_id = startswith(local.network_path, "projects/") ? local.network_path : (
    "projects/${var.project_id}/global/networks/${local.network_path}"
  )

  # The PSC forwarding rule is created in the project that owns the network, which is not
  # `project_id` under Shared VPC. Parse it back out rather than adding an input for it.
  network_project = try(
    regex("^projects/([^/]+)/global/networks/[^/]+$", local.network_id)[0],
    var.project_id
  )

  # Bare network name, whatever spelling arrived. Used to name the service connection policy.
  network_name = regex("[^/]+$", local.network_id)

  # The service connection policy is a SINGLETON per (project, network, region, service class) --
  # every Memorystore instance in the VPC shares the one policy. Naming it after `instance_id`
  # therefore named a shared resource after whichever instance happened to create it, which reads
  # as ownership that does not exist. Name it after its actual scope instead: the project is the
  # resource's own project and the region is its `location`, so network plus service class is what
  # remains to disambiguate.
  service_connection_policy_id = "${local.network_name}-${var.region}-memorystore"

  # Module-owned labels. Merged under the caller's so that a caller supplying `labels` adds to
  # them rather than replacing them, and so the identifying pair always survives.
  labels = merge(var.labels, {
    managed-by = "chalk-vendored-terraform-modules"
    component  = "chalk-online-store"
  })
}

# ---------------------------------------------------------------------------------------------
# Chalk's fixed configuration
#
# These are deliberately module constants rather than inputs. Each one is either something Chalk
# cannot consume the alternative of, or something the Memorystore API treats as create-only, so
# exposing it would only let a caller build an instance Chalk cannot use or cannot change later.
# ---------------------------------------------------------------------------------------------

locals {
  # Immutable in the API. CLUSTER is what Chalk's clients expect, and it is what makes the
  # `clustered=true` flag on the published URI true.
  instance_mode = "CLUSTER"

  # Immutable in the API. IAM_AUTH is the only alternative the GA provider offers, and no Chalk
  # client implements GCP IAM auth, so an IAM_AUTH instance would publish a URI nothing can
  # consume. (TOKEN_AUTH exists but is google-beta only.) With authorization disabled, network
  # reachability IS the authorization boundary -- the PSC policy and your firewall are the
  # security control.
  authorization_mode = "AUTH_DISABLED"

  # Immutable in the API, and GCP offers no "accept either" mode, so this is a birth choice.
  # SERVER_AUTHENTICATION means clients must speak TLS.
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  # Create-only (ForceNew): moving an existing instance to a different CA mode REPLACES it and
  # loses the cache. The per-instance default mints a unique private CA per instance, which is
  # precisely what makes certificate verification impractical. The shared CA is one downloadable
  # bundle per region, so choosing it now is the only way to leave verification reachable later
  # without a fleet-wide rebuild. It costs nothing today. See README, "Certificate authority".
  server_ca_mode = "GOOGLE_MANAGED_SHARED_CA"

  # Eviction policy. Fixed deliberately, and a correctness requirement rather than a preference --
  # which is why it is not an input. This is also Memorystore's own default.
  #
  # The online store holds internal mapping keys written with NO expiry, which the engine needs in
  # order to interpret every other key. `volatile-lru` reclaims only from keys that carry an
  # expiry, so the mapping keys are never eviction candidates. Under a policy that can discard
  # keys regardless of expiry, memory pressure can take the mapping with it, and the store is then
  # unreadable rather than merely cold.
  #
  # The accepted consequence: on a full instance with no expiring keys left to reclaim, writes are
  # refused with an out-of-memory error rather than discarding something that must be kept. That
  # makes sizing load-bearing, since `maxmemory` is left unset. See README, "Eviction policy".
  engine_configs = {
    "maxmemory-policy" = "volatile-lru"
  }

  # Backups. Rendering the automated_backup_config block IS the enablement -- the provider derives
  # automatedBackupMode from the block's presence and always transmits the field, so removing this
  # block does not leave an existing instance alone, it sends DISABLED and turns backups off.
  #
  # 30 days, inside the documented 1-365 day range and below the provider's own 35-day default.
  backup_retention_seconds = "2592000s"
  backup_start_hour_utc    = 9

  # The RDB snapshot anchor. `rdb_snapshot_start_time` is the timestamp "the first snapshot
  # was/will be attempted, and to which future snapshots will be aligned", so with a
  # TWENTY_FOUR_HOURS period it fixes the daily snapshot at this time of day. Leaving it unset
  # does NOT mean "no control" -- it means the API substitutes the moment of creation, so the
  # snapshot lands at whatever time of day the instance happened to be built.
  #
  # 16:45 UTC is the midpoint of the widest gap between the two other scheduled activities on the
  # instance: the 09:00 UTC backup and the SUNDAY 00:30 UTC maintenance window. That is 7h45m of
  # clearance from each.
  #
  # The date component must be a CONSTANT. It is deliberately in the past -- an anchor, not a
  # schedule -- because a `timestamp()` call would re-evaluate on every plan and produce
  # perpetual drift on a field that is Optional+Computed. RFC 3339, UTC, per the provider's own
  # documented examples.
  rdb_snapshot_start_time = "2025-01-01T16:45:00Z"
}

# ---------------------------------------------------------------------------------------------
# Service connection policy (optional)
# ---------------------------------------------------------------------------------------------

resource "google_network_connectivity_service_connection_policy" "valkey" {
  count = var.create_service_connection_policy ? 1 : 0

  project       = local.network_project
  name          = local.service_connection_policy_id
  location      = var.region
  service_class = "gcp-memorystore"
  description   = "Private Service Connect policy for Chalk online-store Valkey instances"
  network       = local.network_id
  labels        = local.labels

  psc_config {
    subnetworks = var.service_connection_policy_subnets
  }

  lifecycle {
    precondition {
      condition     = length(var.service_connection_policy_subnets) > 0
      error_message = "service_connection_policy_subnets must list at least one subnetwork when create_service_connection_policy is true. Private Service Connect draws the instance's endpoint IP addresses from these subnets."
    }

    # The name is derived from the network name and the region, either of which can be long.
    # Catch an over-long name at plan time rather than as an opaque API rejection at apply.
    precondition {
      condition     = length(local.service_connection_policy_id) <= 63
      error_message = "The derived service connection policy name (<network>-<region>-memorystore) exceeds the 63-character limit GCP allows. Either shorten the network name, or create the policy outside this module and leave create_service_connection_policy at false."
    }
  }
}

# ---------------------------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------------------------

resource "google_memorystore_instance" "valkey" {
  project     = var.project_id
  instance_id = var.instance_id
  location    = var.region

  shard_count    = var.shard_count
  replica_count  = var.replica_count
  node_type      = var.node_type
  engine_version = var.engine_version

  mode                    = local.instance_mode
  authorization_mode      = local.authorization_mode
  transit_encryption_mode = local.transit_encryption_mode
  server_ca_mode          = local.server_ca_mode

  engine_configs = local.engine_configs
  labels         = local.labels

  deletion_protection_enabled = var.deletion_protection_enabled

  # Optional CMEK. Null omits the attribute entirely -- it is Optional and, unusually, NOT
  # Computed on this resource, so a null leaves Google-managed encryption in place with no diff.
  kms_key = var.kms_key

  desired_auto_created_endpoints {
    network    = local.network_id
    project_id = local.network_project
  }

  # Create-only (ForceNew) in the provider even though the documentation does not say so:
  # changing zone distribution replaces the instance.
  zone_distribution_config {
    mode = "MULTI_ZONE"
  }

  # RDB snapshots protect against instance-level data loss within the instance's own lifetime.
  # They are NOT backups: they die with the instance. See automated_backup_config below.
  persistence_config {
    mode = "RDB"
    rdb_config {
      rdb_snapshot_period     = "TWENTY_FOUR_HOURS"
      rdb_snapshot_start_time = local.rdb_snapshot_start_time
    }
  }

  # Backups outlive deletion of the instance for the retention period, and must then be deleted
  # by hand if you want them gone.
  automated_backup_config {
    retention = local.backup_retention_seconds
    fixed_frequency_schedule {
      start_time {
        hours = local.backup_start_hour_utc
      }
    }
  }

  maintenance_policy {
    weekly_maintenance_window {
      day = "SUNDAY"
      start_time {
        hours   = 0
        minutes = 30
      }
    }
  }

  # A Memorystore instance cannot be created until a service connection policy exists for its
  # (project, network, region, service class). When the module owns that policy, order the two.
  depends_on = [google_network_connectivity_service_connection_policy.valkey]

  lifecycle {
    # Google requires the CryptoKey's key ring, the key and the instance to share a location, and
    # fails the create request when they differ -- on an attribute that is ForceNew and cannot be
    # corrected in place afterwards. Compare the key's `locations/` segment to `region` here.
    #
    # This belongs in a precondition rather than in the variable's own `validation` block: it
    # needs `var.region` as well as `var.kms_key`, and cross-variable validation conditions
    # require Terraform >= 1.9 while this module's floor is >= 1.3. Shape validation stays on the
    # variable, where it reports against the input the caller actually typed.
    #
    # A `global` key ring fails this check by construction, which is correct: `global` is never a
    # Memorystore instance location.
    precondition {
      condition = var.kms_key == null || try(
        regex("^projects/[^/]+/locations/([^/]+)/keyRings/", var.kms_key)[0], null
      ) == var.region
      error_message = "kms_key must live in the same location as the instance. Google requires the key ring, the key and the instance to share a region and rejects the create request otherwise, and kms_key is create-only, so this cannot be corrected after the fact. Create a key ring in `region` and use a key from it. Note that a `global` key ring can never satisfy this."
    }
  }
}

# ---------------------------------------------------------------------------------------------
# Published connection URI
#
# Derived from the settings above rather than hardcoded, so that if a future version of this
# module ever exposes the transit-encryption or cluster-mode axis, the URI follows automatically
# instead of silently lying about what the instance accepts.
# ---------------------------------------------------------------------------------------------

locals {
  # The scheme decides whether the client uses TLS at all.
  uri_scheme = local.transit_encryption_mode == "SERVER_AUTHENTICATION" ? "rediss" : "redis"

  # Mandatory. All three Chalk URI parsers -- Go, Python and Rust -- require this flag, and the
  # Go and Rust paths raise a hard error when it is absent.
  uri_clustered = local.instance_mode == "CLUSTER" ? "true" : "false"

  # LOAD-BEARING. `#insecure` is not a leftover debug flag: it is the difference between TLS with
  # certificate verification and TLS without, and Chalk cannot do the former here. Memorystore
  # presents a certificate from a Google-managed PRIVATE CA that is in no public trust store, and
  # Chalk has no CA-bundle path for its redis clients -- the only root-certificate setting in the
  # platform is gRPC-only. Dropping this fragment does not harden anything; it breaks every
  # connection on first connect. Flip this constant only together with that engine-side work.
  # See README, "Encrypted in transit, unverified certificate".
  tls_verification_supported = false
  uri_fragment               = local.tls_verification_supported ? "" : "#insecure"

  # A CLUSTER-mode instance publishes SEVERAL PSC connections: a discovery endpoint, a primary
  # (data) endpoint, and with replicas a reader endpoint. They are separate elements of
  # `endpoints[].connections` -- the provider declares `endpoints` and `connections` as unbounded
  # TypeLists and the `psc_auto_connection` inside each connection as MaxItems:1, so the index
  # that matters is the one over `connections`, and `psc_auto_connection[0]` is inert.
  #
  # Only the discovery endpoint is a client entry point. Google documents the primary endpoint as
  # one clients must not connect to directly, and the provider's own deprecation note on
  # `discovery_endpoints` sends callers to `connectionType == CONNECTION_TYPE_DISCOVERY`.
  #
  # Position is UNCONTRACTED: neither the REST reference nor the provider schema states an order
  # for these connections. Selecting by index relies on something nobody promised, which is
  # reason enough not to do it. Select on the type.
  instance_connections = flatten([
    for endpoint in google_memorystore_instance.valkey.endpoints : endpoint.connections
  ])

  discovery_connections = [
    for connection in local.instance_connections : connection.psc_auto_connection[0]
    if try(connection.psc_auto_connection[0].connection_type, null) == "CONNECTION_TYPE_DISCOVERY"
  ]

  # Exactly one is expected: this module configures exactly one auto-created endpoint, on one
  # network. Zero and more-than-one are both refused by the preconditions below rather than
  # resolved with an index, which would only move the same guess up one level.
  #
  # The fallbacks here exist because these locals are evaluated during plan, when the lists are
  # still empty. They are not a tolerated outcome.
  endpoint_host = length(local.discovery_connections) == 1 ? local.discovery_connections[0].ip_address : ""
  endpoint_port = length(local.discovery_connections) == 1 ? local.discovery_connections[0].port : 0

  # The `/0` database path is emitted explicitly. The Rust client defaults an empty path to /0,
  # but relying on that default is a needless dependency on one implementation's behaviour.
  redis_uri = "${local.uri_scheme}://${local.endpoint_host}:${local.endpoint_port}/0?clustered=${local.uri_clustered}${local.uri_fragment}"
}

resource "google_secret_manager_secret" "redis_uri" {
  project   = var.project_id
  secret_id = local.secret_id
  labels    = local.labels

  # Automatic replication is what almost every project wants, and it is the default here.
  #
  # It is, however, REJECTED outright under `constraints/gcp.resourceLocations`: an organization
  # that restricts resource locations cannot hold an automatically replicated secret, because
  # "automatic" means "every region". Such an organization must pin the secret to a permitted
  # region instead. Setting `secret_replication_location` switches to that form.
  dynamic "replication" {
    for_each = var.secret_replication_location == null ? [1] : []
    content {
      auto {}
    }
  }

  dynamic "replication" {
    for_each = var.secret_replication_location == null ? [] : [1]
    content {
      user_managed {
        replicas {
          location = var.secret_replication_location
        }
      }
    }
  }
}

resource "google_secret_manager_secret_version" "redis_uri" {
  secret      = google_secret_manager_secret.redis_uri.id
  secret_data = local.redis_uri

  lifecycle {
    # Refuse to publish a URI that has no endpoint in it.
    #
    # Without these, an instance that exposes no discovery connection publishes
    # `rediss://:0/0?clustered=true#insecure` -- which is WORSE than an index error, because
    # Chalk's own ValidateRedisURI accepts it (it only insists on `clustered`). The failure then
    # surfaces days later as an unexplained connect error against a store nobody suspects, with
    # nothing in the Terraform history to point at.
    precondition {
      condition     = length(local.discovery_connections) > 0
      error_message = "The Memorystore instance exposes no Private Service Connect connection of type CONNECTION_TYPE_DISCOVERY, so there is no endpoint to publish. This normally means the service connection policy for this (project, network, region, gcp-memorystore) combination is missing or has no free addresses in its subnets -- see the README, \"Prerequisites\"."
    }

    # More than one is not resolved by taking an index; that is the same guess one level up.
    precondition {
      condition     = length(local.discovery_connections) < 2
      error_message = "The Memorystore instance exposes more than one CONNECTION_TYPE_DISCOVERY connection, so there is no single endpoint to publish. This module configures exactly one auto-created endpoint, so this means endpoints were attached out of band. Decide which network Chalk should reach the store on and publish that URI yourself."
    }

    # `port` is part of a mutually exclusive group in the Memorystore REST schema, so a response
    # can legitimately omit it -- and the provider's flattener renders a missing port as 0 rather
    # than as an error.
    precondition {
      condition     = local.endpoint_host != "" && local.endpoint_port != 0
      error_message = "Refusing to publish a connection URI with an empty host or a zero port. A malformed URI of this shape still passes Chalk's URI validation, so it would be accepted by the dashboard and then fail at connect time with no indication of the cause."
    }
  }
}
