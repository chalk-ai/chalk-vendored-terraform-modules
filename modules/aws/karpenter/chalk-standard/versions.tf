terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
      # 2.x is the first release line that exposes `sensitive_fields` and treats
      # `upgrade_api_version` as a first-class argument. The manifests here are
      # Karpenter v1 only, so there is no reason to support 1.x.
      version = "~> 2.3"
    }
  }
}
