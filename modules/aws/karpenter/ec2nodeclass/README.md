# AWS Karpenter EC2NodeClass Module

Terraform module that renders and applies one Karpenter **v1** `EC2NodeClass` to an existing EKS
cluster. It exists so that a Chalk customer running their own EKS cluster can create the node
resources Chalk Resources V2 expects — and in particular can pin a machine family — without
hand-authoring CRDs.

The node class owns **subnets, AMI selection, the node IAM role, IMDS options, the root volume and
instance tags**. Scheduling — requirements, taints, limits, weight, disruption — belongs to a
`NodePool`, which is a separate module that consumes this one's `name` output.

## Features

- One `EC2NodeClass` at `apiVersion: karpenter.k8s.aws/v1`, applied with `kubectl_manifest`
- `subnetSelectorTerms` as a first-class, validated input in Karpenter's **native term shape**, so
  both explicit subnet IDs and `karpenter.sh/discovery` tag discovery are expressible
- AMI selection by `alias` (`family@version`), which implies `amiFamily` — so `amiFamily` is never
  emitted
- IMDSv2 enforced (`httpTokens: required`, `httpPutResponseHopLimit: 2`, IPv6 disabled)
- A gp3 `/dev/xvda` root volume that is deleted on termination, defaulting to `50Gi`
- `userData` carrying a `node.eks.aws/v1alpha1` `NodeConfig` that disables kubelet's image-pull rate
  limit
- The manifest body is a **template file** rendered with `templatefile()`, so the YAML is the
  reviewable artefact and a caller can substitute their own file
- An opt-in **YAML input mode**: hand the module a real `EC2NodeClass` document and it overrides
  only the fields that cannot be portable between clusters, emitting the rest verbatim
- A `name` output derived from the applied resource, which is what orders a consuming `NodePool`
  after the node class exists
- Heavy plan-time input validation, and a credential-free test suite that needs no cluster

## Requirements

| Name | Version |
|------|---------|
| kubectl provider (`alekc/kubectl`) | `~> 2.3` |

Karpenter **v1.x must already be running** on the target cluster. This module creates node
resources only; it does not install the Karpenter controller, its CRDs, its IRSA role, its SQS
interruption queue or its EventBridge rules.

The `~> 2.3` floor is functional rather than stylistic. The `kubectl_manifest` **data source** that
the companion `nodepool` module reads is absent from the provider at v2.1.6 and v2.2.0 and present
at v2.3.0, so the looser house pin of `>= 2` would permit a version in which that module cannot
work. Both modules in this family pin identically.

The 2.x line is also deliberate. The provider's `main`-branch documentation describes an
**unreleased** v3 (beta only) in which the data source gains a `wait_for` block and `yaml_incluster`
is replaced by a `drift` attribute. Do not design against it.

## Usage

### Basic — explicit subnet IDs

```hcl
module "karpenter_nodeclass" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/ec2nodeclass?ref=v0.3.0"

  cluster_name   = "example-cluster"
  node_role_name = "example-cluster-Managed-Node-Role"

  subnet_selector_terms = [
    { id = "subnet-xxxxx" },
    { id = "subnet-yyyyy" },
    { id = "subnet-zzzzz" },
  ]
}
```

All three inputs are required. `node_role_name` is the node IAM role **name**, not an ARN.

### Subnet discovery by tag

```hcl
  subnet_selector_terms = [
    { tags = { "karpenter.sh/discovery" = "example-cluster" } },
  ]
```

### Pinning an AMI version, a larger root volume, and local NVMe

```hcl
module "karpenter_nodeclass_gpu" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/ec2nodeclass?ref=v0.3.0"

  name           = "al2023-nvme"
  cluster_name   = "example-cluster"
  node_role_name = "example-cluster-Managed-Node-Role"

  subnet_selector_terms = [{ tags = { "karpenter.sh/discovery" = "example-cluster" } }]

  # Pin the AMI rather than tracking @latest -- see "AMI selection" below.
  ami_alias             = "al2023@v20240807"
  boot_volume_size      = "200Gi"
  instance_store_policy = "RAID0"

  tags = {
    Environment = "production"
  }
}
```

### Feeding a NodePool — the seam

```hcl
module "pool_online" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/nodepool?ref=v0.3.0"

  name              = "online-c7a"
  ec2nodeclass_name = module.karpenter_nodeclass.name

  # ...scheduling inputs...
}
```

Or hand the pool the whole reference and never write the group/kind pair yourself:

```hcl
  node_class_ref = module.karpenter_nodeclass.node_class_ref
```

## Why subnets live here and not on the pool

Karpenter v1's `NodePool` `spec.template.spec` has exactly six fields — `nodeClassRef`, `taints`,
`startupTaints`, `expireAfter`, `terminationGracePeriod`, `requirements` — and **no subnet selector
of any kind**. Subnets are exclusively an `EC2NodeClass` concern, and the upstream documentation
states the consequence directly: to give different NodePools different subnets, you create distinct
EC2NodeClasses.

So: instantiate this module **once per subnet set**, and the pool module once per scheduling shape.
Several pools sharing one node class share its subnets, which is the intended arrangement.

To confine one pool to a **subset** of the node class's subnets, do not look for a subnet input on
the pool — add a zone requirement instead:

```hcl
  { key = "topology.kubernetes.io/zone", operator = "In", values = ["us-west-2a"] }
```

Karpenter then selects a subnet in the target zone, preferring the one with the most free IP
addresses.

## `subnetSelectorTerms`

The input mirrors Karpenter's own term shape:

```hcl
list(object({
  id   = optional(string)
  tags = optional(map(string))
}))
```

Rather than a `list(string)` of subnet IDs, because a flat list can only ever express the `id` form
and so can never express tag discovery. Both forms are first-class here and can be mixed in one
list.

Semantics, which the module does not change:

- **Terms are ORed.** Any matching term is enough.
- **Conditions inside one term are ANDed.** A two-key `tags` map is one term requiring both tags,
  not two terms.
- Tag values accept `*` wildcards, and an empty tag value matches any value for that key.
- `id` and `tags` are the only keys Karpenter accepts here. There is no `name`, unlike
  `securityGroupSelectorTerms`.

The module validates that each term sets **exactly one** of `id` or a non-empty `tags` map. That is
a structural assumption of the bundled template, which branches on it, and not merely a restatement
of the CRD schema. `id` is checked for a `subnet-` prefix and a non-empty remainder — deliberately
loose, since AWS has already lengthened resource IDs once, but tight enough to catch the common
paste error of a `vpc-` or `sg-` ID.

## AMI selection

`ami_alias` renders `spec.amiSelectorTerms[0].alias` as `family@version`. Accepted families are
`al2`, `al2023`, `bottlerocket`, `windows2019` and `windows2022`. Ubuntu is **not** an alias family
in Karpenter v1; it must be selected with an `id`, `name` or `ssm` term, which means substituting
your own manifest template.

An alias is mutually exclusive with the other term forms and **implies `amiFamily`**, which is why
this module never emits `amiFamily`. The captured customer node class this module was built against
omits it for the same reason.

> **`@latest` drifts.** The default is `al2023@latest`, which follows Chalk's current behaviour, but
> every AMI release then drifts the node class and Karpenter replaces every node in every pool that
> references it. In production, pin a dated version.

## What the module deliberately does not emit

Fields Karpenter already defaults are left to the API server. The module emits only what the caller
actually chose, so the manifest stays a record of decisions and does not produce diff noise against
a cluster where the API server supplied the same values itself.

Concretely: no `amiFamily` (implied by the alias), no `instanceStorePolicy` unless set, no `kubelet`
block, no `metadata.labels`, no `metadata.annotations` and no `metadata.namespace` — `EC2NodeClass`
is cluster-scoped.

Two `kubectl_manifest` provider arguments used by Chalk's internal stack are also deliberately
**not** set here, having been checked against the pinned 2.x line rather than copied:

| Argument | Why not |
|---|---|
| `wait_for_rollout` | Applies only to `Deployment`, `DaemonSet`, `StatefulSet` and `APIService`. A no-op for a custom resource, so setting it would imply a guarantee that is absent. |
| `sensitive_fields` | The documented 2.x default is `["data"]`, and only for Secrets. An `EC2NodeClass` carries no secret material. |

The module **does** set `timeouts { delete = "45m" }`. Karpenter puts a finalizer on an
`EC2NodeClass` and holds the delete until every `NodeClaim` referencing it has drained, which is
bounded by the pools' `terminationGracePeriod` rather than by anything Terraform controls.

## The `name` output is the dependency edge

```hcl
# outputs.tf
output "name" {
  value = kubectl_manifest.this.name   # correct
  # value = var.name                   # WRONG
}
```

Both forms render the identical string — the provider exports `name` as the object name extracted
from `yaml_body`. Only the first puts an **edge in the dependency graph**. Read from `var.name`, a
consuming `NodePool` depends on nothing, Terraform is free to create it first, and it fails against
a node class that does not exist yet.

The defect is invisible in the rendered YAML and shows up only as a race, so
`tests/baseline.tftest.hcl` asserts the derivation directly, in the run
`name_output_derives_from_the_applied_resource`.

## Instance tags

`spec.tags` is applied to every EC2 instance the node class launches. The module always contributes
`karpenter.sh/discovery = <cluster_name>` and merges `var.tags` **over** it, so a caller-supplied
key of the same name wins. With no caller tags, `spec.tags` is exactly the discovery tag.

Keys are validated at 128 characters and values at 256, the AWS limits.

## YAML input mode

Set `manifest_yaml` to a complete `EC2NodeClass` document and the module switches from rendering a
template to **merging into your document**. The rule, stated once:

> In YAML mode the module overrides only what cannot be portable between clusters. Everything else
> in the caller's document is emitted unchanged.

The intended use is lift-and-shift: take the node class a cluster already runs, and stand it up on
another cluster's subnets, security groups and node role without rewriting it as module inputs.

```hcl
module "karpenter_nodeclass" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/ec2nodeclass?ref=v0.3.0"

  manifest_yaml = file("${path.root}/nodeclass.yaml")

  # Only the cluster-bound fields. Everything else comes from the document.
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }, { id = "subnet-yyyyy" }]
}
```

There is deliberately **no second path variable**. You already hold the document, so
`file("${path.root}/nodeclass.yaml")` covers the file case without this module guessing a base
directory. `manifest_yaml` and `manifest_path` select different modes and setting both is an error.

### What is overridden

Each override applies **only when its input is non-null**. Leave an input out and the document's own
value survives — that is the whole point, not a fallback.

| Document path | Overridden from | When |
|---|---|---|
| `metadata.name` | `var.name` | `name != null` |
| `spec.role` | `var.node_role_name` | `node_role_name != null` |
| `spec.subnetSelectorTerms` | `var.subnet_selector_terms`, **replaced wholesale** | `subnet_selector_terms != null` |
| `spec.securityGroupSelectorTerms` | the two tag terms derived from `var.cluster_name` | `cluster_name != null` |
| `spec.tags` | `{ karpenter.sh/discovery = cluster_name }` + `var.tags`, merged **over** the document's tags | either is non-empty |

`subnetSelectorTerms` is replaced and not merged because subnet selection is a single decision: a
half-overridden term list would select subnets from two different clusters.

`spec.tags` is the one field that merges rather than replaces, so a document's own tags survive
alongside the discovery tag. A document that carried no `spec.tags` and gets no override does not
acquire an empty `tags: {}` — emitting a key you never wrote is not emitting it unchanged.

### What is untouched

`amiSelectorTerms`, `blockDeviceMappings`, `metadataOptions`, `instanceStorePolicy`, `userData` and
anything else the document carries are emitted verbatim. None of them is cluster-bound, so the
module has no business having an opinion about them here — including its own template-mode opinions.
A document that permits IMDSv1 keeps permitting IMDSv1.

### Inputs YAML mode cannot act on are rejected

`ami_alias`, `boot_volume_size`, `instance_store_policy` and `manifest_path` are template-only.
Setting any of them alongside `manifest_yaml` **fails at plan** rather than being silently dropped.
Silence is the dangerous outcome: nothing about the applied object would tell a caller who passed
`boot_volume_size = "50Gi"` that their document's `200Gi` is what actually shipped.

Every optional input defaults to `null` for this reason — with a non-null default, "did the caller
set this?" is unanswerable, and the module could not tell an ignored input from an unset one. The
real template-mode defaults (`al2023`, `al2023@latest`, `50Gi`) are resolved in `locals`, so
template-mode output is byte-identical to what it was before this mode existed.

### The document is validated structurally

Rejected at plan, with a distinct message for each: a document that is not parseable YAML; one that
decodes to a scalar or a sequence rather than a mapping; a missing or non-`EC2NodeClass` `kind`; a
missing `apiVersion`; a **`v1beta1`** group — called out on its own because it is the likely paste,
and because the v1beta1 schema needs converting rather than relabelling; and a missing `spec`.

### Comments and key order are lost

YAML mode decodes your document, merges into the result and re-encodes it with `yamlencode()`. That
round trip drops **comments and your key order**, and normalises quoting. Values survive intact —
including multi-line `userData` block scalars — but the applied YAML will not look like the file you
wrote.

This is inherent to merging into a parsed document, and it is why **template mode remains the
default and the reviewable-artefact path**. If the diff a reviewer sees matters more than reusing an
existing document, use `manifest_path` instead.

## Substituting your own manifest template

The manifest body is rendered from `templates/ec2nodeclass.yaml.tftpl` with `templatefile()` rather
than being `yamlencode`d out of an HCL map, and `subnetSelectorTerms` is generated **inside** the
template with a `%{ for ~}` directive. Point `manifest_path` at your own file to render an exotic
node class — an `ssm` AMI term, a second block device, a `kubelet` block — while keeping this
module's validation, naming and output contract.

`manifest_path` is **template mode only** and is mutually exclusive with `manifest_yaml`. Reach for
it when you want a rendered, reviewable artefact parameterised by this module's inputs; reach for
`manifest_yaml` when you already have a finished document you want to keep.

The template receives exactly these variables:

| Template variable | Source |
|---|---|
| `name` | `var.name`, or `al2023` when null |
| `ami_alias` | `var.ami_alias`, or `al2023@latest` when null |
| `node_role_name` | `var.node_role_name` |
| `cluster_name` | `var.cluster_name` |
| `subnet_selector_terms` | `var.subnet_selector_terms` |
| `boot_volume_size` | `var.boot_volume_size`, or `50Gi` when null |
| `instance_store_policy` | `var.instance_store_policy` |
| `tags` | `var.tags` merged over the default discovery tag |

The three defaults are resolved in `locals` rather than on the variables, so that YAML mode can tell
a caller-set value from an unset one. A substituted template sees the resolved value, exactly as the
bundled one does.

Every interpolation in the bundled template goes through `jsonencode()`. JSON is a subset of YAML,
so that quotes and escapes caller-supplied strings correctly without hand-rolling YAML escaping
rules; a tag value containing `:`, `#` or quotes round-trips intact.

## Testing

```bash
cd modules/aws/karpenter/ec2nodeclass
tofu init
tofu test
tofu test -filter=tests/subnet_selector_terms.tftest.hcl
```

The suite uses `mock_provider "kubectl" {}`, so it configures no provider and makes no cluster
calls: **no kubeconfig, no cluster and no AWS credentials are needed.** Every run is
`command = plan`.

| File | Covers |
|---|---|
| `tests/baseline.tftest.hcl` | API version, defaults, fields that must be absent, the output seam, the fixed manifest content |
| `tests/subnet_selector_terms.tftest.hcl` | `subnet_selector_terms`, single / multi / mixed, good and bad |
| `tests/identifiers.tftest.hcl` | `cluster_name`, `node_role_name`, `name`, including length boundaries |
| `tests/ami_and_disk.tftest.hcl` | `ami_alias`, `boot_volume_size`, `instance_store_policy`, `tags`, `manifest_path` |
| `tests/fixtures.tftest.hcl` | Structural replay of the captured customer node class in `tests/fixtures/` |
| `tests/manifest_yaml.tftest.hcl` | YAML mode: mode selection, document decoding and structure, each override, each inheritance, passthrough, rejected inputs, template-mode requiredness, and the captured node class fed back in as a document |

Three conventions the suite follows, each for a reason worth knowing before editing it:

- **Assert on `yamldecode(output.rendered_manifest)`, never on the raw string.** `templatefile`
  output is whitespace- and key-order-sensitive, so string matching fails the suite on cosmetic
  edits.
- **Exactly one violation per negative run.** `expect_failures` proves *rejection*, not which rule
  fired — it does not match on `error_message`, and these variables carry several validation blocks
  each. The module's charset and length rules are kept disjoint for the same reason.
- **Every negative value is correctly typed.** `expect_failures` catches only custom validation
  conditions; a type mismatch errors the test instead of passing it.
- **Two failure addresses, and the difference is not cosmetic.** Shape rules are `validation` blocks
  and fail at `var.<name>`. Every cross-variable rule — mode selection, template-mode requiredness,
  and the rejection of template-only inputs in YAML mode — is a `lifecycle` precondition on
  `kubectl_manifest.this` and fails at that address, because a `validation` block may only reference
  the variable it is attached to.

Optionality is asserted through the rendered manifest with `!can(...)` rather than through a
resource attribute, because `mock_provider` fabricates a value for every computed attribute — an
`attribute == null` assertion fails against correct code.

## Inputs

Every input defaults to `null` except `tags`. Requiredness is **per mode** and therefore cannot be
expressed as an absent default — a Terraform variable is required or optional module-wide — so the
three template-mode requirements are enforced as `lifecycle` preconditions and fail at plan with the
module's own message rather than as Terraform's `No value for required variable`.

| Name | Type | Default | Template mode | YAML mode | Description |
|------|------|---------|---------------|-----------|-------------|
| subnet_selector_terms | list(object({ id = optional(string), tags = optional(map(string)) })) | `null` | **required** | optional override | Karpenter `spec.subnetSelectorTerms`, verbatim. Each term must set exactly one of `id` or a non-empty `tags` map. At least one term. In YAML mode it replaces the document's terms wholesale. |
| cluster_name | string | `null` | **required** | optional override | EKS cluster name. Feeds both `securityGroupSelectorTerms` and the default discovery tag. 1–100 characters, starting alphanumeric. |
| node_role_name | string | `null` | **required** | optional override | Node IAM role **name**, not an ARN. 1–64 characters from `[A-Za-z0-9_+=,.@-]`. |
| name | string | `null` | optional, renders `al2023` | optional override | `metadata.name` of the EC2NodeClass. Lowercase RFC 1123 label, at most 63 characters. |
| tags | map(string) | `{}` | optional | merged over the document's tags | Extra instance tags, merged over the default `karpenter.sh/discovery = cluster_name`. Keys ≤ 128 chars, values ≤ 256. |
| manifest_yaml | string | `null` | — | **selects YAML mode** | A complete `EC2NodeClass` document. Mutually exclusive with `manifest_path`. Validated structurally; comments and key order are lost on re-encode. |
| ami_alias | string | `null` | optional, renders `al2023@latest` | **rejected** | `spec.amiSelectorTerms[0].alias`, as `family@version`. Implies `amiFamily`. |
| boot_volume_size | string | `null` | optional, renders `50Gi` | **rejected** | `volumeSize` of the gp3 `/dev/xvda` root volume, as a unit-suffixed Kubernetes quantity. |
| instance_store_policy | string | `null` | optional | **rejected** | `spec.instanceStorePolicy`. `RAID0` or null. Omitted from the manifest when null. |
| manifest_path | string | `null` | optional | **rejected** | Path to the manifest template. Null uses the template bundled with this module. |

## Outputs

| Name | Description |
|------|-------------|
| name | `metadata.name` of the **applied** EC2NodeClass. Feed this to a NodePool; the value carries the ordering dependency. |
| node_class_ref | `{ group, kind, name }` — a drop-in for a NodePool's `spec.template.spec.nodeClassRef`. |
| uid | `metadata.uid` assigned by the API server. |
| id | Terraform resource ID of the applied manifest; useful as an explicit `depends_on` target. |
| rendered_manifest | The YAML exactly as submitted: the rendered template in template mode, `yamlencode()` of the merged document in YAML mode. Parse it with `yamldecode`; do not match the string. |
