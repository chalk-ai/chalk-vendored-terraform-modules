# AWS Karpenter NodePool Module

Terraform module for creating one Karpenter **v1** `NodePool` on an EKS cluster that already runs
Karpenter v1.x. It is the scheduling half of a pair: `modules/aws/karpenter/ec2nodeclass` owns the
subnets, AMI and node role, and this module owns requirements, limits, taints, labels, weight and
disruption. Instantiate the node class once and this module once per pool.

There are two ways to describe the pool. **Template mode** is the default: pass typed inputs and the
module renders the manifest from a template. **YAML mode** is opt-in: pass a finished NodePool
document as `manifest_yaml` and the module emits it with only the two cluster-specific names
overridden. See [Input modes](#input-modes).

## Features

- Renders exactly one `karpenter.sh/v1` `NodePool` from a template file, applied with
  `kubectl_manifest`
- Optional **YAML mode**: hand the module a finished NodePool document and it overrides only
  `metadata.name` and `spec.template.spec.nodeClassRef.name`, emitting everything else verbatim
- Emits the v1 `nodeClassRef` triple (`group`, `kind`, `name`) so a caller never hand-writes the
  group/kind pair that Karpenter v1.1.0 made mandatory
- Optional plan-time read of the referenced `EC2NodeClass`, so a missing node class fails the plan
  instead of the apply
- `requirements` is caller-supplied and free-form; `limits` is keyed by arbitrary resource name
- Plan-time `validation` for every cheap, stable CRD constraint, and a `precondition` for the one
  rule that spans two inputs
- Emits **nothing** that Karpenter already defaults, so the manifest holds only what the caller chose
- `rendered_manifest` output, known at plan time, so the YAML is reviewable and assertable

## Requirements

| Name | Version |
|------|---------|
| kubectl provider (`alekc/kubectl`) | `~> 2.3` |

The floor is functional, not stylistic. The `kubectl_manifest` **data source** that
`lookup_ec2nodeclass` depends on is absent from the provider at v2.1.6 and v2.2.0 and first ships in
v2.3.0. The commonly used pin `>= 2` would resolve to a version in which this module does not work.

The module assumes Karpenter v1.x is already installed on the cluster. It does not manage the
controller, the CRDs, the IRSA role, the SQS interruption queue or the EventBridge rules.

## Usage

### One node class, two pools

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

# General-purpose pool.
module "pool_default" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/nodepool?ref=v0.3.0"

  name              = "default-al2023"
  ec2nodeclass_name = module.karpenter_nodeclass.name # <- the seam

  requirements = [
    { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
    { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
  ]

  limits = { cpu = "1000" }
  weight = 12
}

# Latency-sensitive pool pinning a machine family, against the same node class.
module "pool_c7a" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/nodepool?ref=v0.3.0"

  name              = "online-c7a"
  ec2nodeclass_name = module.karpenter_nodeclass.name

  requirements = [
    { key = "karpenter.k8s.aws/instance-family", operator = "In", values = ["c7a"] },
    { key = "karpenter.k8s.aws/instance-hypervisor", operator = "In", values = ["nitro"] },
    { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
    { key = "karpenter.sh/capacity-type", operator = "In", values = ["on-demand"] },
  ]

  limits = { cpu = "500", memory = "5000Gi" }
  taints = [{ key = "chalk.ai/managed-by", value = "chalk", effect = "NoSchedule" }]
  weight = 20
}
```

### Against a node class you already have

`ec2nodeclass_name` takes a literal name just as happily, so a cluster that already has an `al2023`
node class can get pools without adopting the node class module:

```hcl
module "pool_default" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/nodepool?ref=v0.3.0"

  name              = "default-al2023"
  ec2nodeclass_name = "al2023"
}
```

### Narrowing a pool to a subset of the node class's subnets

There is no subnet input here, and that is a property of the v1 API rather than an omission:
`spec.template.spec` has no subnet selector of any kind, and subnets belong exclusively to the
`EC2NodeClass`. To confine a pool to part of its node class's subnets, add a zone requirement — the
node class module's subnets are then filtered to that zone:

```hcl
  requirements = [
    { key = "topology.kubernetes.io/zone", operator = "In", values = ["us-west-2a"] },
  ]
```

To give two pools genuinely *different* subnets, create two `EC2NodeClass`es.

## Input modes

`manifest_yaml` selects the mode. It defaults to `null`, so nothing below changes an existing caller.

| `manifest_yaml` | `manifest_path` | Mode | Manifest comes from |
|---|---|---|---|
| `null` | `null` | template | the template bundled with this module |
| `null` | set | template | your template, rendered with the module's inputs |
| set | `null` | **YAML** | your document, with two names overridden |
| set | set | — | **error**: they select different modes |

There is no companion path variable for YAML mode. The caller supplies the document, so reading it
from disk is the caller's job:

```hcl
module "pool_default" {
  source = "git::https://github.com/chalk-ai/chalk-vendored-terraform-modules.git//modules/aws/karpenter/nodepool?ref=v0.3.0"

  manifest_yaml = file("${path.root}/nodepool.yaml")

  # The two names this module owns. Both optional -- omit either to keep the document's own value.
  name              = "example-pool"
  ec2nodeclass_name = module.karpenter_nodeclass.name
}
```

with `nodepool.yaml` alongside your root module:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: placeholder-overridden-by-the-module
spec:
  disruption:
    budgets:
      - nodes: 10%
    consolidateAfter: 0s
    consolidationPolicy: WhenEmptyOrUnderutilized
  limits:
    cpu: "500"
    memory: 5000Gi
  template:
    metadata:
      labels:
        example.com/managed-by: terraform
    spec:
      expireAfter: 720h0m0s
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: placeholder-overridden-by-the-module
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values:
            - on-demand
        - key: kubernetes.io/arch
          operator: In
          values:
            - amd64
      taints:
        - effect: NoSchedule
          key: example.com/managed-by
          value: terraform
  weight: 20
```

### What YAML mode overrides, and why so little

> In YAML mode the module overrides only what cannot be portable between clusters. Everything else in
> your document is emitted unchanged.

| Document path | Overridden from | When |
|---|---|---|
| `metadata.name` | `name` | only when `name` is non-null |
| `spec.template.spec.nodeClassRef.name` | `ec2nodeclass_name` | only when `ec2nodeclass_name` is non-null |

That is the whole set, and the thinness is the point rather than an oversight. Requirements, limits,
taints, labels, weight and disruption all mean the same thing on every cluster, so a document
carrying them moves between clusters unchanged. A NodePool's *name* and the *node class it points
at* are the two things that do not: the node class is per-cluster, and two pools in one cluster
cannot share a name. Leave either input `null` and the document's own value stands.

`lookup_ec2nodeclass` keeps working. The name it reads is `ec2nodeclass_name` when set, otherwise the
document's own `nodeClassRef.name`. If neither yields a name and the lookup is on, the plan fails
saying so; set `lookup_ec2nodeclass = false` if that is intentional.

### Inputs YAML mode would ignore are rejected

Your document is authoritative for everything outside the override set, so `requirements`, `limits`,
`taints`, `labels`, `weight`, `disruption`, `expire_after`, `termination_grace_period` and
`manifest_path` have no effect in YAML mode. Setting any of them **fails the plan** rather than being
silently dropped, and the message names which ones. Put those values in the document instead.

This is why every optional input on this module defaults to `null`, including the collections: an
empty list is indistinguishable from "the caller set nothing", and the rejection needs that
distinction. The real template-mode defaults (`[]` and `{}`) are resolved internally, so template
mode renders exactly what it always did.

### What YAML mode checks about your document

Each of these fails the plan with its own message: the value is not parseable YAML; it decodes to a
scalar or a sequence rather than a mapping; `kind` is absent or is not `NodePool`; `apiVersion` is
absent; `apiVersion` names a **v1beta1** group; `spec` is absent.

The v1beta1 case is called out separately because it is the likely paste — a pool copied from a
pre-v1 cluster or from v1beta1-era documentation. It is not merely a rename: `nodeClassRef` takes
`group`/`kind`/`name` instead of `apiVersion`/`kind`/`name`, `consolidationPolicy:
WhenUnderutilized` became `WhenEmptyOrUnderutilized`, and kubelet configuration moved to the
`EC2NodeClass`. Convert the document before passing it.

Everything else is forwarded to the API server unvalidated, in line with the module's policy of not
second-guessing what Karpenter may add later.

### YAML mode does not preserve comments or key order

The module decodes your document, applies the two overrides and re-encodes it with `yamlencode`.
Comments and key order are lost — that is inherent to any decode/merge/emit path, not a defect that
can be fixed here. `terraform plan` will therefore show a manifest that is semantically your document
but textually reordered and stripped of comments.

If the reviewable artefact matters more than authoring real YAML, stay in template mode: that is why
it remains the default. If it does not, YAML mode is the shorter path for a pool you already have.

## The seam: literal name versus module reference

`ec2nodeclass_name` accepts both forms and they behave differently on purpose.

| `ec2nodeclass_name` is… | The `lookup_ec2nodeclass` read happens | A missing node class surfaces as |
|---|---|---|
| `module.karpenter_nodeclass.name` | deferred to **apply** — the data source configuration directly depends on a resource that is changing in the current plan | cannot happen: the dependency edge orders the pool after the node class |
| a literal string | at **plan** | a plan-time error, fail-fast |

The ordering guarantee in the first row exists only because the node class module's `name` output is
read off the applied resource rather than echoed from its input variable. Both forms produce the
identical string; only one creates a graph edge. This module's own `name` output follows the same
rule for the same reason.

Because the deferral is a property of the *caller's* dependency graph, it is not unit-testable with
`mock_provider` and the test suite does not pretend otherwise. What the suite does assert is that the
data source is in the plan when `lookup_ec2nodeclass` is true and out of it when false.

### When to set `lookup_ec2nodeclass = false`

The literal path is also the one that breaks. If the node class is created **elsewhere in the same
root module** — by a raw `kubectl_manifest`, a Helm chart, or anything else Terraform applies in the
same run — it does not exist yet when the data source reads at plan time, and the 2.x data source has
no `wait_for` to absorb that. Set `lookup_ec2nodeclass = false` to opt out of the read.

## What this module deliberately does not emit

`disruption` and `expire_after` default to `null` and produce no keys in the manifest at all. That is
not laziness: `consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter: 0s`,
`budgets: [{nodes: 10%}]` and `expireAfter: 720h` are all **Karpenter defaults**. Restating them
would write server-supplied values into your configuration and generate diff noise against every
cluster where the API server supplied them itself.

`terminationGracePeriod` is the mirror image and has **no** Karpenter default. Left unset, a
misconfigured PDB or a pod carrying `karpenter.sh/do-not-disrupt` can block draining indefinitely.
Maximum node lifetime is `expire_after` plus `termination_grace_period`.

## Validity rules

Every rule below is enforced server-side by the Karpenter CRD regardless of what this module does.
The module restates the cheap, stable, documented ones so you get plan-time feedback instead of a
mid-apply API rejection, and each `validation` block cites the upstream marker it mirrors. Anything
Karpenter might reasonably loosen later is forwarded unvalidated — a module that rejects a
newly-added operator would be worse than one that lets the API server decide.

Several of these are counterintuitive:

| Rule | Detail |
|---|---|
| Operators | Eight, not four: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`, **`Gte`**, **`Lte`** |
| `In` | Requires a non-empty `values` |
| `Exists` / `DoesNotExist` | Require an **empty** `values` |
| `Gt` / `Lt` / `Gte` / `Lte` | Require **exactly one** value that parses as a non-negative integer |
| `minValues` | 1–50, and never greater than the length of its own `values` |
| `requirements` | At most 100 entries — **and `labels` count toward the same 100** |
| `weight` | 1–100. Omitting it means "treated as 0"; an explicit `0` is **rejected** |
| `consolidationPolicy` | `WhenEmpty`, `WhenEmptyOrUnderutilized`, `Balanced`. `WhenUnderutilized` is the v1beta1 value and is invalid in v1 |
| `expire_after`, `consolidateAfter` | `s`/`m`/`h` components, or the literal `Never` |
| `termination_grace_period` | `s`/`m`/`h` components — it does **not** accept `Never` |
| `budgets[].nodes` | A whole number or `0%`–`100%`; `101%` is rejected |
| `budgets[].schedule` / `.duration` | Set both or neither |
| `budgets[].duration` | Hours and minutes only — `30s` is rejected, unlike the two duration fields above |
| `budgets[].reasons` | `Underutilized`, `Empty`, `Drifted` |
| `budgets`, `taints` | At most 50 entries each |
| Taint `effect` | `NoSchedule`, `PreferNoSchedule`, `NoExecute` — from Kubernetes, not Karpenter |

### `limits` is a map, not a triple

`spec.limits` is keyed by resource name and Karpenter accepts arbitrary names, so this input is
`map(string)`:

```hcl
  limits = {
    cpu              = "500"
    memory           = "5000Gi"
    "nvidia.com/gpu" = "2"
    nodes            = "10"
  }
```

Values are Kubernetes quantities and are always rendered as YAML strings, so `1k` stays `"1k"` and
`500` stays `"500"` rather than being coerced to a number by the YAML parser.

### `labels` share the `requirements` budget

Labels propagate onto every NodeClaim as requirements, so `length(requirements) + length(labels)`
must be at most 100. This is the one rule that spans two inputs and therefore cannot be a
`validation` block; it is a `precondition` on the manifest resource, and it fails the plan naming
both counts. In YAML mode it counts the **document's** requirements and labels, not the (null)
inputs, so the cap holds either way.

## Rendering

In template mode the manifest comes from `templates/nodepool.yaml.tftpl` via `templatefile()` rather
than from `yamlencode`, which keeps the manifest a reviewable artefact. Set `manifest_path` to
substitute your own template; it must accept the same variables as the bundled one. The path is
resolved against the process working directory, not the module directory.

In YAML mode the manifest is `yamlencode()` of your decoded document with the two overrides applied.
See [YAML mode does not preserve comments or key order](#yaml-mode-does-not-preserve-comments-or-key-order).

### `name` and `ec2nodeclass_name` are required per mode, not module-wide

A Terraform variable is required or optional module-wide; there is no per-mode requiredness. So both
default to `null`, and "required in template mode" is a `precondition` on the manifest resource
rather than a missing default.

Behaviour is unchanged — omitting `name` in template mode still fails the plan — but the **error
surface** differs. It used to be Terraform's own `No value for required variable`; it is now this
module's message, raised when the resource is planned. Shape checks (the DNS-1123 pattern and the
rest) are still `validation` blocks on the variables, because a `validation` block may only reference
its own variable.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| name | string | `null` | `metadata.name` of the NodePool. A DNS-1123 label, at most 63 characters. **Required in template mode**; in YAML mode it overrides the document's name, and null keeps it |
| ec2nodeclass_name | string | `null` | Name of the `EC2NodeClass` to schedule against. A literal name, or the node class module's `name` output. **Required in template mode**; in YAML mode it overrides the document's `nodeClassRef.name`, and null keeps it |
| lookup_ec2nodeclass | bool | `true` | Read the referenced `EC2NodeClass` so a missing one fails the plan. Set false when it is created elsewhere in the same root module |
| manifest_yaml | string | `null` | A finished NodePool document as YAML. Setting it selects **YAML mode**. Mutually exclusive with `manifest_path` |
| requirements | list(object) | `null` → `[]` | `spec.template.spec.requirements`: `key`, `operator`, optional `values`, optional `minValues`. Template mode only |
| limits | map(string) | `null` → `{}` | `spec.limits`, keyed by arbitrary resource name; values are Kubernetes quantities. Template mode only |
| taints | list(object) | `null` → `[]` | `spec.template.spec.taints`: `key`, optional `value`, `effect`. Template mode only |
| labels | map(string) | `null` → `{}` | `spec.template.metadata.labels`. Counts toward the 100-entry requirements cap. Template mode only |
| weight | number | `null` | `spec.weight`, 1–100. Omit rather than passing 0. Template mode only |
| disruption | object | `null` | `spec.disruption`: `consolidationPolicy`, `consolidateAfter`, `budgets`. Omitted entirely when null. Template mode only |
| expire_after | string | `null` | `spec.template.spec.expireAfter`. Omitted when null, inheriting Karpenter's 720h. Template mode only |
| termination_grace_period | string | `null` | `spec.template.spec.terminationGracePeriod`. No Karpenter default; does not accept `Never`. Template mode only |
| manifest_path | string | `null` | Replacement **template** file. Null uses the bundled one. Mutually exclusive with `manifest_yaml` |

Every "template mode only" input above is **rejected**, not ignored, when `manifest_yaml` is set.
`null → []` means the variable defaults to `null` and the module resolves the empty collection
internally for template mode; the two are indistinguishable in the rendered manifest, and the null
default is what makes the rejection above possible.

## Outputs

| Name | Description |
|------|-------------|
| name | `metadata.name` of the applied NodePool, read off the resource so consumers are ordered after it exists |
| uid | `metadata.uid` of the applied NodePool |
| id | Terraform resource ID of the applied NodePool |
| rendered_manifest | The templated YAML exactly as submitted. Known at plan time |

## Out of scope

`startupTaints`, `spec.template.metadata.annotations`, kubelet configuration (which moved to the
`EC2NodeClass` in v1) and EKS Auto Mode node pools are not exposed. Karpenter itself is assumed
installed. Non-AWS clouds would be separate modules.

## Testing

```bash
cd modules/aws/karpenter/nodepool
tofu init
tofu test
tofu test -filter=tests/requirements.tftest.hcl
```

Every run is `command = plan` against `mock_provider "kubectl" {}`, which configures no provider and
makes no cluster calls, so the suite needs no kubeconfig, no cluster and no AWS credentials. Run it
from this directory: `tests/fixtures.tftest.hcl` loads its fixture YAML by relative path.

| File | Covers |
|------|--------|
| `tests/baseline.tftest.hcl` | Minimal render, the no-Karpenter-defaults rule, `name`, `manifest_path` |
| `tests/requirements.tftest.hcl` | Operator enum, per-operator value arity, `minValues`, the 100-item cap |
| `tests/limits_taints_labels.tftest.hcl` | Quantity parsing, taint effects and keys, label key/value shape, the 50-taint cap |
| `tests/disruption.tftest.hcl` | Consolidation policy and duration, budget nodes/schedule/duration/reasons, the 50-budget cap |
| `tests/durations_and_weight.tftest.hcl` | `expire_after` versus `termination_grace_period`, and the `weight` bounds |
| `tests/nodeclass_reference.tftest.hcl` | The `nodeClassRef` triple and `lookup_ec2nodeclass` |
| `tests/combinations.tftest.hcl` | Rules that span attributes, including the requirements-plus-labels cap |
| `tests/fixtures.tftest.hcl` | Replay of two anonymised NodePools captured from live clusters |
| `tests/manifest_yaml.tftest.hcl` | YAML mode: mode selection, document structure, the override set, inheritance, passthrough, ignored-input rejection, and both fixtures fed in as documents |

Assertions go through `yamldecode(output.rendered_manifest)`, never the raw string: `templatefile`
output is whitespace- and key-order-sensitive, and string equality would make the suite fail on
cosmetic edits.

`expect_failures` proves that an object was *rejected*, not *which* of its validation blocks fired,
so every rejecting run breaks exactly one rule. It also cannot catch type errors, so every rejection
case is a correctly-typed value that violates a rule — `weight = "ten"` is left to the type system.
