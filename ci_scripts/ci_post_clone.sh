#!/bin/zsh
# Xcode Cloud runs this after it clones the repo (docs/development.md, Xcode Cloud). The project
# is generated, not committed, so this makes it: XcodeGen, the signing team, the build number,
# and the package pins Xcode Cloud needs because it never resolves packages on its own.
set -euo pipefail
cd "${CI_PRIMARY_REPOSITORY_PATH:-${0:A:h:h}}"

[[ -n ${CI_TEAM_ID:-} ]] || { print -u2 "ci_post_clone.sh: CI_TEAM_ID is not set"; exit 1; }
print -r -- "DEVELOPMENT_TEAM = $CI_TEAM_ID" > Config/Signing.local.xcconfig

# Same scheme and time zone as scripts/testflight.sh. The archive keeps it, but Xcode Cloud stamps
# the build it uploads to TestFlight with its own counter (docs/development.md, Xcode Cloud).
BUILD=$(TZ=America/New_York date +%y%m%d%H%M)
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\).*/\1 \"$BUILD\"/" project.yml
grep -q "CURRENT_PROJECT_VERSION: \"$BUILD\"" project.yml || { print -u2 "ci_post_clone.sh: could not set the build number"; exit 1; }

if ! command -v xcodegen >/dev/null; then
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew install --quiet xcodegen
fi
xcodegen generate --quiet

# The app's only remote package comes through PlainKit, so PlainKit's pins are the project's pins.
PINS=Plain.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p $PINS
cp Packages/PlainKit/Package.resolved $PINS/Package.resolved
print -r -- "ci_post_clone.sh: generated Plain.xcodeproj, build $BUILD"
