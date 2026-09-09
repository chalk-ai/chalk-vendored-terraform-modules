terraform {
  required_version = ">= 1.3.0"

  required_providers {
    kubectl = {
      source = "alekc/kubectl"
      # Functional floor, not a style match: `data "kubectl_manifest"` -- which
      # var.lookup_ec2nodeclass depends on -- is absent at v2.1.6 and v2.2.0 and
      # first ships in v2.3.0. The prevailing house pin of `>= 2` would permit a
      # version in which this module simply does not work.
      version = "~> 2.3"
    }
  }
}
