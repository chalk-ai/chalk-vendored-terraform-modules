#!/usr/bin/env bash
#
# Report whether the upstream source this module was ported from has moved.
#
# modules/aws/karpenter/chalk-standard is a direct port of a single file in the
# chalk-terraform repository, taken at a specific commit. That makes drift invisible:
# nothing in this repository changes when the source does. This script surfaces it.
#
# Exit codes:
#   0  no drift -- the source file is unchanged since UPSTREAM_SHA
#   1  drift    -- one or more commits have touched the source file
#   2  usage or environment error
#
# Read-only. It runs one `git log` and mutates nothing.

set -euo pipefail

# The commit this module was ported from. Bump this ONLY together with a review of the
# intervening commits and any corresponding change to the module.
UPSTREAM_SHA="aa986a8544bd8be391ed81457f95e3cb4775ef82"
UPSTREAM_PATH="infra/aws/terragrunt/chalk-kube/karpenter.tf"

usage() {
  cat <<EOF
usage: ${0##*/} [CHALK_TERRAFORM_CHECKOUT]

Reports commits that have touched
  ${UPSTREAM_PATH}
since ${UPSTREAM_SHA}

The checkout may be given as the first argument, or via the CHALK_TERRAFORM_REPO
environment variable. It defaults to \$HOME/IdeaProjects/chalk-terraform.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
-*)
  echo "error: unknown option ${1}" >&2
  usage >&2
  exit 2
  ;;
esac

repo="${1:-${CHALK_TERRAFORM_REPO:-${HOME}/IdeaProjects/chalk-terraform}}"

# A git worktree has .git as a FILE, not a directory, so test for existence not type.
if [[ ! -e "${repo}/.git" ]]; then
  echo "error: ${repo} is not a git checkout" >&2
  echo "hint: pass the chalk-terraform checkout as the first argument, or set CHALK_TERRAFORM_REPO" >&2
  exit 2
fi

if ! git -C "${repo}" cat-file -e "${UPSTREAM_SHA}^{commit}" 2>/dev/null; then
  echo "error: commit ${UPSTREAM_SHA} is not present in ${repo}" >&2
  echo "hint: a shallow clone will not have it, and neither will an unrelated repository" >&2
  exit 2
fi

commits="$(git -C "${repo}" log --oneline "${UPSTREAM_SHA}..HEAD" -- "${UPSTREAM_PATH}")"

if [[ -z "${commits}" ]]; then
  echo "no drift: ${UPSTREAM_PATH} is unchanged since ${UPSTREAM_SHA:0:8}"
  exit 0
fi

count="$(printf '%s\n' "${commits}" | wc -l | tr -d ' ')"
echo "UPSTREAM DRIFT: ${count} commit(s) have touched ${UPSTREAM_PATH} since ${UPSTREAM_SHA:0:8}"
echo
printf '%s\n' "${commits}"
echo
echo "Review each against this module. If the module needs no change, bump UPSTREAM_SHA"
echo "in this script and in the module README so the next run is quiet again."
exit 1
