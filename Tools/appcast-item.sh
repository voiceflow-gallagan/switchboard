#!/bin/bash
# Prints one appcast <item> for a release. The notes file is Markdown with headings, bullets, and
# paragraphs; anything else is shown as text.
set -euo pipefail

usage() {
  echo "usage: Tools/appcast-item.sh <version> <build> <zip> <notes.md> [--repo owner/name] [--date RFC2822]" >&2
  exit 64
}

VERSION="" BUILD="" ZIP="" NOTES="" REPO="voiceflow-gallagan/switchboard" DATE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --date) [ $# -ge 2 ] || usage; DATE="$2"; shift 2 ;;
    -*) usage ;;
    *)
      if [ -z "$VERSION" ]; then VERSION="$1"
      elif [ -z "$BUILD" ]; then BUILD="$1"
      elif [ -z "$ZIP" ]; then ZIP="$1"
      elif [ -z "$NOTES" ]; then NOTES="$1"
      else usage; fi
      shift ;;
  esac
done
[ -n "$NOTES" ] || usage
[ -s "$NOTES" ] || { echo "notes file is missing or empty: $NOTES" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "zip is missing: $ZIP" >&2; exit 1; }
# These land in XML and in URLs unescaped, so only plain forms are accepted.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3: $VERSION" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "build must be a number: $BUILD" >&2; exit 1; }
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "repo must look like owner/name: $REPO" >&2; exit 1; }
grep -Fq ']]>' "$NOTES" && { echo "notes must not contain ]]>" >&2; exit 1; }
[ -n "$DATE" ] || DATE="$(LC_ALL=C date -R)"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_UPDATE="$(find "$ROOT/.build" -type f -path "*/artifacts/sparkle/Sparkle/bin/sign_update" -print -quit)"
[ -n "$SIGN_UPDATE" ] || { echo "sign_update not found; build the app once so the Sparkle package is resolved" >&2; exit 1; }

# sign_update prints: sparkle:edSignature="..." length="..."
SIGNATURE_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
case "$SIGNATURE_ATTRS" in
  sparkle:edSignature=*) ;;
  *) echo "sign_update gave no signature; is the key in the login keychain?" >&2; exit 1 ;;
esac

escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Markdown to HTML: "## " headings, "- " bullets, blank-line paragraphs. Bold **x** becomes <b>.
html() {
  escape | awk '
    function close_list() { if (in_list) { print "</ul>"; in_list = 0 } }
    function close_para() { if (in_para) { print "</p>"; in_para = 0 } }
    {
      gsub(/\*\*[^*]+\*\*/, "<b>&</b>"); gsub(/<b>\*\*/, "<b>"); gsub(/\*\*<\/b>/, "</b>")
    }
    /^## / { close_list(); close_para(); print "<h2>" substr($0, 4) "</h2>"; next }
    /^# / { close_list(); close_para(); print "<h1>" substr($0, 3) "</h1>"; next }
    /^- / { close_para(); if (!in_list) { print "<ul>"; in_list = 1 }; print "<li>" substr($0, 3) "</li>"; next }
    /^[[:space:]]*$/ { close_list(); close_para(); next }
    { close_list(); if (!in_para) { print "<p>"; in_para = 1 }; print }
    END { close_list(); close_para() }
  '
}

cat <<ITEM_EOF
    <item>
      <title>Switchboard $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <description><![CDATA[
$(html < "$NOTES")
      ]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Switchboard-$VERSION.zip" $SIGNATURE_ATTRS type="application/octet-stream" />
    </item>
ITEM_EOF
