# GCP Memorystore for Valkey — Chalk online store

Creates a GCP Memorystore for Valkey instance configured the way Chalk wants it, and publishes a
single Secret Manager secret containing the connection URI to paste into the Chalk dashboard.

The module deliberately exposes a small surface: identity, sizing, and three named handles.
Everything else — cluster mode, authorization mode, transit encryption, the certificate authority,
the eviction policy, persistence, backups, the maintenance window and zone distribution — is fixed
inside the module. Each of those is either immutable in the Memorystore API or something Chalk
cannot consume the alternative of, so exposing it would only let you build an instance Chalk cannot
use, or cannot change later without a rebuild.

## Read this first: two things that will surprise you

**1. `deletion_protection_enabled` defaults to `true`.** This is the opposite of the Memorystore API
default, and it is intentional. A `terraform destroy` run against a misread plan empties your online
feature store. To tear the instance down deliberately, set `deletion_protection_enabled = false`,
**apply that change**, and then destroy. One extra apply is the entire cost; recovering a cache that
was destroyed by accident is not.

**2. The published URI ends in `#insecure`, and that is not a mistake.** See
[Encrypted in transit, unverified certificate](#encrypted-in-transit-unverified-certificate). It is
the single most likely thing in this module for a well-meaning reader to "fix", and removing it does
not harden anything — it breaks every connection.

## Usage

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/gcp/online-store/valkey?ref=v0.4.0"

  project_id  = "example-project"
  region      = "us-central1"
  network     = "example-vpc"
  instance_id = "chalk-online-store"
}

output "chalk_online_store_secret" {
  value = module.chalk_online_store.secret_id
}
```

Shared VPC — pass a qualified network path and the module works out the host project itself:

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/gcp/online-store/valkey?ref=v0.4.0"

  project_id  = "example-service-project"
  region      = "us-central1"
  network     = "projects/example-host-project/global/networks/example-shared-vpc"
  instance_id = "chalk-online-store"

  shard_count   = 6
  replica_count = 2
  node_type     = "STANDARD_LARGE"

  labels = {
    environment = "example-env"
  }
}
```

## Prerequisites

**Enabled APIs** in `project_id`: `memorystore.googleapis.com`,
`networkconnectivity.googleapis.com`, `secretmanager.googleapis.com`, and `compute.googleapis.com`.

**A Private Service Connect service connection policy.** PSC service connectivity automation is the
*only* way to reach a Memorystore for Valkey instance, and the policy must exist for the
`(project, network, region, gcp-memorystore)` combination before the instance is created. Exactly
one policy may exist per combination.

- If a policy already exists — the usual case when several instances share a VPC — leave
  `create_service_connection_policy` at its default of `false`.
- Otherwise set `create_service_connection_policy = true` on **exactly one** module instance for
  that combination and pass `service_connection_policy_subnets`. Do not list proxy-only subnets.

Note the regional quota: the PSC connection limit is roughly two connections per instance per
region, and an unset limit means unlimited.

**Firewall.** Clients need egress to the instance on TCP **6379** *and* **11000–13047**. Valkey
cluster mode uses the second range for the cluster bus and node redirection; allowing only 6379
produces a cluster that connects and then fails on the first redirect. This module does not manage
firewall rules.

## Encrypted in transit, unverified certificate

The module publishes a URI of this exact shape:

```
rediss://<host>:<port>/0?clustered=true#insecure
```

Every part of it is load-bearing.

| Element | Why |
|---|---|
| `rediss` | TLS is on. The instance is created with `SERVER_AUTHENTICATION`, which makes GCP reject plaintext clients outright. |
| `/0` | The database index, emitted explicitly rather than relying on one client's default for an empty path. |
| `clustered=true` | **Mandatory.** All three Chalk URI parsers require it, and two of them raise a hard error when it is missing. |
| `#insecure` | Certificate verification off. **Load-bearing — see below.** |

In a Chalk online-store URI, **TLS and certificate verification are separate axes**. The scheme
decides whether TLS is used at all; the fragment decides whether the server certificate is checked.

| URI | TLS | Verify cert | Result |
|---|---|---|---|
| `rediss://…?clustered=true#insecure` | yes | no | **what this module publishes** |
| `rediss://…?clustered=true` | yes | yes | **fails on first connect** — see below |
| `redis://…?clustered=true` | no | n/a | not offered; transit encryption is immutable and this module always enables it |
| `…?auth_mode=iam` | — | — | not offered; no Chalk client implements GCP IAM auth |

**Why verification cannot be enabled today.** Memorystore presents a server certificate issued by a
Google-managed **private** CA. It is in no public trust store, and Google's own documentation
requires each client to download and install the CA bundle. Chalk has no CA-bundle path for its
redis clients — the only root-certificate setting in the platform is gRPC-only. So `rediss://` with
no fragment means "verify against the system trust store", which cannot contain the issuer, and
every connection fails immediately.

Closing this properly is an engine change — a trust-store path on the online-store client plus
distribution of the regional CA bundle — not a Terraform change. Until that exists, `#insecure`
stays. **Do not remove it on the grounds that it looks like a leftover debug flag.**

## Certificate authority

The instance is created with `server_ca_mode = "GOOGLE_MANAGED_SHARED_CA"` rather than the API
default of `GOOGLE_MANAGED_PER_INSTANCE_CA`.

This attribute is **create-only**: moving an existing instance to a different CA mode replaces it,
and replacing an online store loses the cache. The per-instance default mints a unique CA for every
single instance, which is exactly what makes verification impractical at fleet scale. The shared CA
is one downloadable bundle per region, valid for every instance in it.

It costs nothing today — the published URI carries `#insecure` either way, so behaviour is
identical. It only changes what is possible later: whenever the engine-side verification work
happens, it becomes an engine-only change instead of an engine change *plus* a rebuild of every
instance.

Two consequences, both of which this design wants anyway: the CA mode cannot be changed afterwards,
and in-transit encryption cannot be deactivated on such an instance.

`server_ca_mode` first shipped in the `hashicorp/google` provider at **v7.24.0**, which is why this
module's provider floor is `>= 7.24.0`.

## Persistence and backups are different things

| | RDB persistence | Automated backups |
|---|---|---|
| Configured as | `persistence_config`, RDB, every 24 hours | `automated_backup_config`, daily at 09:00 UTC |
| Retention | n/a | 30 days (`2592000s`) |
| Survives instance deletion | **no** | **yes**, for the retention period |
| Cleanup | automatic | **manual** — backups outlive the instance and must be deleted by hand |

Both are enforced by the module and neither is exposed as an input.

A note on how backups are enabled: the provider derives the API's `automatedBackupMode` from whether
the `automated_backup_config` block is rendered, and it transmits that field on **every** apply.
Removing the block from a future version of this module would therefore send `DISABLED` and actively
turn backups off on existing instances — it is a destructive edit, not a no-op. The test suite
asserts the block is present for this reason.

**Restore is unrehearsed.** This module enforces backups from day one but exposes no restore path.
`managed_backup_source` and `gcs_source` only mean anything at instance creation, and restoring an
online store is a deliberate, supervised operation that wants a runbook rather than a variable.
Backups existing without a rehearsed restore is a known half-measure — do not assume a restore will
be smooth the first time you need one.

## Granting Chalk access to the secret

The module creates the secret but does **not** grant anyone access to it, because it has no reliable
way to know your Chalk deployment's service account identity — guessing would either fail or
over-grant. Grant it yourself:

```bash
gcloud secrets add-iam-policy-binding "$(terraform output -raw secret_id)" \
  --project="example-project" \
  --role="roles/secretmanager.secretAccessor" \
  --member="serviceAccount:<chalk-workload-service-account>@example-project.iam.gserviceaccount.com"
```

For a Chalk environment running on GKE the member is the Google service account bound to the
environment's Kubernetes workload identity. Your Chalk representative can confirm the exact
principal for your deployment.

Then, in the Chalk dashboard: **Integrations > Online Store > Redis**, and set **Secret Name** to
the `secret_id` output.

## Sizing

Capacity is `shard_count` × `node_type`. `maxmemory` is deliberately left unset so Memorystore's own
per-node default applies.

The Valkey engine is **single-threaded per shard**. A larger `node_type` raises capacity but not the
per-shard write ceiling, so a write-throughput problem is solved by adding shards, not by picking a
bigger node.

**`SHARED_CORE_NANO` has no SLA.** Google documents it as suitable for development and testing only.
It is accepted by this module's validation, but do not put a production online store on it.

`replica_count` must be at least 1. Memorystore itself accepts 0; this module rejects it, because
the instance is created with `MULTI_ZONE` distribution and with no replica there is no second copy
to place in another zone — the zone spread buys nothing, and a shard whose only node fails loses its
slot range outright. This is a deliberate restriction of choice for an online store.

## Engine version

Unlike AWS ElastiCache — where the engine version is effectively create-only, which is why this repo
carries both a `valkey8` and a `valkey9` AWS module — GCP's `engine_version` is **mutable in place**
and Memorystore supports in-place upgrades. That is why this directory is `valkey` and carries no
version suffix: a suffix here would encode a constraint that does not exist and force a new
directory for every minor release.

The provider enforces no enum on `engine_version`, so the module validates it against the four
values GCP supports. `VALKEY_9_1` is the default and is also GCP's own default for new instances.

**Downgrades are not guarded by this module.** Terraform configuration cannot read an attribute's
prior state — `self` is unavailable in `precondition` blocks and a resource may not refer to
itself — so a plan-time "is this a downgrade?" check is not expressible. Read the plan before
applying an `engine_version` change. If you want an enforced guard, build it outside the module
against the `google_memorystore_instance` **data source**, which can read the deployed version.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project_id` | `string` | — | **Required.** Project holding the instance and the secret. |
| `region` | `string` | — | **Required.** Region for the instance and its service connection policy. |
| `network` | `string` | — | **Required.** Bare network name, `projects/<p>/global/networks/<n>` path, or self-link. Use a path or self-link for Shared VPC. |
| `instance_id` | `string` | — | **Required.** Instance ID. Immutable. Also derives the secret name. |
| `shard_count` | `number` | `3` | Number of shards. Must be >= 1. |
| `replica_count` | `number` | `1` | Replicas per shard. Must be 1–5; 0 is rejected deliberately. |
| `node_type` | `string` | `STANDARD_SMALL` | One of the ten Memorystore node types, uppercase. |
| `engine_version` | `string` | `VALKEY_9_1` | One of `VALKEY_7_2`, `VALKEY_8_0`, `VALKEY_9_0`, `VALKEY_9_1`. |
| `deletion_protection_enabled` | `bool` | `true` | Refuse to delete the instance. See the warning at the top. |
| `labels` | `map(string)` | `{}` | Merged with the module's own labels; the module's win on collision. |
| `create_service_connection_policy` | `bool` | `false` | Create the PSC policy. Only one may exist per project/network/region/service class. |
| `service_connection_policy_subnets` | `list(string)` | `[]` | Subnets PSC draws endpoint IPs from. Required when the flag above is true. |

## Outputs

| Name | Description |
|---|---|
| `secret_id` | **The dashboard value.** Short ID of the connection-URI secret. |
| `secret_name` | Fully qualified secret name, for IAM bindings. |
| `instance_id` | Instance ID. |
| `endpoint_host` | IP of the first PSC auto-created endpoint, or `""`. |
| `endpoint_port` | Port of the first PSC auto-created endpoint, or `0`. |
| `shard_count` | Shards on the instance. |
| `replica_count` | Replicas per shard. |
| `node_type` | Node machine type. |
| `engine_version` | Engine version the instance is running. |
| `state` | Instance state as reported by the API. |
| `service_connection_policy_name` | Policy name if the module created one, else `null`. |

## Requirements

| | |
|---|---|
| Terraform | `>= 1.3` |
| `hashicorp/google` | `>= 7.24.0` (floor set by `server_ca_mode`) |

The provider constraint is a floor rather than a pessimistic (`~>`) pin, because consumers compose
this module with their own google provider and a pessimistic constraint would make it uninstallable
alongside a newer one.

Running the bundled test suite additionally needs Terraform `>= 1.11` for `state_key`. The suite
uses a mocked provider: it reads no credentials, contacts no API and creates nothing.

```bash
terraform init -backend=false
terraform validate
terraform test
```

## Attribution

This module is derived from
[terraform-google-modules/terraform-google-memorystore](https://github.com/terraform-google-modules/terraform-google-memorystore)
(`modules/valkey`), Copyright 2024 Google LLC, licensed under the Apache License, Version 2.0. It has
been substantially modified by Chalk: the input surface is reduced, Chalk's preferred configuration
is fixed inside the module rather than exposed, the `random` provider dependency is removed, and the
published connection URI follows Chalk's online-store contract. The Apache-2.0 notice is retained in
`main.tf` and `versions.tf`.
