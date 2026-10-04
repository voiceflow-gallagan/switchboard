#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: Tools/release.sh <version> --notes <file> [--repo owner/name] [--allow-dirty]" >&2
  echo "  <file> holds the What's new section for this version, in Markdown." >&2
  exit 64
}

VERSION=""
REPO="voiceflow-gallagan/switchboard"
ALLOW_DIRTY=0
WHATS_NEW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; WHATS_NEW="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    -*) usage ;;
    *) [ -z "$VERSION" ] || usage; VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || usage
[ -n "$WHATS_NEW" ] && [ -s "$WHATS_NEW" ] || { echo "--notes must name a non-empty file" >&2; usage; }

# The team comes from the ignored Config/Local.xcconfig, never from this script.
TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null | head -1)"
if [ -z "$TEAM_ID" ]; then
  echo "Config/Local.xcconfig must set DEVELOPMENT_TEAM. Copy Config/Local.xcconfig.example and fill it in." >&2
  exit 1
fi
NOTARY_PROFILE="switchboard"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/release"
ARCHIVE="$OUT/Switchboard.xcarchive"
EXPORT_DIR="$OUT/export"
APP="$EXPORT_DIR/Switchboard.app"
ZIP="$OUT/Switchboard-$VERSION.zip"
NOTES="$OUT/release-notes.md"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

cd "$ROOT"

echo "[1/9] Checking the development repository is clean"
DIRTY="$(git status --porcelain)"
if [ -n "$DIRTY" ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
  echo "Uncommitted changes present; commit them or pass --allow-dirty" >&2
  echo "$DIRTY" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "[2/9] Archiving Release build $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
  -project Switchboard.xcodeproj \
  -scheme Switchboard \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -quiet

echo "[3/9] Exporting the archive with Developer ID signing"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -quiet

echo "[4/9] Verifying the code signature"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
echo "$SIGN_INFO" | grep -q "Authority=Developer ID Application" \
  || { echo "Not signed with a Developer ID Application certificate" >&2; exit 1; }
echo "$SIGN_INFO" | grep -q "flags=0x10000(runtime)" \
  || { echo "Hardened runtime flag missing" >&2; exit 1; }
echo "$SIGN_INFO" | grep -E "Authority=Developer ID Application|flags="

echo "[5/9] Zipping the app"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "[6/9] Submitting to Apple notarization (this can take several minutes)"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$SUBMIT_OUT"
SUBMISSION_ID="$(echo "$SUBMIT_OUT" | awk '/^ *id:/ {print $2; exit}')"
STATUS="$(echo "$SUBMIT_OUT" | awk '/^ *status:/ {print $2}' | tail -1)"
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization status: ${STATUS:-unknown}" >&2
  [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2
  exit 1
fi

echo "[7/9] Stapling the ticket and re-zipping"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "[8/9] Assessing with Gatekeeper"
SPCTL_OUT="$(spctl --assess --type execute --verbose "$APP" 2>&1)"
echo "$SPCTL_OUT"
echo "$SPCTL_OUT" | grep -q "accepted" || { echo "Gatekeeper did not accept the app" >&2; exit 1; }
echo "$SPCTL_OUT" | grep -q "source=Notarized Developer ID" \
  || { echo "Source is not Notarized Developer ID" >&2; exit 1; }

echo "[9/9] Creating GitHub release v$VERSION on $REPO"
{
  cat "$WHATS_NEW"
  echo
  cat <<NOTES_EOF
Switchboard shows everything Claude Desktop and Claude Code load on your Mac in one window: MCP servers, plugins, and skills.
It reports what each server costs in memory and lets you switch items on or off per app or per project.

Requires macOS 14 or later.

Install: unzip Switchboard-$VERSION.zip, drag Switchboard to Applications, then open it.
NOTES_EOF
} > "$NOTES"
gh release create "v$VERSION" "$ZIP" \
  --repo "$REPO" \
  --title "Switchboard $VERSION" \
  --notes-file "$NOTES"

echo "Done: https://github.com/$REPO/releases/tag/v$VERSION"
