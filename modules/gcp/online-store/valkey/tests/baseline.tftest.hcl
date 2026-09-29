# Characterization tests for the GCP Memorystore for Valkey online-store module.
#
# These pin the behaviour a customer depends on: the defaults, the settings the module fixes and
# does not expose, and -- above all -- the exact connection URI it publishes. The URI is a
# contract with three independent Chalk parsers, so a change to its shape is a breaking change to
# the platform, not a cosmetic edit.
#
# `mock_provider "google" {}` configures no provider, reads no credentials and makes no API calls,
# so this suite runs against no GCP project and creates nothing.

mock_provider "google" {}

variables {
  project_id  = "example-project"
  region      = "us-central1"
  network     = "example-vpc"
  instance_id = "chalk-valkey-test"
}

# ---------------------------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------------------------

run "defaults_are_pinned" {
  command = plan

  assert {
    condition     = output.shard_count == 3
    error_message = "default shard_count changed"
  }
  assert {
    condition     = output.replica_count == 1
    error_message = "default replica_count changed"
  }
  assert {
    condition     = output.node_type == "STANDARD_SMALL"
    error_message = "default node_type changed"
  }
  assert {
    condition     = output.engine_version == "VALKEY_9_1"
    error_message = "default engine_version changed"
  }
  assert {
    condition     = google_memorystore_instance.valkey.deletion_protection_enabled
    error_message = "deletion_protection_enabled no longer defaults to true; a destroy would silently empty the online store"
  }
}

# ---------------------------------------------------------------------------------------------
# Settings the module fixes. Each of these is either immutable in the API or something Chalk
# cannot consume the alternative of, so a regression here is not recoverable in place.
# ---------------------------------------------------------------------------------------------

run "fixed_settings_are_pinned" {
  command = plan

  assert {
    condition     = google_memorystore_instance.valkey.mode == "CLUSTER"
    error_message = "mode is no longer CLUSTER; the clustered=true flag on the published URI would become a lie"
  }
  assert {
    condition     = google_memorystore_instance.valkey.authorization_mode == "AUTH_DISABLED"
    error_message = "authorization_mode changed; no Chalk client implements GCP IAM auth"
  }
  assert {
    condition     = google_memorystore_instance.valkey.transit_encryption_mode == "SERVER_AUTHENTICATION"
    error_message = "transit_encryption_mode changed; transit encryption is immutable and must be chosen at creation"
  }
  assert {
    condition     = google_memorystore_instance.valkey.server_ca_mode == "GOOGLE_MANAGED_SHARED_CA"
    error_message = "server_ca_mode changed. It is create-only: moving an existing instance to a different CA mode replaces it and loses the cache."
  }
  assert {
    condition     = google_memorystore_instance.valkey.engine_configs["maxmemory-policy"] == "allkeys-lru"
    error_message = "maxmemory-policy changed; an online feature store must evict rather than refuse writes"
  }
  assert {
    condition     = google_memorystore_instance.valkey.zone_distribution_config[0].mode == "MULTI_ZONE"
    error_message = "zone distribution changed; it is create-only, so this replaces the instance"
  }
}

run "persistence_and_backups_are_pinned" {
  command = plan

  assert {
    condition     = google_memorystore_instance.valkey.persistence_config[0].mode == "RDB"
    error_message = "persistence mode changed"
  }
  assert {
    condition     = google_memorystore_instance.valkey.persistence_config[0].rdb_config[0].rdb_snapshot_period == "TWENTY_FOUR_HOURS"
    error_message = "RDB snapshot period changed"
  }

  # Rendering the block IS the enablement: the provider derives automatedBackupMode from the
  # block's presence and always transmits the field, so losing this block turns backups off on an
  # existing instance rather than leaving it alone.
  assert {
    condition     = length(google_memorystore_instance.valkey.automated_backup_config) == 1
    error_message = "the automated_backup_config block is gone; removing it sends automatedBackupMode=DISABLED and turns backups off"
  }
  assert {
    condition     = google_memorystore_instance.valkey.automated_backup_config[0].retention == "2592000s"
    error_message = "backup retention changed; it must stay a duration-seconds string inside the 1-365 day range"
  }
  assert {
    condition     = google_memorystore_instance.valkey.automated_backup_config[0].fixed_frequency_schedule[0].start_time[0].hours == 9
    error_message = "backup start hour changed; it must not collide with the Sunday 00:00 UTC maintenance window"
  }
  assert {
    condition     = google_memorystore_instance.valkey.maintenance_policy[0].weekly_maintenance_window[0].day == "SUNDAY"
    error_message = "maintenance day changed"
  }
  assert {
    condition     = google_memorystore_instance.valkey.maintenance_policy[0].weekly_maintenance_window[0].start_time[0].hours == 0
    error_message = "maintenance hour changed"
  }
}

# ---------------------------------------------------------------------------------------------
# Derived naming and network normalisation
# ---------------------------------------------------------------------------------------------

run "names_derive_from_instance_id" {
  command = plan

  assert {
    condition     = google_memorystore_instance.valkey.instance_id == "chalk-valkey-test"
    error_message = "instance_id no longer tracks var.instance_id"
  }
  assert {
    condition     = output.secret_id == "chalk-valkey-test-redis-uri"
    error_message = "secret id is no longer <instance_id>-redis-uri; Chalk reads this name from the dashboard"
  }
}

run "bare_network_name_is_qualified_with_project_id" {
  command = plan

  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].network == "projects/example-project/global/networks/example-vpc"
    error_message = "a bare network name is no longer qualified with project_id"
  }
  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].project_id == "example-project"
    error_message = "endpoint project_id no longer falls back to project_id"
  }
}

run "shared_vpc_network_path_is_preserved" {
  command = plan

  variables {
    network = "projects/example-host-project/global/networks/example-shared-vpc"
  }

  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].network == "projects/example-host-project/global/networks/example-shared-vpc"
    error_message = "a fully qualified network path is no longer preserved"
  }
  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].project_id == "example-host-project"
    error_message = "endpoint project_id is no longer parsed from the network path, which breaks Shared VPC"
  }
}

run "network_self_link_is_normalised" {
  command = plan

  variables {
    network = "https://www.googleapis.com/compute/v1/projects/example-host-project/global/networks/example-shared-vpc"
  }

  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].network == "projects/example-host-project/global/networks/example-shared-vpc"
    error_message = "a self-link is no longer stripped to a resource path"
  }
}

# ---------------------------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------------------------

run "caller_labels_are_merged_not_substituted" {
  command = plan

  variables {
    labels = {
      environment = "example-env"
    }
  }

  assert {
    condition     = google_memorystore_instance.valkey.labels["environment"] == "example-env"
    error_message = "caller labels are no longer applied"
  }
  assert {
    condition     = google_memorystore_instance.valkey.labels["managed-by"] == "chalk-vendored-terraform-modules"
    error_message = "caller labels now replace the module's own labels instead of merging with them"
  }
  assert {
    condition     = google_memorystore_instance.valkey.labels["component"] == "chalk-online-store"
    error_message = "the component label is gone"
  }
}

# ---------------------------------------------------------------------------------------------
# The published URI. This is the contract.
#
# The endpoint is computed, so these need `apply` (still fully mocked) plus an override pinning
# the PSC endpoint the instance would have been given.
# ---------------------------------------------------------------------------------------------

run "published_uri_is_rediss_clustered_and_insecure" {
  command = apply

  override_resource {
    target = google_memorystore_instance.valkey
    values = {
      endpoints = [
        {
          connections = [
            {
              psc_auto_connection = [
                {
                  connection_type    = "CONNECTION_TYPE_DISCOVERY"
                  forwarding_rule    = "example-forwarding-rule"
                  ip_address         = "10.0.0.10"
                  network            = "projects/example-project/global/networks/example-vpc"
                  port               = 6379
                  project_id         = "example-project"
                  psc_connection_id  = "000000000000000000"
                  service_attachment = "example-service-attachment"
                }
              ]
            }
          ]
        }
      ]
    }
  }

  # Every element of this string is load-bearing:
  #   rediss      -- TLS on. GCP blocks plaintext clients outright under SERVER_AUTHENTICATION.
  #   /0          -- emitted explicitly rather than relying on the Rust client's default.
  #   clustered   -- mandatory; the Go and Rust parsers hard-error without it.
  #   #insecure   -- certificate verification off. Memorystore's cert comes from a private CA and
  #                  Chalk has no CA-bundle path for redis, so removing this breaks every
  #                  connection rather than hardening it.
  assert {
    condition     = google_secret_manager_secret_version.redis_uri.secret_data == "rediss://10.0.0.10:6379/0?clustered=true#insecure"
    error_message = "the published connection URI changed. Three Chalk parsers depend on this exact shape -- see the module README before touching it."
  }

  assert {
    condition     = output.endpoint_host == "10.0.0.10"
    error_message = "endpoint_host no longer tracks the first PSC auto-connection"
  }
  assert {
    condition     = output.endpoint_port == 6379
    error_message = "endpoint_port no longer tracks the first PSC auto-connection"
  }
}

run "uri_endpoint_lookup_tolerates_no_endpoints" {
  command = apply

  # Its own state. `run` blocks in a file otherwise share one state, and the instance is
  # unchanged from the previous run, so an override would never be applied to it and this would
  # silently assert against the previous run's endpoint.
  state_key = "no_endpoints"

  override_resource {
    target = google_memorystore_instance.valkey
    values = {
      endpoints = []
    }
  }

  assert {
    condition     = output.endpoint_host == ""
    error_message = "an instance with no endpoints should yield an empty host, not an index error"
  }
  assert {
    condition     = output.endpoint_port == 0
    error_message = "an instance with no endpoints should yield port 0, not an index error"
  }
}

# ---------------------------------------------------------------------------------------------
# Service connection policy
# ---------------------------------------------------------------------------------------------

run "service_connection_policy_is_not_created_by_default" {
  command = plan

  assert {
    condition     = length(google_network_connectivity_service_connection_policy.valkey) == 0
    error_message = "the module now creates a service connection policy by default; only one may exist per project/network/region/service class"
  }
  assert {
    condition     = output.service_connection_policy_name == null
    error_message = "service_connection_policy_name should be null when the module does not own the policy"
  }
}

run "service_connection_policy_is_created_on_request" {
  command = plan

  variables {
    create_service_connection_policy  = true
    service_connection_policy_subnets = ["projects/example-project/regions/us-central1/subnetworks/example-subnet"]
  }

  assert {
    condition     = length(google_network_connectivity_service_connection_policy.valkey) == 1
    error_message = "create_service_connection_policy = true no longer creates the policy"
  }
  assert {
    condition     = google_network_connectivity_service_connection_policy.valkey[0].service_class == "gcp-memorystore"
    error_message = "service_class changed; Memorystore will not match a policy under another class"
  }
  assert {
    condition     = google_network_connectivity_service_connection_policy.valkey[0].location == "us-central1"
    error_message = "the policy is no longer created in var.region"
  }
  assert {
    condition     = output.service_connection_policy_name == "chalk-valkey-test-valkey-scp"
    error_message = "service connection policy name changed"
  }
}

run "service_connection_policy_without_subnets_is_rejected" {
  command = plan

  variables {
    create_service_connection_policy  = true
    service_connection_policy_subnets = []
  }

  expect_failures = [google_network_connectivity_service_connection_policy.valkey]
}

# ---------------------------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------------------------

run "zero_replicas_is_rejected" {
  command = plan

  variables {
    replica_count = 0
  }

  expect_failures = [var.replica_count]
}

run "more_than_five_replicas_is_rejected" {
  command = plan

  variables {
    replica_count = 6
  }

  expect_failures = [var.replica_count]
}

run "five_replicas_is_accepted" {
  command = plan

  variables {
    replica_count = 5
  }

  assert {
    condition     = output.replica_count == 5
    error_message = "replica_count 5 is legitimate -- GCP raised the per-primary limit to five -- and must not be rejected"
  }
}

run "lowercase_node_type_is_rejected" {
  command = plan

  variables {
    node_type = "standard-small"
  }

  expect_failures = [var.node_type]
}

run "unknown_node_type_is_rejected" {
  command = plan

  variables {
    node_type = "STANDARD_ENORMOUS"
  }

  expect_failures = [var.node_type]
}

run "full_node_type_set_is_accepted" {
  command = plan

  variables {
    node_type = "HIGHMEM_2XLARGE"
  }

  assert {
    condition     = output.node_type == "HIGHMEM_2XLARGE"
    error_message = "the module must accept all ten node types the provider supports, not just the four the upstream module documented"
  }
}

run "unknown_engine_version_is_rejected" {
  command = plan

  variables {
    engine_version = "VALKEY_9_2"
  }

  expect_failures = [var.engine_version]
}

run "zero_shards_is_rejected" {
  command = plan

  variables {
    shard_count = 0
  }

  expect_failures = [var.shard_count]
}

run "invalid_instance_id_is_rejected" {
  command = plan

  variables {
    instance_id = "Chalk_Valkey_Test"
  }

  expect_failures = [var.instance_id]
}
