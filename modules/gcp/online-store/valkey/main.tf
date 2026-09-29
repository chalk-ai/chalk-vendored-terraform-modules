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
  secret_id                    = "${var.instance_id}-redis-uri"
  service_connection_policy_id = "${var.instance_id}-valkey-scp"

  # `network` may arrive as a bare name, a resource path, or a full self-link. Normalise to the
  # `projects/<project>/global/networks/<name>` form the Memorystore endpoint argument wants.
  network_path = replace(var.network, "https://www.googleapis.com/compute/v1/", "")
  network_id = startswith(local.network_path, "projects/") ? local.network_path : (
    "projects/${var.project_id}/global/networks/${var.network}"
  )

  # The PSC forwarding rule is created in the project that owns the network, which is not
  # `project_id` under Shared VPC. Parse it back out rather than adding an input for it.
  network_project = try(
    regex("^projects/([^/]+)/global/networks/[^/]+$", local.network_id)[0],
    var.project_id
  )

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

  # An online feature store is a cache of derived values: evicting the coldest key is correct,
  # and refusing writes when full is not.
  engine_configs = {
    "maxmemory-policy" = "allkeys-lru"
  }

  # Backups. Rendering the automated_backup_config block IS the enablement -- the provider derives
  # automatedBackupMode from the block's presence and always transmits the field, so removing this
  # block does not leave an existing instance alone, it sends DISABLED and turns backups off.
  #
  # 30 days, inside the documented 1-365 day range and below the provider's own 35-day default.
  # 09:00 UTC keeps the backup away from the Sunday 00:00 UTC maintenance window; the
  # TWENTY_FOUR_HOURS RDB period gives no start-time control, so hour-of-day is the only
  # separation available.
  backup_retention_seconds = "2592000s"
  backup_start_hour_utc    = 9
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
      rdb_snapshot_period = "TWENTY_FOUR_HOURS"
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
        hours = 0
      }
    }
  }

  # A Memorystore instance cannot be created until a service connection policy exists for its
  # (project, network, region, service class). When the module owns that policy, order the two.
  depends_on = [google_network_connectivity_service_connection_policy.valkey]
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

  # Guard the endpoint lists rather than indexing blind: a multi-VPC instance carries several
  # endpoints, and the lists are empty until the instance exists.
  psc_auto_connections = flatten([
    for endpoint in google_memorystore_instance.valkey.endpoints : [
      for connection in endpoint.connections : connection.psc_auto_connection
    ]
  ])

  endpoint_host = length(local.psc_auto_connections) > 0 ? local.psc_auto_connections[0].ip_address : ""
  endpoint_port = length(local.psc_auto_connections) > 0 ? local.psc_auto_connections[0].port : 0

  # The `/0` database path is emitted explicitly. The Rust client defaults an empty path to /0,
  # but relying on that default is a needless dependency on one implementation's behaviour.
  redis_uri = "${local.uri_scheme}://${local.endpoint_host}:${local.endpoint_port}/0?clustered=${local.uri_clustered}${local.uri_fragment}"
}

resource "google_secret_manager_secret" "redis_uri" {
  project   = var.project_id
  secret_id = local.secret_id
  labels    = local.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "redis_uri" {
  secret      = google_secret_manager_secret.redis_uri.id
  secret_data = local.redis_uri
}
