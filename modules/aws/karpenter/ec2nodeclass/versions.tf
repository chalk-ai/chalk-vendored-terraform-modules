terraform {
  required_providers {
    kubectl = {
      source = "alekc/kubectl"
      # `~> 2.3` is a functional floor, not a style match: the `kubectl_manifest` DATA SOURCE that
      # the companion nodepool module reads is absent at v2.1.6 and v2.2.0 and present at v2.3.0.
      # The prevailing house pin of `>= 2` would permit a version in which that module cannot work,
      # so both modules in this family pin the same way. The 2.x line is also deliberate: the
      # provider's `main` documentation describes an unreleased v3 (beta only) whose data source
      # gains `wait_for` and replaces `yaml_incluster` with `drift`. Do not design against it.
      version = "~> 2.3"
    }
  }
}
