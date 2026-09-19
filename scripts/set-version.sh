#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    print -u2 "Invalid marketing version: ${version} (expected X.Y.Z with optional prerelease suffix)"
    exit 64
fi
if [[ ! "$build" =~ ^[0-9]+$ ]] || [[ "$build" -eq 0 ]]; then
    print -u2 "Invalid build number: ${build} (expected a positive integer)"
    exit 64
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
project_file="${repo_root}/project.yml"

command -v xcodegen >/dev/null || {
    print -u2 "Missing command: xcodegen"
    exit 69
}
[[ -f "$project_file" ]] || {
    print -u2 "Project definition not found: ${project_file}"
    exit 70
}

# Only the application target carries these settings in project.yml.
marketing_count=$(grep -c 'MARKETING_VERSION:' "$project_file" || true)
build_count=$(grep -c 'CURRENT_PROJECT_VERSION:' "$project_file" || true)
if [[ "$marketing_count" -ne 1 ]] || [[ "$build_count" -ne 1 ]]; then
    print -u2 "Expected exactly one MARKETING_VERSION and one CURRENT_PROJECT_VERSION in project.yml, found ${marketing_count}/${build_count}"
    exit 70
fi

sed -i '' \
    -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${version}\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${build}\"/" \
    "$project_file"

if ! grep -q "MARKETING_VERSION: \"${version}\"" "$project_file" || ! grep -q "CURRENT_PROJECT_VERSION: \"${build}\"" "$project_file"; then
    print -u2 "Failed to rewrite version settings in project.yml"
    exit 70
fi

(cd "$repo_root" && xcodegen generate >/dev/null)

print "Copilot Native version set to ${version} (${build})"
