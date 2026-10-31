#!/bin/bash
# Publish ufo to kontor's exodus repository:
#   KONTOR_URL=https://kontor.example.org KONTOR_TOKEN=… scripts/publish.sh
#     PUT /exodus/ufo/<version>/exodus.json   the manifest (kontor checks name/version)
#     PUT /exodus/ufo/<version>/package       the source archive from package.sh
# The token goes to curl through a header file, never onto its command line.
set -eu
cd "$(dirname "$0")/.."
: "${KONTOR_URL:?set KONTOR_URL}"
: "${KONTOR_TOKEN:?set KONTOR_TOKEN (a kontor token with the writer role)}"
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' exodus.json | head -1)"
PKG="$(scripts/package.sh "${OUT:-out}")"
HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT
chmod 600 "$HDR"; printf 'Authorization: Bearer %s\n' "$KONTOR_TOKEN" > "$HDR"
BASE="${KONTOR_URL%/}/exodus/ufo/$VERSION"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$HDR" -X PUT --data-binary @exodus.json "$BASE/exodus.json")
[ "$code" = "201" ] || [ "$code" = "200" ] || { echo "manifest upload failed: HTTP $code" >&2; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$HDR" -X PUT --data-binary @"$PKG" "$BASE/package")
[ "$code" = "201" ] || [ "$code" = "200" ] || { echo "package upload failed: HTTP $code" >&2; exit 1; }
echo "published ufo $VERSION → $BASE"
