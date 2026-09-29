# GCP Memorystore for Valkey — Chalk online store

Creates a GCP Memorystore for Valkey instance configured the way Chalk wants it, and publishes a
single Secret Manager secret containing the connection URI to paste into the Chalk dashboard.

The module deliberately exposes a small surface: identity, sizing, and three named handles.
Everything else — cluster mode, authorization mode, transit encryption, the certificate authority,
the eviction policy, persistence, backups, the maintenance window and zone distribution — is fixed
inside the module. Each of those is either immutable in the Memorystore API or something Chalk
cannot consume the alternative of, so exposing it would only let you build an instance Chalk cannot
use, or cannot change later without a rebuild.

## Read this first: three things that will surprise you

**1. The eviction policy is fixed at `volatile-lru`, and it is not a tuning knob.** The store holds
internal mapping keys, written with no expiry, that the engine needs in order to interpret every
other key. An eviction policy that can discard keys regardless of expiry can discard those, which
leaves the store **unreadable** rather than merely cold. This is why it is not an input. See
[Eviction policy](#eviction-policy).

**2. `deletion_protection_enabled` defaults to `true`.** This is the opposite of the Memorystore API
default, and it is intentional. A `terraform destroy` run against a misread plan empties your online
feature store. To tear the instance down deliberately, set `deletion_protection_enabled = false`,
**apply that change**, and then destroy. One extra apply is the entire cost; recovering a cache that
was destroyed by accident is not.

**3. The published URI ends in `#insecure`, and that is not a mistake.** See
[Encrypted in transit, unverified certificate](#encrypted-in-transit-unverified-certificate). It is
the single most likely thing in this module for a well-meaning reader to "fix", and removing it does
not harden anything — it breaks every connection.

## Usage

```hcl
module "chalk_online_store" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/gcp/online-store/valkey9?ref=v0.3.3"

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
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/gcp/online-store/valkey9?ref=v0.3.3"

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

**Enabled APIs.** Reconciled against Google's own "Before you begin" for creating a Memorystore for
Valkey instance and for configuring a service connection policy — the first three are Google's list
verbatim, the last two are what this module additionally needs.

| API | Why | Where |
|---|---|---|
| `memorystore.googleapis.com` | The instance. | `project_id` |
| `networkconnectivity.googleapis.com` | Private Service Connect service connectivity automation. **Without it, instance creation fails.** | the network's project |
| `serviceconsumermanagement.googleapis.com` | Same automation. **Without it, instance creation fails.** Google asks for it in "the consumer project that Private Service Connect endpoints are deployed in". | the network's project |
| `compute.googleapis.com` | Required to configure a service connection policy, and to resolve the network. | the network's project |
| `secretmanager.googleapis.com` | The connection-URI secret this module publishes. | `project_id` |
| `cloudkms.googleapis.com` | Only when `kms_key` is set. | the key's project |

Under Shared VPC "the network's project" is the host project, not `project_id`. When the two are
the same, enable everything in the one project.

`serviceconsumermanagement.googleapis.com` is the one most often missed, and its failure mode is
the instance simply refusing to be created — not a permissions error naming the API.

Two APIs are deliberately **not** on this list. `servicedirectory.googleapis.com` is not named as a
requirement by either of Google's two "Before you begin" lists. `orgpolicy.googleapis.com` is not
needed because this module does not read your organization policies: there is no effective-policy
data source (the v1 one is project/folder-scoped and misses inherited org-level policies), and
reading it would fail the plan for anyone lacking the permission.

**A Private Service Connect service connection policy.** PSC service connectivity automation is the
*only* way to reach a Memorystore for Valkey instance, and the policy must exist for the
`(project, network, region, gcp-memorystore)` combination before the instance is created. Exactly
one policy may exist per combination.

- If a policy already exists — the usual case when several instances share a VPC — leave
  `create_service_connection_policy` at its default of `false`.
- Otherwise set `create_service_connection_policy = true` on **exactly one** module instance for
  that combination and pass `service_connection_policy_subnets`. Do not list proxy-only subnets.

When the module creates the policy it names it `<network>-<region>-memorystore`, after the scope the
policy actually has. The name deliberately does **not** contain `instance_id`: the policy is shared
by every Memorystore instance on that network, and naming it after whichever instance happened to
create it would imply an ownership that does not exist.

Note the regional quota: the PSC connection limit is roughly two connections per instance per
region, and an unset limit means unlimited.

**Org policy: `constraints/gcp.resourceLocations`.** If your organization enforces it, the default
automatic replication of the connection-URI secret is **rejected** — "automatic" means every region,
which a location constraint forbids. Set `secret_replication_location` to a permitted region and the
secret is created with a single user-managed replica there instead. Leave it unset otherwise.
Secret Manager does not allow a replication policy to change after creation, so this has to be
right the first time.

**Firewall.** Clients need egress to the instance on TCP **6379** *and* **11000–13047**. Valkey
cluster mode uses the second range for the cluster bus and node redirection; allowing only 6379
produces a cluster that connects and then fails on the first redirect. This module does not manage
firewall rules.

## Which endpoint the URI carries

A cluster-mode instance publishes **more than one** Private Service Connect connection: a
**discovery** endpoint, a **primary** (data) endpoint and, with replicas, a **reader** endpoint.
They are separate elements of `endpoints[].connections`. Google documents the primary endpoint as
one clients must not connect to directly — only the discovery endpoint is a client entry point.

The module selects it by `connection_type == "CONNECTION_TYPE_DISCOVERY"`, never by list position.
Position is **uncontracted**: neither the Memorystore REST reference nor the provider schema states
an order for these connections, so an index relies on something nobody promised. It also looks
correct for as long as an instance has only one connection, which is exactly how this class of bug
survives review.

If **no** discovery connection exists — or if **more than one** does, which means endpoints were
attached out of band — the module **refuses to publish** rather than emitting a URI it guessed at.
That is deliberate: `rediss://:0/0?clustered=true#insecure` passes Chalk's own URI validation, which
only insists on `clustered`, so the dashboard would accept it and the fault would surface days later
as an unexplained connect error. A plan-time precondition failure naming the missing endpoint is
much cheaper. The usual cause of the zero case is a missing service connection policy, or one whose
subnets have no free addresses.

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

## Customer-managed encryption keys

`kms_key` is optional and defaults to `null`, which leaves the instance on Google-managed
encryption. Set it to a Cloud KMS CryptoKey resource ID to encrypt the instance's **at-rest** data
with your own key: backups, RDB persistence files, and the metadata behind the security features.
In-memory data is not what CMEK covers.

```hcl
kms_key = "projects/example-kms-project/locations/us-central1/keyRings/example-ring/cryptoKeys/example-key"
```

Four things to know before you set it.

**It is create-only.** Google: *"You can enable CMEK only on new instances. You can't apply CMEK to
existing instances."* The provider marks the attribute `ForceNew`, so adding it, removing it or
repointing it **replaces the instance** and discards the cache. Decide at creation.

**It is mandatory in some organizations.** `constraints/gcp.restrictNonCmekServices` lists services
that may not hold non-CMEK data. If the Memorystore for Valkey API is on that deny list, you
*cannot create a non-CMEK instance at all* — and because the attribute is create-only, a module
without this input would leave you with no path forward. That is why the input exists despite the
module's otherwise minimal surface.

**The key must live in the instance's region.** Google requires the key ring, the key and the
instance to share a location and fails the create request when they do not. The module compares the
key's `locations/` segment to `region` in a plan-time precondition, so a mismatch is caught before
anything is built. A `global` key ring can never satisfy this, and is rejected by the same check.

**The key's project is not checked, on purpose.** Holding keys in a separate central KMS project is
a normal arrangement that Google explicitly supports, and which key projects are permitted is
governed by `constraints/gcp.restrictCmekCryptoKeyProjects` — your policy, not this module's.

One prerequisite the module cannot do for you: grant
`roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key to the Memorystore service agent,
`service-<PROJECT_NUMBER>@gcp-sa-memorystore.iam.gserviceaccount.com`. Without it the instance
cannot be created.

## Persistence and backups are different things

| | RDB persistence | Automated backups |
|---|---|---|
| Configured as | `persistence_config`, RDB, every 24 hours anchored at 16:45 UTC | `automated_backup_config`, daily at 09:00 UTC |
| Retention | n/a | 30 days (`2592000s`) |
| Survives instance deletion | **no** | **yes**, for the retention period |
| Cleanup | automatic | **manual** — backups outlive the instance and must be deleted by hand |

Both are enforced by the module and neither is exposed as an input.

The RDB snapshot time is pinned rather than left to the API. `rdb_snapshot_start_time` is the
timestamp future snapshots align to, and when it is unset the API substitutes *the moment the
instance was created* — so the snapshot would land at an arbitrary hour that varies per instance.
16:45 UTC is the midpoint of the widest gap between the other two scheduled activities on the
instance, the 09:00 UTC backup and the Sunday 00:30 UTC maintenance window, giving 7h45m of
clearance from each. The date part of the value is a constant in the past: it is an alignment
anchor, not a schedule, and a computed timestamp there would produce perpetual plan drift.

A note on how backups are enabled: the provider derives the API's `automatedBackupMode` from whether
the `automated_backup_config` block is rendered, and it transmits that field on **every** apply.
Removing the block from a future version of this module would therefore send `DISABLED` and actively
turn backups off on existing instances — it is a destructive edit, not a no-op.

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

## Eviction policy

`maxmemory-policy` is fixed at **`volatile-lru`**, which is also Memorystore's own default. It is
deliberately not an input, because it is a correctness requirement rather than a preference.

The online store holds two kinds of key. Feature values carry an expiry. Alongside them the store
keeps a small set of **internal mapping keys, written with no expiry**, which the engine needs in
order to interpret everything else in the store.

`volatile-lru` reclaims memory only from keys that carry an expiry, so the mapping keys are never
candidates for eviction. Under a policy that can discard keys regardless of expiry, memory pressure
can take the mapping with it — and at that point the store is not cold, it is **unreadable**:
the data that remains cannot be interpreted, and recovery means rebuilding state rather than
waiting for a cache to warm.

**The tradeoff, stated plainly: on a full instance, writes are refused rather than evicting.** If
the instance reaches its memory limit and no expiring keys are left to reclaim, Valkey returns an
out-of-memory error on write instead of discarding something it must keep. That is the intended
behaviour — a write that fails loudly is a better outcome than a store that quietly stops making
sense.

That makes sizing load-bearing. `maxmemory` is left unset, so Memorystore's per-node default
applies; size the instance for your working set, including the keys you write without a TTL. See
[Sizing](#sizing).

## Sizing

Capacity is `shard_count` × `node_type`. `maxmemory` is deliberately left unset so Memorystore's own
per-node default applies.

Because the [eviction policy](#eviction-policy) reclaims only from keys that carry an expiry, a
full instance refuses writes rather than discarding keys it must keep. Size for your working set,
including any keys written without a TTL.

The Valkey engine is **single-threaded per shard**. A larger `node_type` raises capacity but not the
per-shard write ceiling, so a write-throughput problem is solved by adding shards, not by picking a
bigger node.

**`SHARED_CORE_NANO` has no SLA.** Google documents it as suitable for development and testing only.
It is accepted by this module's validation, but do not put a production online store on it.

**`CUSTOM_PICO`, `CUSTOM_MICRO` and `CUSTOM_MINI` are rejected.** They exist in the provider's enum,
so Terraform would happily plan them — but Google offers custom node types *for Cluster Mode
Disabled instances only*, and they do not appear in the Cluster-Mode-Enabled capacity table. This
module always builds a cluster, so those three would pass `plan` and fail at `apply`. The validation
turns that into a plan-time error that names the reason. The seven accepted values are
`SHARED_CORE_NANO`, `STANDARD_SMALL`, `HIGHMEM_MEDIUM`, `HIGHCPU_MEDIUM`, `STANDARD_LARGE`,
`HIGHMEM_XLARGE` and `HIGHMEM_2XLARGE`.

`replica_count` must be at least 1. Memorystore itself accepts 0; this module rejects it, because
the instance is created with `MULTI_ZONE` distribution and with no replica there is no second copy
to place in another zone — the zone spread buys nothing, and a shard whose only node fails loses its
slot range outright. This is a deliberate restriction of choice for an online store.

## Engine version

On Memorystore, `engine_version` is **mutable in place** — Memorystore supports in-place upgrades,
unlike AWS ElastiCache where the engine version is effectively create-only.

That mutability is exactly why this module carries a `9` in its path. Because the version can change
in place, raising this module's default engine version would upgrade an existing consumer's instance
on their next apply, without them asking for it. A version-suffixed directory prevents that: a
future engine default ships as a **new** module path, so you opt in by changing `source` rather than
being carried along silently. (The AWS modules are suffixed too, but for the opposite reason — there
the suffix guards a create-only field; here it guards a silent in-place change.)

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
| `network` | `string` | — | **Required.** Bare network name, `projects/<p>/global/networks/<n>` path, or a self-link in either the `www.googleapis.com` or `compute.googleapis.com` spelling (a trailing slash is tolerated). Use a path or self-link for Shared VPC. |
| `instance_id` | `string` | — | **Required.** Instance ID. Immutable. Also derives the secret name. |
| `shard_count` | `number` | `3` | Number of shards. Must be >= 1. |
| `replica_count` | `number` | `1` | Replicas per shard. Must be 1–5; 0 is rejected deliberately. |
| `node_type` | `string` | `STANDARD_SMALL` | One of the **seven** Cluster-Mode-Enabled node types, uppercase. The three `CUSTOM_*` types are rejected — see Sizing. |
| `engine_version` | `string` | `VALKEY_9_1` | One of `VALKEY_7_2`, `VALKEY_8_0`, `VALKEY_9_0`, `VALKEY_9_1`. |
| `deletion_protection_enabled` | `bool` | `true` | Refuse to delete the instance. See the warning at the top. |
| `kms_key` | `string` | `null` | CryptoKey for at-rest encryption. Create-only; must be in `region`. Required under `constraints/gcp.restrictNonCmekServices`. |
| `labels` | `map(string)` | `{}` | Merged with the module's own labels; the module's win on collision. |
| `secret_replication_location` | `string` | `null` | Pin the connection-URI secret to one region instead of replicating it automatically. Required under `constraints/gcp.resourceLocations`. Immutable — changing it replaces the secret. |
| `create_service_connection_policy` | `bool` | `false` | Create the PSC policy. Only one may exist per project/network/region/service class. |
| `service_connection_policy_subnets` | `list(string)` | `[]` | Subnets PSC draws endpoint IPs from. Required when the flag above is true. |

## Outputs

| Name | Description |
|---|---|
| `secret_id` | **The dashboard value.** Short ID of the connection-URI secret. |
| `secret_name` | Fully qualified secret name, for IAM bindings. |
| `instance_id` | Instance ID. |
| `endpoint_host` | IP of the PSC **discovery** endpoint — the one clients use. Never the data endpoint. |
| `endpoint_port` | Port of the PSC discovery endpoint. |
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

## Attribution

This module is derived from
[terraform-google-modules/terraform-google-memorystore](https://github.com/terraform-google-modules/terraform-google-memorystore)
(`modules/valkey`), Copyright 2024 Google LLC, licensed under the Apache License, Version 2.0. It has
been substantially modified by Chalk: the input surface is reduced, Chalk's preferred configuration
is fixed inside the module rather than exposed, the `random` provider dependency is removed, and the
published connection URI follows Chalk's online-store contract. The Apache-2.0 notice is retained in
`main.tf` and `versions.tf`.
