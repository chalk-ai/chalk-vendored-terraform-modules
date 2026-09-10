# Karpenter Chalk Standard Module

Terraform module that creates Chalk's **standard** set of Karpenter node resources — three
`EC2NodeClass` objects, six `NodePool` objects and one `RuntimeClass` — on an EKS cluster
that Chalk does **not** manage.

It is a direct port of the objects Chalk's own pipeline creates, not a generic node-pool
builder. It takes two required inputs, and everything else is fixed.

## Features

- All ten standard objects from one module. No nested modules, no sub-module calls.
- Karpenter **v1** schemas only (`karpenter.sh/v1`, `karpenter.k8s.aws/v1`).
- Two required inputs: `subnets` and `cluster_name`. The node role name is derived from
  the cluster name and is the only other thing a caller normally touches.
- Pool names, labels, taints, requirements, boot volume sizes, disruption policy and
  vCPU limits are all hardcoded to Chalk's standard values.
- Optional `chalk-nap` fallback pool for dataplane-v2 clusters, behind one input.
- Manifests are rendered from YAML template files, so the object that will be applied is
  readable as YAML in the repository rather than assembled by `yamlencode`.
- Characterization tests pin every one of the ten manifests in full.

## Why you need this on a cluster Chalk does not manage

On a Chalk-managed cluster these objects come from Chalk's infrastructure pipeline. On a
self-managed cluster, nothing creates them, and the Chalk UI cannot fill the gap:

| | Chalk UI | This module |
|---|---|---|
| Create `NodePool` | yes | yes |
| Create `EC2NodeClass` | **no** — requires one to already exist | yes |
| Create `RuntimeClass` | **no** — cannot at all | yes |

## Requirements

| Name | Version |
|------|---------|
| kubectl provider (`alekc/kubectl`) | `~> 2.3` |

This module creates Kubernetes objects only. Everything below must already be true, and
none of it is created or verified here:

- **The Karpenter controller is installed and working** on the cluster, at a v1 chart
  (1.x). The Helm releases were deliberately not ported; see "What is not ported".
- **The controller has IAM permission** to launch instances and pass the node role.
- **The node role exists** and is mapped in the cluster's auth configuration. A node
  launched with an unmapped role never joins.
- **The subnets are tagged** for Karpenter discovery, and **the security groups carry
  either `karpenter.sh/discovery = <cluster_name>` or `aws:eks:cluster-name = <cluster_name>`**.
  Both tag terms are emitted, so either convention works — but if neither tag is present
  the node classes match no security group and go `NotReady`.

## Usage

### Basic

```hcl
module "chalk_karpenter" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/chalk-standard?ref=v0.3.0"

  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
}
```

The provider must be configured by the root module:

```hcl
provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
  apply_retry_count      = 3
}
```

### Dataplane v2

```hcl
module "chalk_karpenter" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/chalk-standard?ref=v0.3.0"

  cluster_name            = "example-cluster"
  subnets                 = ["subnet-xxxxx", "subnet-yyyyy"]
  chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
}
```

### Cluster whose node role does not follow the Chalk convention

```hcl
module "chalk_karpenter" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/chalk-standard?ref=v0.3.0"

  cluster_name   = "example-cluster"
  subnets        = ["subnet-xxxxx", "subnet-yyyyy"]
  node_role_name = "example-cluster-node-role"
}
```

## What this module creates

| Object | Name | Notes |
|---|---|---|
| `EC2NodeClass` | `al2023` | AL2023 (`al2023@latest` alias), 200Gi gp3 root, IMDSv2 required |
| `EC2NodeClass` | `al2023-offline-lssd` | As above plus `instanceStorePolicy: RAID0` for local NVMe scratch |
| `EC2NodeClass` | `gvisor` | As `al2023` plus MIME-multipart user data that installs `runsc` and registers it with containerd |
| `NodePool` | `oss-controllers` | `t3.medium` only, 6 vCPU limit, untainted — where open-source controllers land |
| `NodePool` | `chalk-infrastructure` | Tainted `chalk.ai/workload-type=infrastructure` |
| `NodePool` | `chalk-online` | Tainted `chalk.ai/workload-type=online` |
| `NodePool` | `chalk-offline` | Tainted `chalk.ai/workload-type=offline`, requires local NVMe |
| `NodePool` | `chalk-nap` | **Dataplane v2 only.** Same capacity as `chalk-online` but with *no* workload-type taint |
| `NodePool` | `chalk-compute` | gVisor sandboxed compute, triple-tainted |
| `NodePool` | `chalk-compute-gpu` | NVIDIA g/p families, tainted `nvidia.com/gpu=true` |
| `RuntimeClass` | `gvisor` | `handler: runsc`, with the node selector and three tolerations that place a pod on `chalk-compute` |

Every `NodePool` except `oss-controllers` carries a 128000 vCPU limit and the
`chalk.ai/managed-by=chalk` taint.

## Why this module is not configurable

The values the upstream source hardcodes are `local`s in `main.tf`, not variables:
`max_cpu`, `create_gvisor_nodeclass`, both boot volume sizes, the disruption policy, the
weights, and every requirement list.

That is the design, not an omission. Promoting them to inputs produces a generic
node-pool builder, and a generic node-pool builder cannot promise that a cluster matches
Chalk's standard shape — which is the only thing this module is for. Changing one of them
means editing this file, which puts the change through review.

If you need node pools that are *not* Chalk's standard set, use the generic
`modules/aws/karpenter/ec2nodeclass` and `modules/aws/karpenter/nodepool` building blocks
instead of parameterising this one.

## Deliberate divergences from the sibling karpenter modules

Three things here will look like bugs to a reviewer who knows the generic
`ec2nodeclass` and `nodepool` modules. All three are deliberate, and all three follow
from this module being a **direct port**.

### 1. `subnets` is a `list(string)`, not `subnet_selector_terms`

The sibling `ec2nodeclass` module takes `subnet_selector_terms`, which can select by tag.
This module takes a plain list of subnet IDs and renders one `{ id = <subnet> }` term per
element, exactly as the source does. Selecting subnets by tag is not part of Chalk's
standard shape, and accepting arbitrary selector terms is precisely the generality that
was rejected.

### 2. This module emits `disruption` and `expireAfter`; the siblings do not

`consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter: 0s` and
`expireAfter: 720h` are all Karpenter CRD defaults. The sibling modules deliberately omit
them and let the CRD apply the default. This module emits them explicitly because the
source does, and because a port that renders a *different manifest* from the thing it
ports is not a port. The practical effect is a visible value in `kubectl get nodepool -o
yaml` rather than an implicit one, and immunity to a future CRD default change.

`terminationGracePeriod: 30m` is **not** a CRD default and is load-bearing: Karpenter v1
leaves node draining unbounded without it, so one undrainable pod can block a rollout
indefinitely.

### 3. This module sets `upgrade_api_version` and `sensitive_fields`

The sibling modules dropped both after checking them against `alekc/kubectl` 2.x. This
module keeps them, for fidelity:

- `upgrade_api_version = true` on all node classes and pools.
- `sensitive_fields = []` on all pools, with the source's comment that NodePool specs
  carry no secrets and the full diff should be visible in plans.

Note that the `sensitive_fields` justification **may predate provider v2**. In
`alekc/kubectl` v2.4.1, `sensitive_fields` controls redaction of `yaml_body_parsed`; it
does not make `yaml_body` non-sensitive, because `yaml_body` is marked sensitive at the
schema level regardless. That is why this module's outputs are derived from locals rather
than read back out of the resources, and why the tests wrap every read in
`nonsensitive()`. Before removing `sensitive_fields`, confirm what it actually buys on the
provider version in use — do not remove it on the assumption that it is decorative.

## What is not ported

Deliberately excluded from the upstream file — this module manages node *shape* only:

- `helm_release.karpenter` and `helm_release.karpenter_crd`
- The Karpenter controller IRSA role, its policy document, policy and attachment
- The spot-termination SQS queue and its queue policy
- The four interruption CloudWatch event rules and their targets

Installing and empowering the Karpenter controller stays with the cluster's owner, who
already has an opinion about how IAM is managed in their account. Every input those
resources needed is excluded too, which is what makes the cut clean.

Two further things this module does not do:

- **It does not install the NVIDIA device plugin.** Without a device-plugin DaemonSet
  that tolerates `nvidia.com/gpu`, nodes from `chalk-compute-gpu` never advertise the
  `nvidia.com/gpu` resource, and nothing schedules on them.
- **It grants nothing in IAM.** `node_role_name` names a role that must already exist and
  already be mapped in the cluster's auth configuration.

## Provenance and upstream drift

Ported from:

```
chalk-terraform  infra/aws/terragrunt/chalk-kube/karpenter.tf
                 @ aa986a8544bd8be391ed81457f95e3cb4775ef82
```

Nothing in this repository changes when that file changes, so drift is invisible unless
you go looking. `scripts/check-upstream-drift.sh` goes looking:

```bash
./scripts/check-upstream-drift.sh                       # $HOME/IdeaProjects/chalk-terraform
./scripts/check-upstream-drift.sh /path/to/chalk-terraform
CHALK_TERRAFORM_REPO=/path/to/chalk-terraform ./scripts/check-upstream-drift.sh
```

It is read-only, runs one `git log`, and exits `0` for no drift, `1` when commits have
touched the source file, and `2` on a usage or environment error — so it can gate CI.

When drift is reported: review each commit against this module, apply what belongs here,
then bump `UPSTREAM_SHA` in the script **and** the SHA above.

### Known, intentional differences from the source at that commit

- **Karpenter v1 only.** The source's `karpenter_is_v1` flag and every ternary it fed are
  collapsed to their v1 branch. There is no way to render a v1beta1 manifest.
- **The GPU pool is unconditional.** In the source it was gated on `karpenter_is_v1`.
- **`amiFamily` is never emitted.** The v1 `amiSelectorTerms` alias `al2023@latest`
  already implies the family.
- **Subnet selector terms omit `tags: null`.** The source emitted an explicit null
  alongside each `id`; it serialised to a YAML null that the API server discards.
- **`oss-controllers` gained a `depends_on` the `al2023` node class.** The source relied
  on the Helm release alone for ordering, which left this one pool with no dependency on
  the node class it references.
- **The source's unused `karpenter_min_instance_generation = 6` local is dropped.** It was
  dead there and would be dead here.
- **`oss-controllers` still has no `wait` / `wait_for_rollout`,** unlike every other pool.
  That asymmetry is inherited from the source and was left alone rather than quietly
  "fixed".

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| subnets | list(string) | _required_ | Subnet IDs Karpenter may launch nodes into. One `{ id = <subnet> }` selector term per element. Must be non-empty |
| cluster_name | string | _required_ | EKS cluster name. Keys both `securityGroupSelectorTerms` tag terms, the node class `tags`, and the default node role name. Must be non-empty |
| node_role_name | string | `null` → `"<cluster_name>-Managed-Node-Role"` | Bare IAM role **name** (not ARN) for launched nodes |
| chalk_dataplane_version | string | `null` | Exactly `"CHALK_DATAPLANE_VERSION_V2"` adds the `chalk-nap` pool. Any other value, including `null`, does not |

`chalk_dataplane_version` is an exact string comparison with no validation behind it,
matching the source. A near-miss value silently produces nine objects instead of ten
rather than failing — there is a test asserting exactly that, so the behaviour is pinned
rather than accidental.

## Outputs

| Name | Description |
|------|-------------|
| node_role_name | The role name actually used — the input, or the derived default |
| ec2_node_class_names | Names of the EC2NodeClass objects created |
| node_pool_names | Names of every NodePool created, sorted. Includes `chalk-nap` only on dataplane v2 |
| runtime_class_name | Name of the gVisor RuntimeClass, or `null` if the gVisor objects are off |
| chalk_nap_enabled | Whether the dataplane-v2 fallback pool was created |
| subnet_selector_terms | The selector terms rendered into every EC2NodeClass |
| max_cpu | Aggregate vCPU limit applied to every Chalk NodePool |
| boot_volume_size | Boot volume size on the `al2023` and `gvisor` node classes |
| offline_boot_volume_size | Boot volume size on the `al2023-offline-lssd` node class |
| cluster_name | Input echo of `var.cluster_name` |

These are derived from `local`s, not read back from `kubectl_manifest` attributes, because
`yaml_body` is sensitive at the schema level and any output reading it would have to be
`sensitive = true`.

## Tests

```bash
tofu init
tofu test
tofu fmt -check -recursive
```

`mock_provider "kubectl" {}` configures no provider and reaches no cluster, so the suite
needs no kubeconfig and no credentials.

| File | Covers |
|------|--------|
| `tests/manifests.tftest.hcl` | Every one of the ten objects, each with its **full** decoded manifest pinned |
| `tests/subnets.tftest.hcl` | Single and multiple subnets, order, and that all three node classes select the same set |
| `tests/dataplane.tftest.hcl` | The `chalk-nap` gate, including that enabling it changes nothing else |
| `tests/v1_only.tftest.hcl` | No `v1beta1` anywhere, no `amiFamily`, every `nodeClassRef` carries group + kind + name |
| `tests/requirements.tftest.hcl` | The workload / offline / compute / GPU requirement lists, field by field |
| `tests/node_role.tftest.hcl` | The derived default and an explicit override |
| `tests/validation.tftest.hcl` | Each input validation, one violation per run |

The whole-manifest pins in `tests/manifests.tftest.hcl` are the ones that matter. A
per-field suite passes when a field is *deleted*; a whole-manifest equality assertion does
not. If a pin fails after a deliberate change, read the diff and update the pin — do not
weaken the assertion.

The drift script's own behaviour (exit codes, argument handling, error paths) is exercised
against a `git` shim rather than a real repository, so it can be checked without network
or repository access.
