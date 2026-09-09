# subnet_selector_terms, fully covered: single / multi / mixed, good and bad.
#
# This is the field a customer cannot be told how to fill in prose -- it is environment-specific,
# it is the one most likely to be wrong, and a wrong value produces nodes that never launch rather
# than a clear error. So it gets the heaviest coverage in the module.
#
# `mock_provider "kubectl" {}` makes no cluster calls, so this runs with no kubeconfig and no AWS
# credentials.
#
# Two constraints shape every negative run below:
#
#   * `expect_failures` proves REJECTION, not which rule fired -- it does not match on
#     error_message, and this variable carries three validation blocks. So every negative run
#     contains exactly one violation, and a run that starts passing for the wrong reason still
#     names the case it was written for.
#   * `expect_failures` cannot catch type errors. Every value below is correctly typed and violates
#     a custom validation; type enforcement is left to the type system and not re-tested.

mock_provider "kubectl" {}

variables {
  cluster_name          = "example-cluster"
  node_role_name        = "example-cluster-Managed-Node-Role"
  subnet_selector_terms = [{ id = "subnet-xxxxx" }]
}

# --------------------------------------------------------------------------------------------------
# single good
# --------------------------------------------------------------------------------------------------

run "single_id_term" {
  command = plan

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ id = "subnet-xxxxx" }]
    error_message = "a single id term no longer renders"
  }
}

run "single_tag_term" {
  command = plan

  variables {
    subnet_selector_terms = [{ tags = { "karpenter.sh/discovery" = "example-cluster" } }]
  }

  assert {
    condition     = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [{ tags = { "karpenter.sh/discovery" = "example-cluster" } }]
    error_message = "a single tag-discovery term no longer renders"
  }
}

# --------------------------------------------------------------------------------------------------
# multi good
# --------------------------------------------------------------------------------------------------

run "multi_id_terms" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "subnet-xxxxx" }, { id = "subnet-yyyyy" }, { id = "subnet-zzzzz" }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms) == 3
    error_message = "multi-term lists no longer render every term"
  }
  assert {
    condition = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy" },
      { id = "subnet-zzzzz" },
    ]
    error_message = "multi-term id lists no longer render in caller order"
  }
}

run "multi_tag_terms" {
  command = plan

  variables {
    subnet_selector_terms = [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = { "Tier" = "private" } },
    ]
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = { "Tier" = "private" } },
    ]
    error_message = "multiple tag terms no longer render as separate ORed terms"
  }
}

# Conditions inside one term are ANDed, so a two-key term is one term and not two.
run "multi_key_tag_term_stays_one_anded_term" {
  command = plan

  variables {
    subnet_selector_terms = [{ tags = { "karpenter.sh/discovery" = "example-cluster", "Tier" = "private" } }]
  }

  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms) == 1
    error_message = "a two-key tag term is being split into two terms, which changes AND semantics into OR"
  }
  assert {
    condition     = length(yamldecode(output.rendered_manifest).spec.subnetSelectorTerms[0].tags) == 2
    error_message = "a two-key tag term no longer renders both keys"
  }
}

# Cross-form: terms are ORed, so the id form and the tag form coexist in one list.
run "mixed_id_and_tag_forms_are_both_valid" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx" },
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
    ]
  }

  assert {
    condition = yamldecode(output.rendered_manifest).spec.subnetSelectorTerms == [
      { id = "subnet-xxxxx" },
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
    ]
    error_message = "id and tag terms no longer coexist in one list"
  }
}

# --------------------------------------------------------------------------------------------------
# single bad
# --------------------------------------------------------------------------------------------------

run "empty_list_rejected" {
  command = plan

  variables {
    subnet_selector_terms = []
  }

  expect_failures = [var.subnet_selector_terms]
}

run "term_with_neither_key_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = null, tags = null }]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "term_with_both_keys_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "subnet-xxxxx", tags = { a = "b" } }]
  }

  expect_failures = [var.subnet_selector_terms]
}

# An empty tags map satisfies neither side of the exclusivity rule, which is why the module needs no
# separate "tags must be non-empty" validation that would double-fire in the same run.
run "term_with_an_empty_tags_map_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ tags = {} }]
  }

  expect_failures = [var.subnet_selector_terms]
}

# --- id shape. One run per malformed shape, so each names its own case. ---------------------------

run "vpc_id_in_a_subnet_field_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "vpc-xxxxx" }]
  }

  expect_failures = [var.subnet_selector_terms]
}

# An empty string is not null, so it passes the exclusivity rule and must be caught by the id shape
# rule instead.
run "empty_string_id_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "" }]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "bare_subnet_prefix_id_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "subnet-" }]
  }

  expect_failures = [var.subnet_selector_terms]
}

# --------------------------------------------------------------------------------------------------
# multi bad
# --------------------------------------------------------------------------------------------------

run "all_terms_missing_both_keys_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{}, {}]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "all_terms_setting_both_keys_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx", tags = { a = "b" } },
      { id = "subnet-yyyyy", tags = { c = "d" } },
    ]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "all_ids_malformed_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [{ id = "vpc-xxxxx" }, { id = "" }, { id = "subnet-" }]
  }

  expect_failures = [var.subnet_selector_terms]
}

# --------------------------------------------------------------------------------------------------
# MIXED: valid elements first, the invalid one LAST. These are the runs that earn their keep.
#
# A validation written as `var.subnet_selector_terms[0].id != null` passes every run above. It fails
# only here, which is what forces `alltrue([for t in ... : ...])` instead of an index.
# --------------------------------------------------------------------------------------------------

run "valid_terms_followed_by_a_term_with_neither_key_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx" },
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { id = null, tags = null },
    ]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "valid_term_followed_by_a_both_keys_term_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy", tags = { a = "b" } },
    ]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "valid_ids_followed_by_a_vpc_id_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [
      { id = "subnet-xxxxx" },
      { id = "subnet-yyyyy" },
      { id = "vpc-xxxxx" },
    ]
  }

  expect_failures = [var.subnet_selector_terms]
}

run "valid_tag_term_followed_by_an_empty_tags_map_rejected" {
  command = plan

  variables {
    subnet_selector_terms = [
      { tags = { "karpenter.sh/discovery" = "example-cluster" } },
      { tags = {} },
    ]
  }

  expect_failures = [var.subnet_selector_terms]
}
