#!/bin/bash
# Publish ufo to museum's exodus repository:
#   MUSEUM_URL=https://museum.example.org MUSEUM_TOKEN=… scripts/publish.sh
#     PUT /exodus/ufo/<version>/exodus.json   the manifest (museum checks name/version)
#     PUT /exodus/ufo/<version>/package       the source archive from package.sh
# The token goes to curl through a header file, never onto its command line.
set -eu
cd "$(dirname "$0")/.."
: "${MUSEUM_URL:?set MUSEUM_URL}"
: "${MUSEUM_TOKEN:?set MUSEUM_TOKEN (a museum token with the writer role)}"
VERSION="$(python3 -c 'import json; print(json.load(open("exodus.json"))["version"])')"
PKG="$(scripts/package.sh "${OUT:-out}")"
HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT
chmod 600 "$HDR"; printf 'Authorization: Bearer %s\n' "$MUSEUM_TOKEN" > "$HDR"
BASE="${MUSEUM_URL%/}/exodus/ufo/$VERSION"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$HDR" -X PUT --data-binary @exodus.json "$BASE/exodus.json")
[ "$code" = "201" ] || [ "$code" = "200" ] || { echo "manifest upload failed: HTTP $code" >&2; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$HDR" -X PUT --data-binary @"$PKG" "$BASE/package")
[ "$code" = "201" ] || [ "$code" = "200" ] || { echo "package upload failed: HTTP $code" >&2; exit 1; }
echo "published ufo $VERSION → $BASE"
