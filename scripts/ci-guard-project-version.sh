#!/usr/bin/env bash
# Validate project.yml marketing/build for CI.
# - Always: MARKETING_VERSION looks like semver-ish X.Y or X.Y.Z; CURRENT_PROJECT_VERSION is a positive integer.
# - pull_request: CURRENT_PROJECT_VERSION must match the PR base branch (no drive-by bump on feature PRs).
# ASC uniqueness is enforced in the TestFlight upload workflow, not here.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-.}"
YML="${ROOT}/project.yml"
if [[ ! -f "${YML}" ]]; then
  echo "::error::project.yml not found at ${YML}"
  exit 1
fi

marketing="$(
  grep -E '^\s*MARKETING_VERSION:' "${YML}" | head -n1 | sed -E 's/.*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/' | tr -d '[:space:]'
)"
build="$(
  grep -E '^\s*CURRENT_PROJECT_VERSION:' "${YML}" | head -n1 | sed -E 's/.*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/' | tr -d '[:space:]'
)"

if [[ -z "${marketing}" || -z "${build}" ]]; then
  echo "::error::Could not parse MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml"
  exit 1
fi

if [[ ! "${marketing}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "::error::Invalid MARKETING_VERSION '${marketing}' (expected X.Y or X.Y.Z)"
  exit 1
fi

if [[ ! "${build}" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Invalid CURRENT_PROJECT_VERSION '${build}' (expected positive integer)"
  exit 1
fi

echo "project.yml marketing=${marketing} build=${build}"

event="${GITHUB_EVENT_NAME:-}"
if [[ "${event}" == "pull_request" ]]; then
  base_ref="${GITHUB_BASE_REF:-}"
  if [[ -z "${base_ref}" ]]; then
    echo "::error::GITHUB_BASE_REF missing on pull_request"
    exit 1
  fi
  git fetch --no-tags --depth=1 origin "${base_ref}" 2>/dev/null || git fetch --no-tags origin "${base_ref}"
  base_yml="$(git show "origin/${base_ref}:project.yml" 2>/dev/null || true)"
  if [[ -z "${base_yml}" ]]; then
    echo "::error::Could not read project.yml from origin/${base_ref}"
    exit 1
  fi
  base_build="$(
    printf '%s\n' "${base_yml}" | grep -E '^\s*CURRENT_PROJECT_VERSION:' | head -n1 | sed -E 's/.*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"]+)"?.*/\1/' | tr -d '[:space:]'
  )"
  if [[ -z "${base_build}" ]]; then
    echo "::error::Could not parse CURRENT_PROJECT_VERSION from origin/${base_ref}:project.yml"
    exit 1
  fi
  if [[ "${build}" != "${base_build}" ]]; then
    title="${PR_TITLE:-}"
    # Dedicated release PRs may bump build; ordinary feature PRs may not.
    if [[ "${title}" =~ ^chore\(release\) ]] || [[ "${title}" =~ ^chore\(ios-release\) ]]; then
      echo "Allowing CURRENT_PROJECT_VERSION change on release-titled PR (${base_build} -> ${build})"
    else
      echo "::error::Feature PR must not change CURRENT_PROJECT_VERSION (head=${build}, base=${base_ref}:${base_build}). Use a chore(release) PR or push a dedicated release commit for TestFlight bumps."
      exit 1
    fi
  else
    echo "PR build matches base ${base_ref} (${base_build})"
  fi
fi

echo "CI project version guard passed."
