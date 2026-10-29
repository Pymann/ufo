#!/bin/bash
# Source package of ufo for kontor's exodus repository:
#   scripts/package.sh [<out-dir>]      → <out-dir>/ufo-<version>.tar.gz (default out/)
# The archive is reproducible (sorted, mtime 0, owner 0:0, gzip -n): the same
# sources give the same bytes, so kontor stores a re-publish once.
# It unpacks to ufo-<version>/ with exodus.json at the top: `exodus build` there
# (with an aiml that has the bytes/fsmeta builtins) builds the binary, and the
# lib/*.aiml modules can be imported by other aiml projects.
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-out}"
VERSION="$(python3 -c 'import json; print(json.load(open("exodus.json"))["version"])')"
NAME="ufo-$VERSION"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME"
cp -r ufo.aiml exodus.json README.md lib tests scripts "$STAGE/$NAME/"
find "$STAGE/$NAME" -name '__aiml_cache' -prune -exec rm -rf {} + 2>/dev/null || true
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
    -C "$STAGE" -cf - "$NAME" | gzip -n -9 > "$OUT/$NAME.tar.gz"
echo "$OUT/$NAME.tar.gz"
