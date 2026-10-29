#!/bin/zsh
# Builds the Mac app for direct download: archive (Release, Developer ID,
# hardened runtime) → notarize → staple → Database.zip for GitHub Releases.
#
#   Scripts/release.sh [version]
#
# version defaults to the project's MARKETING_VERSION. Notarization needs a
# notarytool keychain profile, created once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id AUCR797TMH
# and passed as NOTARY_PROFILE=<profile>; without it the zip is signed but
# not notarized (Gatekeeper will warn). Publishing stays manual: the script
# prints the `gh release create` command instead of running it.
set -euo pipefail
cd "${0:A:h}/.."

TEAM=AUCR797TMH
OUT=build/release
VERSION=${1:-$(xcodebuild -project Database.xcodeproj -scheme Database -showBuildSettings 2>/dev/null \
  | awk '/ MARKETING_VERSION = / { print $3; exit }')}
ARCHIVE=$OUT/Database.xcarchive
APP=$OUT/Database.app
ZIP=$OUT/Database.zip

rm -rf $OUT && mkdir -p $OUT
echo "==> Archiving Database $VERSION"
# xcodebuild-release is xcodebuild with the release link every v57 app ships with (LTO, ld-archive-prelink,
# actool-icon-slim: unused package code goes, the icon's fallbacks as HEVC), from the Code checkout beside this
# repo's main checkout (RELEASE_TOOLS: another copy of Code's Sources/CodeActions/Release).
release=${RELEASE_TOOLS:-${$(git rev-parse --path-format=absolute --git-common-dir):h:h}/Code/Sources/CodeActions/Release}/xcodebuild-release
[[ -x $release ]] || { echo "xcodebuild-release not found at $release (RELEASE_TOOLS: Code's Sources/CodeActions/Release)" >&2; exit 1 }
$release -project Database.xcodeproj -scheme Database -configuration Release \
  -destination 'generic/platform=macOS' -archivePath $ARCHIVE archive \
  MARKETING_VERSION=$VERSION \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$TEAM \
  OTHER_CODE_SIGN_FLAGS=--timestamp -quiet
ditto $ARCHIVE/Products/Applications/Database.app $APP
codesign --verify --strict --deep $APP

if [[ -n ${NOTARY_PROFILE:-} ]]; then
  echo "==> Notarizing"
  ditto -c -k --keepParent $APP $OUT/notarize.zip
  xcrun notarytool submit $OUT/notarize.zip --keychain-profile $NOTARY_PROFILE --wait
  xcrun stapler staple $APP
  rm $OUT/notarize.zip
  spctl --assess --type execute --verbose $APP
else
  echo "==> NOTARY_PROFILE not set: skipping notarization (the build is signed only)"
fi

ditto -c -k --keepParent $APP $ZIP
echo "==> $ZIP ($(du -h $ZIP | cut -f1) zipped, app $(du -sh $APP | cut -f1))"
echo "Publish (stable link: https://github.com/v57/Database/releases/latest/download/Database.zip):"
echo "  gh release create v$VERSION $ZIP --repo v57/Database --title \"Database $VERSION\" --generate-notes"
