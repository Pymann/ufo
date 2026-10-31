#!/bin/bash
# Package → kontor → download → run: the exodus distribution path end to end.
#   AIML_BIN=/path/to/aiml KONTOR_DIR=../kontor tests/package.sh
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
KONTOR_DIR="${KONTOR_DIR:-../kontor}"
PORT="${PORT:-18233}"
WORK="$(mktemp -d)"
PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
[ -f "$KONTOR_DIR/kontor.aiml" ] || { echo "SKIP: no kontor at $KONTOR_DIR"; exit 0; }
VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' exodus.json | head -1)"

A="$(scripts/package.sh "$WORK/a")"; B="$(scripts/package.sh "$WORK/b")"
check "archive is reproducible" "$(cmp -s "$A" "$B" && echo same)" "same"
check "archive layout" "$(tar tzf "$A" | grep -cE "^ufo-$VERSION/(exodus.json|ufo.aiml|lib/layer.aiml|README.md)$")" "4"

TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
mkdir -p "$WORK/data"
# a server already on the port would be tested instead of ours
if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then echo "FAIL port $PORT is in use"; exit 1; fi
# exec: $! is kontor itself, so the trap stops it (not just the subshell)
(cd "$KONTOR_DIR" && KONTOR_ADMIN_TOKEN="$TOKEN" AIML_MEM_V3=1 exec "$AIML_BIN" kontor.aiml -- "$PORT" "$WORK/data" > "$WORK/kontor.log" 2>&1) & PIDS="$!"
for _ in $(seq 150); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" && break; sleep 0.2; done
KONTOR_URL="http://127.0.0.1:$PORT" KONTOR_TOKEN="$TOKEN" OUT="$WORK/pub" scripts/publish.sh > "$WORK/publish.log" 2>&1
check "publish" "$?" "0"
check "token not echoed" "$(grep -c "$TOKEN" "$WORK/publish.log")" "0"
check "manifest from kontor" "$(curl -s "http://127.0.0.1:$PORT/exodus/ufo/$VERSION/exodus.json" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -1)" "ufo"
curl -s -o "$WORK/dl.tar.gz" "http://127.0.0.1:$PORT/exodus/ufo/$VERSION/package"
check "package bytes" "$(sha256sum < "$WORK/dl.tar.gz")" "$(sha256sum < "$A")"
mkdir -p "$WORK/consumer" && tar xzf "$WORK/dl.tar.gz" -C "$WORK/consumer"
U="env AIML_MEM_V3=1 $AIML_BIN $WORK/consumer/ufo-$VERSION/ufo.aiml --"
$U init "$WORK/r" > /dev/null 2>&1
mkdir -p "$WORK/up/etc"; printf 'x\n' > "$WORK/up/etc/x"
L=$($U -C "$WORK/r" layer commit "$WORK/up" -p pkg -s test 2>/dev/null)
check "unpacked ufo runs" "$(git -C "$WORK/r" rev-parse refs/layers/pkg/test)" "$L"

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
