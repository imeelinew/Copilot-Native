#!/bin/zsh
set -euo pipefail
umask 077

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: $0 <marketing-version> <build-number>"
    exit 64
fi

version="$1"
build="$2"
tag="v${version}"
script_dir="${0:A:h}"
repo_root="${script_dir:h}"
github_repo="${COPILOT_NATIVE_GITHUB_REPOSITORY:-imeelinew/Copilot-Native}"
team_id="${COPILOT_NATIVE_TEAM_ID:-5Q5QT76MJU}"
work_dir=$(mktemp -d /tmp/copilot-native-release.XXXXXX)
trap 'rm -rf "$work_dir"' EXIT

cd "$repo_root"

for required_command in git gh xcodebuild security codesign ditto ruby xcodegen; do
    command -v "$required_command" >/dev/null || {
        print -u2 "Missing command: $required_command"
        exit 69
    }
done

[[ "$(git branch --show-current)" == "main" ]] || {
    print -u2 "Release must run from main"
    exit 65
}
[[ -z "$(git status --porcelain)" ]] || {
    print -u2 "Commit or discard local changes before releasing"
    exit 65
}
gh auth status >/dev/null
if gh release view "$tag" --repo "$github_repo" >/dev/null 2>&1; then
    print -u2 "Release already exists: $tag"
    exit 65
fi

signing_identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)
[[ -n "$signing_identity" ]] || {
    print -u2 "No Apple Development certificate found in the login Keychain"
    exit 66
}

"$script_dir/set-version.sh" "$version" "$build"
git add project.yml 'Copilot Native.xcodeproj/project.pbxproj'
if ! git diff --cached --quiet; then
    git commit -m "Release $tag"
fi

archive_path="$work_dir/Copilot Native.xcarchive"
derived_data="$work_dir/DerivedData"
xcodebuild archive \
    -project 'Copilot Native.xcodeproj' \
    -scheme 'Copilot Native' \
    -configuration Release \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_IDENTITY="$signing_identity" \
    CODE_SIGN_STYLE=Manual \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build"

app_path="$archive_path/Products/Applications/Copilot Native.app"
[[ -d "$app_path" ]] || {
    print -u2 "Archived app not found"
    exit 70
}
codesign --verify --deep --strict --verbose=2 "$app_path"

archive_file="$work_dir/CopilotNative-${version}.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_file"

git fetch origin main
git merge-base --is-ancestor origin/main HEAD || {
    print -u2 "Local main does not contain origin/main; integrate remote changes first"
    exit 65
}
git push origin HEAD:main

# Intentionally blank release description. Never add --generate-notes or a notes file.
gh release create "$tag" \
    "$archive_file" \
    --repo "$github_repo" \
    --target "$(git rev-parse HEAD)" \
    --title "$tag" \
    --notes '' \
    --latest

print "Published $tag with an empty description"
print "GitHub Actions will sign the archive and publish the Sparkle appcast"
