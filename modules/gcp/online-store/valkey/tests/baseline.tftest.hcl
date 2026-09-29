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

# `location` and `project` are the two arguments whose absence would be invisible: the plan still
# renders, the instance is simply built somewhere else. Pin them to the variables rather than
# accepting whatever the provider block happens to default to.
run "placement_tracks_the_inputs" {
  command = plan

  variables {
    project_id = "example-other-project"
    region     = "europe-west1"
  }

  assert {
    condition     = google_memorystore_instance.valkey.location == "europe-west1"
    error_message = "the instance is no longer created in var.region"
  }
  assert {
    condition     = google_memorystore_instance.valkey.project == "example-other-project"
    error_message = "the instance is no longer created in var.project_id"
  }
  assert {
    condition     = google_secret_manager_secret.redis_uri.project == "example-other-project"
    error_message = "the connection-URI secret is no longer created in var.project_id; Chalk would be pointed at a secret in the wrong project"
  }
}

run "deletion_protection_can_be_disabled" {
  command = plan

  variables {
    deletion_protection_enabled = false
  }

  # The documented teardown path is: set this to false, APPLY that change, then destroy. If the
  # module stopped honouring the input, that path would silently stop working.
  assert {
    condition     = google_memorystore_instance.valkey.deletion_protection_enabled == false
    error_message = "deletion_protection_enabled = false is no longer honoured, which makes the documented teardown path impossible"
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

  # The anchor the daily snapshot aligns to. Leaving it unset does not mean "no control" -- it
  # means the API substitutes the instance's creation time, so the snapshot lands at an arbitrary
  # hour and its separation from the 09:00 backup and the Sunday 00:30 maintenance window becomes
  # luck. It must also stay a CONSTANT: a timestamp() call here would re-evaluate every plan.
  assert {
    condition     = google_memorystore_instance.valkey.persistence_config[0].rdb_config[0].rdb_snapshot_start_time == "2025-01-01T16:45:00Z"
    error_message = "the RDB snapshot anchor changed. 16:45 UTC is the midpoint of the widest gap between the 09:00 UTC backup and the SUNDAY 00:30 UTC maintenance window; if it is now unset, the snapshot runs at whatever time of day the instance was created."
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
    error_message = "backup start hour changed; it must not collide with the Sunday 00:30 UTC maintenance window"
  }
  assert {
    condition     = google_memorystore_instance.valkey.maintenance_policy[0].weekly_maintenance_window[0].day == "SUNDAY"
    error_message = "maintenance day changed"
  }
  # SUNDAY 00:30 UTC is Chalk's preferred window across the internal estate. The minutes are
  # load-bearing -- 00:00 and 00:30 are different windows, and the RDB anchor above is chosen
  # relative to this one.
  assert {
    condition     = google_memorystore_instance.valkey.maintenance_policy[0].weekly_maintenance_window[0].start_time[0].hours == 0
    error_message = "maintenance hour changed"
  }
  assert {
    condition     = google_memorystore_instance.valkey.maintenance_policy[0].weekly_maintenance_window[0].start_time[0].minutes == 30
    error_message = "the maintenance window is no longer at 00:30; Chalk-preferred across the internal estate is SUNDAY 00:30 UTC, not 00:00"
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

# `compute.googleapis.com` is the other spelling GCP emits for a self-link, and it is just as
# legitimate as `www.googleapis.com`. Stripping only the second prefix left the first intact and
# produced a malformed network id that the API would reject at apply.
run "compute_googleapis_self_link_is_normalised" {
  command = plan

  variables {
    network = "https://compute.googleapis.com/compute/v1/projects/example-host-project/global/networks/example-shared-vpc"
  }

  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].network == "projects/example-host-project/global/networks/example-shared-vpc"
    error_message = "the compute.googleapis.com self-link spelling is not normalised"
  }
  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].project_id == "example-host-project"
    error_message = "the host project is not parsed out of a compute.googleapis.com self-link, which breaks Shared VPC"
  }
}

run "trailing_slash_on_a_network_path_is_tolerated" {
  command = plan

  variables {
    network = "projects/example-host-project/global/networks/example-shared-vpc/"
  }

  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].network == "projects/example-host-project/global/networks/example-shared-vpc"
    error_message = "a trailing slash survives into the network id, producing a value the API rejects"
  }
}

run "trailing_whitespace_on_a_bare_network_name_is_tolerated" {
  command = plan

  variables {
    network = "  example-vpc  "
  }

  assert {
    condition     = google_memorystore_instance.valkey.desired_auto_created_endpoints[0].network == "projects/example-project/global/networks/example-vpc"
    error_message = "surrounding whitespace survives into the network id"
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
    error_message = "endpoint_host no longer tracks the discovery PSC auto-connection"
  }
  assert {
    condition     = output.endpoint_port == 6379
    error_message = "endpoint_port no longer tracks the discovery PSC auto-connection"
  }
}

# A CLUSTER-mode instance carries MORE THAN ONE PSC auto-connection: a discovery endpoint and a
# data (primary) endpoint. The API promises no ordering between them, and Google documents the
# data endpoint with "don't connect to this endpoint directly", so the endpoint must be selected
# by `connection_type` and never by list position.
#
# The data connection is deliberately listed FIRST here. Every other fixture in this file has
# exactly one connection, which is what made position-based selection look correct.
run "discovery_endpoint_is_selected_by_type_not_by_position" {
  command = apply

  state_key = "two_connections"

  override_resource {
    target = google_memorystore_instance.valkey
    values = {
      endpoints = [
        {
          connections = [
            {
              psc_auto_connection = [
                {
                  connection_type    = "CONNECTION_TYPE_PRIMARY"
                  forwarding_rule    = "example-forwarding-rule-data"
                  ip_address         = "10.0.0.20"
                  network            = "projects/example-project/global/networks/example-vpc"
                  port               = 6379
                  project_id         = "example-project"
                  psc_connection_id  = "111111111111111111"
                  service_attachment = "example-service-attachment-data"
                }
              ]
            },
            {
              psc_auto_connection = [
                {
                  connection_type    = "CONNECTION_TYPE_DISCOVERY"
                  forwarding_rule    = "example-forwarding-rule-discovery"
                  ip_address         = "10.0.0.10"
                  network            = "projects/example-project/global/networks/example-vpc"
                  port               = 6379
                  project_id         = "example-project"
                  psc_connection_id  = "000000000000000000"
                  service_attachment = "example-service-attachment-discovery"
                }
              ]
            }
          ]
        }
      ]
    }
  }

  assert {
    condition     = google_secret_manager_secret_version.redis_uri.secret_data == "rediss://10.0.0.10:6379/0?clustered=true#insecure"
    error_message = "the published URI carries an endpoint other than the discovery one. Taking psc_auto_connection[0] publishes the data endpoint whenever the API returns it first, and Google documents that endpoint as one clients must not connect to directly."
  }
  assert {
    condition     = output.endpoint_host == "10.0.0.10"
    error_message = "endpoint_host is not the discovery endpoint's address"
  }
}

run "uri_publication_fails_when_no_endpoint_exists" {
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

  # An earlier version of this module tolerated this and published
  # `rediss://:0/0?clustered=true#insecure`. That is worse than an index error: Chalk's
  # ValidateRedisURI accepts it, because the only thing it insists on is `clustered`. The
  # dashboard would take it and the failure would surface much later as an unexplained connect
  # error. Refusing at plan/apply is the correct behaviour.
  expect_failures = [google_secret_manager_secret_version.redis_uri]
}

run "uri_publication_fails_when_only_a_data_endpoint_exists" {
  command = apply

  state_key = "data_endpoint_only"

  override_resource {
    target = google_memorystore_instance.valkey
    values = {
      endpoints = [
        {
          connections = [
            {
              psc_auto_connection = [
                {
                  connection_type    = "CONNECTION_TYPE_PRIMARY"
                  forwarding_rule    = "example-forwarding-rule-data"
                  ip_address         = "10.0.0.20"
                  network            = "projects/example-project/global/networks/example-vpc"
                  port               = 6379
                  project_id         = "example-project"
                  psc_connection_id  = "111111111111111111"
                  service_attachment = "example-service-attachment-data"
                }
              ]
            }
          ]
        }
      ]
    }
  }

  # Falling back to "whatever connection is present" would publish the data endpoint here, which
  # Google documents as not to be connected to directly. Fail loudly instead.
  expect_failures = [google_secret_manager_secret_version.redis_uri]
}

run "uri_publication_fails_when_several_discovery_endpoints_exist" {
  command = apply

  state_key = "two_discovery_endpoints"

  # Two auto-created endpoints, one per network. This module configures exactly one, so reaching
  # this state means endpoints were attached out of band -- and there is then no single URI that
  # is the right answer. Taking [0] of the filtered set would just move the original guess up a
  # level, so the module refuses and says so.
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
                  forwarding_rule    = "example-forwarding-rule-discovery-a"
                  ip_address         = "10.0.0.10"
                  network            = "projects/example-project/global/networks/example-vpc"
                  port               = 6379
                  project_id         = "example-project"
                  psc_connection_id  = "000000000000000000"
                  service_attachment = "example-service-attachment-a"
                }
              ]
            }
          ]
        },
        {
          connections = [
            {
              psc_auto_connection = [
                {
                  connection_type    = "CONNECTION_TYPE_DISCOVERY"
                  forwarding_rule    = "example-forwarding-rule-discovery-b"
                  ip_address         = "10.1.0.10"
                  network            = "projects/example-project/global/networks/example-other-vpc"
                  port               = 6379
                  project_id         = "example-project"
                  psc_connection_id  = "222222222222222222"
                  service_attachment = "example-service-attachment-b"
                }
              ]
            }
          ]
        }
      ]
    }
  }

  expect_failures = [google_secret_manager_secret_version.redis_uri]
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
  # The policy is a SINGLETON per (project, network, region, service class), shared by every
  # Memorystore instance in the VPC. Its name must therefore not carry the instance_id of
  # whichever module instance happened to create it -- that reads as ownership that does not
  # exist, and invites a second caller to create a "different" policy the API will reject.
  assert {
    condition     = output.service_connection_policy_name == "example-vpc-us-central1-memorystore"
    error_message = "the service connection policy name is no longer derived from the network and region. Do not reintroduce instance_id: the policy is shared by every instance on the network."
  }
}

run "service_connection_policy_name_uses_the_bare_network_name_from_a_path" {
  command = plan

  variables {
    create_service_connection_policy  = true
    service_connection_policy_subnets = ["projects/example-host-project/regions/us-central1/subnetworks/example-subnet"]
    network                           = "projects/example-host-project/global/networks/example-shared-vpc"
  }

  assert {
    condition     = output.service_connection_policy_name == "example-shared-vpc-us-central1-memorystore"
    error_message = "the policy name is not derived from the bare network name when a qualified path is supplied"
  }
  assert {
    condition     = google_network_connectivity_service_connection_policy.valkey[0].project == "example-host-project"
    error_message = "the policy is no longer created in the network's host project, which breaks Shared VPC"
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

# ---------------------------------------------------------------------------------------------
# Secret replication
#
# Automatic replication is the default and is what almost every project wants. It is, however,
# rejected outright under `constraints/gcp.resourceLocations`, which some organizations enforce --
# so the location-restricted form has to stay reachable.
# ---------------------------------------------------------------------------------------------

run "secret_replication_is_automatic_by_default" {
  command = plan

  assert {
    condition     = length(google_secret_manager_secret.redis_uri.replication[0].auto) == 1
    error_message = "the secret is no longer automatically replicated by default"
  }
  assert {
    condition     = length(google_secret_manager_secret.redis_uri.replication[0].user_managed) == 0
    error_message = "the default replication is no longer purely automatic"
  }
}

run "secret_replication_can_be_pinned_to_one_location" {
  command = plan

  variables {
    secret_replication_location = "us-central1"
  }

  assert {
    condition     = length(google_secret_manager_secret.redis_uri.replication[0].auto) == 0
    error_message = "automatic replication is still rendered alongside the pinned location; a secret has exactly one replication policy"
  }
  assert {
    condition     = google_secret_manager_secret.redis_uri.replication[0].user_managed[0].replicas[0].location == "us-central1"
    error_message = "secret_replication_location no longer pins the secret's replica. Organizations enforcing constraints/gcp.resourceLocations cannot hold an automatically replicated secret at all, so losing this capability locks them out of the module."
  }
}

run "secret_replication_location_need_not_match_region" {
  command = plan

  variables {
    region                      = "us-central1"
    secret_replication_location = "us-east1"
  }

  assert {
    condition     = google_secret_manager_secret.redis_uri.replication[0].user_managed[0].replicas[0].location == "us-east1"
    error_message = "secret_replication_location is being overridden by region; the permitted secret location need not equal the instance's region"
  }
}

run "empty_secret_replication_location_is_rejected" {
  command = plan

  variables {
    secret_replication_location = "  "
  }

  expect_failures = [var.secret_replication_location]
}
