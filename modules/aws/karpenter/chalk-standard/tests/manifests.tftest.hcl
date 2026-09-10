# Per-object characterization tests. Each run pins one object's FULL decoded manifest.
#
# A whole-manifest equality assertion is the only kind that catches an accidental edit
# to a label, a taint, a requirement value or a boot volume size -- a per-field
# assertion suite quietly passes when a field is DELETED.
#
# `mock_provider "kubectl" {}` configures no provider and reaches no cluster, so this
# suite needs no kubeconfig and no credentials.
#
# `nonsensitive()` is required because alekc/kubectl marks `yaml_body` sensitive at the
# schema level; the provider's `sensitive_fields = []` argument does not change that, it
# only controls redaction of `yaml_body_parsed`.

mock_provider "kubectl" {}

variables {
  cluster_name = "example-cluster"
  subnets      = ["subnet-xxxxx", "subnet-yyyyy"]
}


run "ec2nodeclass_al2023" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.al2023_node_class.yaml_body)) == {
      apiVersion = "karpenter.k8s.aws/v1"
      kind       = "EC2NodeClass"
      metadata = {
        name = "al2023"
      }
      spec = {
        amiSelectorTerms = [{ alias = "al2023@latest" }]
        role             = "example-cluster-Managed-Node-Role"
        subnetSelectorTerms = [
          { id = "subnet-xxxxx" },
          { id = "subnet-yyyyy" },
        ]
        securityGroupSelectorTerms = [
          { tags = { "karpenter.sh/discovery" = "example-cluster" } },
          { tags = { "aws:eks:cluster-name" = "example-cluster" } },
        ]
        userData = <<-EOT
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                registryPullQPS: 0
        EOT
        blockDeviceMappings = [
          {
            deviceName = "/dev/xvda"
            ebs = {
              volumeType          = "gp3"
              volumeSize          = "200Gi"
              deleteOnTermination = true
            }
          },
        ]
        metadataOptions = {
          httpEndpoint            = "enabled"
          httpProtocolIPv6        = "disabled"
          httpPutResponseHopLimit = 2
          httpTokens              = "required"
        }
        tags = {
          "karpenter.sh/discovery" = "example-cluster"
        }
      }
    }
    error_message = "the rendered manifest for ec2nodeclass_al2023 no longer matches its pinned manifest"
  }
}

run "ec2nodeclass_al2023_offline_lssd" {
  command = plan

  # instanceStorePolicy RAID0 is the only structural difference from al2023; the boot volume size is the same 200Gi under Karpenter v1.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.al2023_lssd_node_class.yaml_body)) == {
      apiVersion = "karpenter.k8s.aws/v1"
      kind       = "EC2NodeClass"
      metadata = {
        name = "al2023-offline-lssd"
      }
      spec = {
        amiSelectorTerms = [{ alias = "al2023@latest" }]
        role             = "example-cluster-Managed-Node-Role"
        subnetSelectorTerms = [
          { id = "subnet-xxxxx" },
          { id = "subnet-yyyyy" },
        ]
        securityGroupSelectorTerms = [
          { tags = { "karpenter.sh/discovery" = "example-cluster" } },
          { tags = { "aws:eks:cluster-name" = "example-cluster" } },
        ]
        instanceStorePolicy = "RAID0"
        userData            = <<-EOT
          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                registryPullQPS: 0
        EOT
        blockDeviceMappings = [
          {
            deviceName = "/dev/xvda"
            ebs = {
              volumeType          = "gp3"
              volumeSize          = "200Gi"
              deleteOnTermination = true
            }
          },
        ]
        metadataOptions = {
          httpEndpoint            = "enabled"
          httpProtocolIPv6        = "disabled"
          httpPutResponseHopLimit = 2
          httpTokens              = "required"
        }
        tags = {
          "karpenter.sh/discovery" = "example-cluster"
        }
      }
    }
    error_message = "the rendered manifest for ec2nodeclass_al2023_offline_lssd no longer matches its pinned manifest"
  }
}

run "ec2nodeclass_gvisor" {
  command = plan

  # MIME-multipart user data. The $${ARCH} / $${URL} escapes must survive as literal shell variables, not be interpolated by OpenTofu.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.gvisor_node_class[0].yaml_body)) == {
      apiVersion = "karpenter.k8s.aws/v1"
      kind       = "EC2NodeClass"
      metadata = {
        name = "gvisor"
      }
      spec = {
        amiSelectorTerms = [{ alias = "al2023@latest" }]
        role             = "example-cluster-Managed-Node-Role"
        subnetSelectorTerms = [
          { id = "subnet-xxxxx" },
          { id = "subnet-yyyyy" },
        ]
        securityGroupSelectorTerms = [
          { tags = { "karpenter.sh/discovery" = "example-cluster" } },
          { tags = { "aws:eks:cluster-name" = "example-cluster" } },
        ]
        blockDeviceMappings = [
          {
            deviceName = "/dev/xvda"
            ebs = {
              deleteOnTermination = true
              volumeSize          = "200Gi"
              volumeType          = "gp3"
            }
          },
        ]
        metadataOptions = {
          httpEndpoint            = "enabled"
          httpProtocolIPv6        = "disabled"
          httpPutResponseHopLimit = 2
          httpTokens              = "required"
        }
        tags = {
          "karpenter.sh/discovery" = "example-cluster"
        }
        userData = <<-EOT
          MIME-Version: 1.0
          Content-Type: multipart/mixed; boundary="BOUNDARY"

          --BOUNDARY
          Content-Type: application/node.eks.aws

          apiVersion: node.eks.aws/v1alpha1
          kind: NodeConfig
          spec:
            kubelet:
              config:
                registryPullQPS: 0

          --BOUNDARY
          Content-Type: text/x-shellscript; charset="us-ascii"

          #!/bin/bash
          set -e

          # Install gVisor
          ARCH=$(uname -m)
          URL="https://storage.googleapis.com/gvisor/releases/release/latest/$${ARCH}"
          curl -fsSL "$${URL}/runsc" -o /usr/local/bin/runsc
          curl -fsSL "$${URL}/containerd-shim-runsc-v1" -o /usr/local/bin/containerd-shim-runsc-v1
          chmod +x /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1

          # Wait for nodeadm to configure containerd
          while [ ! -f /etc/containerd/config.toml ] || ! grep -q "io.containerd.cri.v1.runtime" /etc/containerd/config.toml; do
            sleep 1
          done

          # Add gVisor runtime (AL2023 containerd 2.x format)
          cat >> /etc/containerd/config.toml <<'CONTAINERD_EOF'

          [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
          runtime_type = "io.containerd.runsc.v1"
          CONTAINERD_EOF

          systemctl restart containerd

          --BOUNDARY--
        EOT
      }
    }
    error_message = "the rendered manifest for ec2nodeclass_gvisor no longer matches its pinned manifest"
  }
}

run "nodepool_oss_controllers" {
  command = plan

  # The only pool with no template.metadata, no taints, and a cpu limit that is not local.max_cpu.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.oss_controllers_node_pool.yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "oss-controllers"
        labels = {
          "chalk.ai/visibility" = "internal"
        }
      }
      spec = {
        template = {
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "node.kubernetes.io/instance-type"
                operator = "In"
                values   = ["t3.medium"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
            ]
          }
        }
        limits = {
          cpu = 6
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_oss_controllers no longer matches its pinned manifest"
  }
}

run "nodepool_chalk_infrastructure" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-infrastructure"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-infrastructure"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "infrastructure"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "infrastructure"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = ["m", "r", "c"]
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "In"
                values   = ["5", "6", "7", "8"]
              },
              {
                key      = "karpenter.k8s.aws/instance-hypervisor"
                operator = "In"
                values   = ["nitro"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
            ]
            taints = [
              {
                key    = "chalk.ai/workload-type"
                value  = "infrastructure"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_chalk_infrastructure no longer matches its pinned manifest"
  }
}

run "nodepool_chalk_online" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-online"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-online"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "online"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "online"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = ["m", "r", "c"]
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "In"
                values   = ["5", "6", "7", "8"]
              },
              {
                key      = "karpenter.k8s.aws/instance-hypervisor"
                operator = "In"
                values   = ["nitro"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
            ]
            taints = [
              {
                key    = "chalk.ai/workload-type"
                value  = "online"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_chalk_online no longer matches its pinned manifest"
  }
}

run "nodepool_chalk_offline" {
  command = plan

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-offline"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-offline"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "offline"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "offline"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023-offline-lssd"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = ["m", "r", "c"]
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "In"
                values   = ["5", "6", "7", "8"]
              },
              {
                key      = "karpenter.k8s.aws/instance-hypervisor"
                operator = "In"
                values   = ["nitro"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
              {
                key      = "karpenter.k8s.aws/instance-local-nvme"
                operator = "Gt"
                values   = ["0"]
              },
            ]
            taints = [
              {
                key    = "chalk.ai/workload-type"
                value  = "offline"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_chalk_offline no longer matches its pinned manifest"
  }
}

run "nodepool_chalk_nap" {
  command = plan

  variables {
    chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
  }

  # Dataplane v2 only. Identical to chalk-online EXCEPT that it carries no chalk.ai/workload-type taint -- that is the entire point of the pool.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.internal_node_pools["chalk-nap"].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-nap"
        labels = {
          "chalk.ai/visibility"    = "internal"
          "chalk.ai/workload-type" = "online"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "online"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = ["m", "r", "c"]
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "In"
                values   = ["5", "6", "7", "8"]
              },
              {
                key      = "karpenter.k8s.aws/instance-hypervisor"
                operator = "In"
                values   = ["nitro"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
            ]
            taints = [
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_chalk_nap no longer matches its pinned manifest"
  }
}

run "nodepool_chalk_compute" {
  command = plan

  # Generation 6+ only here, unlike the shared workload requirements which also allow 5.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.chalk_compute_node_pool[0].yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-compute"
        labels = {
          "chalk.ai/visibility" = "internal"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/container-runtime" = "gvisor"
              "chalk.ai/managed-by"        = "chalk"
              "chalk.ai/workload-type"     = "compute"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "gvisor"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = ["m", "r", "c"]
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "In"
                values   = ["6", "7", "8"]
              },
              {
                key      = "karpenter.k8s.aws/instance-hypervisor"
                operator = "In"
                values   = ["nitro"]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
            ]
            taints = [
              {
                key    = "chalk.ai/container-runtime"
                value  = "gvisor"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/workload-type"
                value  = "compute"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_chalk_compute no longer matches its pinned manifest"
  }
}

run "nodepool_chalk_compute_gpu" {
  command = plan

  # Always created; the GPU pool is not gated on anything.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.chalk_compute_gpu_node_pool.yaml_body)) == {
      apiVersion = "karpenter.sh/v1"
      kind       = "NodePool"
      metadata = {
        name = "chalk-compute-gpu"
        labels = {
          "chalk.ai/visibility" = "internal"
        }
      }
      spec = {
        template = {
          metadata = {
            labels = {
              "chalk.ai/managed-by"    = "chalk"
              "chalk.ai/workload-type" = "compute"
              "nvidia.com/gpu.present" = "true"
            }
          }
          spec = {
            nodeClassRef = {
              group = "karpenter.k8s.aws"
              kind  = "EC2NodeClass"
              name  = "al2023"
            }
            expireAfter            = "720h"
            terminationGracePeriod = "30m"
            requirements = [
              {
                key      = "karpenter.k8s.aws/instance-category"
                operator = "In"
                values   = ["g", "p"]
              },
              {
                key      = "karpenter.k8s.aws/instance-gpu-manufacturer"
                operator = "In"
                values   = ["nvidia"]
              },
              {
                key      = "karpenter.k8s.aws/instance-generation"
                operator = "In"
                values   = ["4", "5", "6"]
              },
              {
                key      = "karpenter.k8s.aws/instance-hypervisor"
                operator = "In"
                values   = ["nitro"]
              },
              {
                key      = "kubernetes.io/arch"
                operator = "In"
                values   = ["amd64"]
              },
              {
                key      = "kubernetes.io/os"
                operator = "In"
                values   = ["linux"]
              },
              {
                key      = "karpenter.sh/capacity-type"
                operator = "In"
                values   = ["on-demand"]
              },
            ]
            taints = [
              {
                key    = "nvidia.com/gpu"
                value  = "true"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/workload-type"
                value  = "compute"
                effect = "NoSchedule"
              },
              {
                key    = "chalk.ai/managed-by"
                value  = "chalk"
                effect = "NoSchedule"
              },
            ]
          }
        }
        limits = {
          cpu = 128000
        }
        disruption = {
          consolidationPolicy = "WhenEmptyOrUnderutilized"
          consolidateAfter    = "0s"
        }
        weight = 10
      }
    }
    error_message = "the rendered manifest for nodepool_chalk_compute_gpu no longer matches its pinned manifest"
  }
}

run "runtimeclass_gvisor" {
  command = plan

  # The Chalk UI cannot create a RuntimeClass at all, so this object only ever comes from Terraform.

  assert {
    condition = yamldecode(nonsensitive(kubectl_manifest.gvisor_runtime_class[0].yaml_body)) == {
      apiVersion = "node.k8s.io/v1"
      kind       = "RuntimeClass"
      metadata = {
        name = "gvisor"
      }
      handler = "runsc"
      scheduling = {
        nodeSelector = {
          "chalk.ai/container-runtime" = "gvisor"
          "chalk.ai/workload-type"     = "compute"
        }
        tolerations = [
          {
            key      = "chalk.ai/container-runtime"
            operator = "Equal"
            value    = "gvisor"
            effect   = "NoSchedule"
          },
          {
            key      = "chalk.ai/workload-type"
            operator = "Equal"
            value    = "compute"
            effect   = "NoSchedule"
          },
          {
            key      = "chalk.ai/managed-by"
            operator = "Equal"
            value    = "chalk"
            effect   = "NoSchedule"
          },
        ]
      }
    }
    error_message = "the rendered manifest for runtimeclass_gvisor no longer matches its pinned manifest"
  }
}

run "all_ten_objects_are_created" {
  command = plan

  variables {
    chalk_dataplane_version = "CHALK_DATAPLANE_VERSION_V2"
  }

  assert {
    condition     = length(kubectl_manifest.internal_node_pools) == 4
    error_message = "expected 4 internal node pools on dataplane v2: chalk-infrastructure, chalk-online, chalk-offline, chalk-nap"
  }
  assert {
    condition     = length(kubectl_manifest.gvisor_node_class) == 1
    error_message = "the gvisor EC2NodeClass is no longer created"
  }
  assert {
    condition     = length(kubectl_manifest.chalk_compute_node_pool) == 1
    error_message = "the chalk-compute NodePool is no longer created"
  }
  assert {
    condition     = length(kubectl_manifest.gvisor_runtime_class) == 1
    error_message = "the gvisor RuntimeClass is no longer created"
  }
  assert {
    condition     = output.ec2_node_class_names == ["al2023", "al2023-offline-lssd", "gvisor"]
    error_message = "the set of EC2NodeClass names changed"
  }
  assert {
    # tolist() because sort() returns list(string) and a bracket literal is a tuple;
    # OpenTofu's == is type-strict across those two.
    condition = output.node_pool_names == tolist([
      "chalk-compute",
      "chalk-compute-gpu",
      "chalk-infrastructure",
      "chalk-nap",
      "chalk-offline",
      "chalk-online",
      "oss-controllers",
    ])
    error_message = "the set of NodePool names changed"
  }
  assert {
    condition     = output.runtime_class_name == "gvisor"
    error_message = "the gvisor RuntimeClass name changed"
  }
}
