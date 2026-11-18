#!/bin/bash
# Writes dist/appcast.xml, the feed DictBridge's in-app updater (Sparkle) reads, for the release
# that was just built by scripts/build-app.sh. Run by CI when a release is published.
#
#   SPARKLE_PRIVATE_KEY=… GH_TOKEN=… scripts/make-appcast.sh
#
# The .zip and the feed are signed with the project's EdDSA key; the app only installs updates
# whose signatures match the public key in Resources/sparkle-public-key.txt. The release notes
# shown in the update window are the GitHub release's text, rendered to HTML.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set (GitHub secret)}"
REPO="Andy7016/DictBridge-for-Mac"
PLIST="dist/DictBridge.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")"
ZIP="dist/DictBridge-$VERSION.zip"
TAG="v$VERSION"
SIGN=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN" ]] || { echo "sign_update not found (run swift package resolve)" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "$ZIP not found" >&2; exit 1; }

# sparkle:edSignature="…" length="…"
ENCLOSURE_SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$ZIP")"
[[ "$ENCLOSURE_SIGNATURE" == *edSignature=* ]] || { echo "signing failed" >&2; exit 1; }

NOTES_MD="$(gh release view "$TAG" --repo "$REPO" --json body -q .body 2>/dev/null || true)"
NOTES_HTML=""
if [[ -n "$NOTES_MD" ]]; then
  NOTES_HTML="$(gh api markdown -f text="$NOTES_MD" -f mode=gfm -f context="$REPO")"
fi
NOTES_HTML="${NOTES_HTML//]]>/]]&gt;}"

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DictBridge</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>DictBridge $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[$NOTES_HTML]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/DictBridge-$VERSION.zip"
                 type="application/octet-stream" $ENCLOSURE_SIGNATURE />
    </item>
  </channel>
</rss>
EOF

# The app requires a signed feed (SURequireSignedFeed); this embeds the signature.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN" --ed-key-file - dist/appcast.xml
xmllint --noout dist/appcast.xml
echo "==> dist/appcast.xml for $VERSION ($BUILD)"
cat dist/appcast.xml
