# Karpenter Chalk Standard Module

Terraform module that creates Chalk's **standard** set of Karpenter node resources — three
`EC2NodeClass` objects, six `NodePool` objects and one `RuntimeClass` — on an EKS cluster
that Chalk does **not** manage.

It creates one fixed, opinionated set of objects, not a generic node-pool builder. It takes
two required inputs, and everything else is fixed.

## Features

- All ten standard objects from one module. No nested modules, no sub-module calls.
- Karpenter **v1** schemas only (`karpenter.sh/v1`, `karpenter.k8s.aws/v1`).
- Two required inputs: `subnets` and `cluster_name`. The node role name is derived from
  the cluster name and is the only other thing a caller normally touches.
- Pool names, labels, taints, requirements, boot volume sizes, disruption policy and
  vCPU limits are all fixed at Chalk's standard values.
- Manifests are rendered from YAML template files, so the object that will be applied is
  readable as YAML in the repository rather than assembled by `yamlencode`.

## Why you need this on a cluster Chalk does not manage

On a Chalk-managed cluster these objects are created for you. On a self-managed cluster,
nothing creates them, and the Chalk UI cannot fill the gap:

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
  (1.x). Installing it is out of scope; see "What this module does not do".
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
| `NodePool` | `chalk-compute` | gVisor sandboxed compute, triple-tainted |
| `NodePool` | `chalk-compute-gpu` | NVIDIA g/p families, tainted `nvidia.com/gpu=true` |
| `RuntimeClass` | `gvisor` | `handler: runsc`, with the node selector and three tolerations that place a pod on `chalk-compute` |

Every `NodePool` except `oss-controllers` carries a 128000 vCPU limit and the
`chalk.ai/managed-by=chalk` taint.

## Why this module is not configurable

The values that define Chalk's standard shape are `local`s in `main.tf`, not variables:
`max_cpu`, `create_gvisor_nodeclass`, both boot volume sizes, the disruption policy, the
weights, and every requirement list.

That is the design, not an omission. Promoting them to inputs produces a generic
node-pool builder, and a generic node-pool builder cannot promise that a cluster matches
Chalk's standard shape — which is the only thing this module is for. Changing one of them
means editing this file, which puts the change through review.

If you need node pools that are *not* Chalk's standard set, declare them yourself against
the Karpenter CRDs rather than parameterising this module.

## Behaviour worth knowing

Things a reviewer is likely to ask about. All of them are deliberate.

### `subnets` is a `list(string)`, not selector terms

The module takes a plain list of subnet IDs and renders one `{ id = <subnet> }` term per
element into `subnetSelectorTerms`. It cannot select subnets by tag: that is not part of
Chalk's standard shape, and accepting arbitrary selector terms is precisely the generality
this module rejects.

### `disruption` and `expireAfter` are emitted explicitly

`consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter: 0s` and
`expireAfter: 720h` currently match the Karpenter CRD defaults, so a manifest that omitted
them would behave the same way today. They are emitted anyway, so that the applied object
states its own disruption behaviour instead of relying on server-side defaulting. The
practical effects: `kubectl get nodepool -o yaml` shows a real value rather than an
implicit one, and a future change to a CRD default cannot silently change how these pools
consolidate or expire.

`terminationGracePeriod: 30m` is **not** a CRD default and is load-bearing: Karpenter v1
leaves node draining unbounded without it, so one undrainable pod can block a rollout
indefinitely.

### `sensitive_fields = []` does less than it looks

Every `NodePool` sets `sensitive_fields = []` with the intent of showing the full spec diff
in plans rather than the provider default of redacting `spec`. On `alekc/kubectl` v2 that
argument controls redaction of `yaml_body_parsed` only; it does **not** make `yaml_body`
non-sensitive, because `yaml_body` is marked sensitive at the schema level regardless. So it
does not actually make the spec diff visible in a plan.

That is also why this module's outputs are derived from locals rather than read back out of
the resources: an output reading `yaml_body` would itself have to be `sensitive`. Before
removing `sensitive_fields`, confirm what it buys on the provider version in use — do not
remove it on the assumption that it is decorative.

### Other behaviour

- **Karpenter v1 only.** There is no way to render a v1beta1 manifest.
- **The GPU pool is always created.** It is not gated on any input.
- **`amiFamily` is never emitted.** The v1 `amiSelectorTerms` alias `al2023@latest`
  already implies the family.
- **`upgrade_api_version = true`** on every node class and pool.
- **Every `NodePool` declares an explicit dependency** on the node class it references, so
  a fresh apply does not briefly leave a pool pointing at a `nodeClassRef` that does not
  resolve yet.
- **`oss-controllers` is applied without `wait` / `wait_for_rollout`,** unlike every other
  pool, so an apply does not block on it.

## What this module does not do

It manages node *shape* only. Out of scope, on purpose:

- **The Karpenter controller and its CRDs.** No Helm releases are created here.
- **The controller's IAM.** No IRSA role, policy document, policy or attachment.
- **Spot-interruption handling.** No SQS queue, no queue policy, and none of the
  CloudWatch event rules or targets that feed it.

Installing and empowering the Karpenter controller stays with the cluster's owner, who
already has an opinion about how IAM is managed in their account. Every input those
resources would have needed is absent too, which is what keeps the boundary clean.

Two further things this module does not do:

- **It does not install the NVIDIA device plugin.** Without a device-plugin DaemonSet
  that tolerates `nvidia.com/gpu`, nodes from `chalk-compute-gpu` never advertise the
  `nvidia.com/gpu` resource, and nothing schedules on them.
- **It grants nothing in IAM.** `node_role_name` names a role that must already exist and
  already be mapped in the cluster's auth configuration.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| subnets | list(string) | _required_ | Subnet IDs Karpenter may launch nodes into. One `{ id = <subnet> }` selector term per element. Must be non-empty |
| cluster_name | string | _required_ | EKS cluster name. Keys both `securityGroupSelectorTerms` tag terms, the node class `tags`, and the default node role name. Must be non-empty |
| node_role_name | string | `null` → `"<cluster_name>-Managed-Node-Role"` | Bare IAM role **name** (not ARN) for launched nodes |

`subnets`, `cluster_name` and `node_role_name` are the entire input surface. Everything
else — pool names, labels, taints, requirements, volume sizes, the vCPU ceiling — is a
`local` in `main.tf`, so changing one goes through review rather than through a caller's
`.tfvars`.

## Outputs

| Name | Description |
|------|-------------|
| node_role_name | The role name actually used — the input, or the derived default |
| ec2_node_class_names | Names of the EC2NodeClass objects created |
| node_pool_names | Names of every NodePool created, sorted |
| runtime_class_name | Name of the gVisor RuntimeClass, or `null` if the gVisor objects are off |
| subnet_selector_terms | The selector terms rendered into every EC2NodeClass |
| max_cpu | Aggregate vCPU limit applied to every Chalk NodePool |
| boot_volume_size | Boot volume size on the `al2023` and `gvisor` node classes |
| offline_boot_volume_size | Boot volume size on the `al2023-offline-lssd` node class |
| cluster_name | Input echo of `var.cluster_name` |

These are derived from `local`s, not read back from `kubectl_manifest` attributes, because
`yaml_body` is sensitive at the schema level and any output reading it would have to be
`sensitive = true`.
