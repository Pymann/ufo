#!/bin/bash
# ufo.kit MuseumKit against a live museum (doc/kit.md §6).
#   AIML_BIN=/path/to/aiml MUSEUM_DIR=../museum UFO=./ufo tests/kit_museum.sh
set -u
cd "$(dirname "$0")/.."
UFO="${UFO:-./ufo}"
AIML_BIN="${AIML_BIN:-aiml}"
MUSEUM_DIR="${MUSEUM_DIR:-../museum}"
PORT="${PORT:-18341}"
WORK="$(mktemp -d)"; PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1"; }
[ -f "$MUSEUM_DIR/museum.aiml" ] || { echo "SKIP: no museum at $MUSEUM_DIR"; exit 0; }
TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
mkdir -p "$WORK/data"
(cd "$MUSEUM_DIR" && MUSEUM_ADMIN_TOKEN="$TOKEN" AIML_MEM_V3=1 "$AIML_BIN" museum.aiml -- "$PORT" "$WORK/data" > "$WORK/museum.log" 2>&1) & PIDS="$!"
for _ in $(seq 150); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/health" && break; sleep 0.2; done
URL="http://127.0.0.1:$PORT"

# two stages, as cosmos lays them down (same shapes as tests/kit.sh)
L="$WORK/layers"; mkdir -p "$L/0/upper/etc" "$L/1/upper/etc"
printf 'root:x:0:0\n' > "$L/0/upper/etc/passwd"; printf 'old\n' > "$L/0/upper/etc/marke"
printf 'stage=base\nrun=run-7\nagent=a1\n' > "$L/0/layer.meta"
mknod "$L/1/upper/etc/marke" c 0 0 2>/dev/null || printf '' > "$L/1/upper/etc/.wh.marke"
printf 'new\n' > "$L/1/upper/etc/motd"
printf 'stage=build\nbindings=arch=amd64\nrun=run-7\nagent=a1\n' > "$L/1/layer.meta"
$UFO image export-layers "$L" "$WORK/img" --ref build > /dev/null 2>&1
MAN=$(python3 tests/oci_check.py "$WORK/img" | json /dev/stdin "j['manifest']")

export UFO_REGISTRY_TOKEN="$TOKEN"
D1=$($UFO image push "$WORK/img" cosmos-layers/demo:run-7 --registry "$URL" --artifact-type application/vnd.cosmos.run-layers.v1+json 2> "$WORK/push.err")
check "push prints a sha256 digest" "$(echo "$D1" | grep -cE '^sha256:[0-9a-f]{64}$')" "1"
curl -s -H "Authorization: Bearer $TOKEN" "$URL/api/v1/layers/demo/run-7" > "$WORK/run.json"
check "museum lists the run's stages" "$(json "$WORK/run.json" "[s['stage'] for s in j['stages']]")" "['base', 'build']"
check "with their bindings and agent" "$(json "$WORK/run.json" "j['stages'][1]['bindings'] + ' ' + j['stages'][1]['agent']")" "arch=amd64 a1"
D2=$($UFO image pull cosmos-layers/demo:run-7 "$WORK/back" --registry "$URL" 2>/dev/null)
check "pull: same manifest digest" "$D2" "$D1"
check "pulled layout is valid" "$(python3 tests/oci_check.py "$WORK/back" > /dev/null 2>&1; echo $?)" "0"
$UFO image import "$WORK/img" "$WORK/r1" > /dev/null 2>&1; $UFO image import "$WORK/back" "$WORK/r2" > /dev/null 2>&1
check "same rootfs from both" "$(cd "$WORK/r2" && find . | sort | md5sum)" "$(cd "$WORK/r1" && find . | sort | md5sum)"
D3=$($UFO image push "$WORK/img" cosmos-layers/demo:again --registry "$URL" 2>/dev/null)
check "second push (blobs exist) works" "$(echo "$D3" | grep -c '^sha256:')" "1"
UFO_REGISTRY_TOKEN=wrong-token $UFO image push "$WORK/img" cosmos-layers/demo:x --registry "$URL" > "$WORK/bad.out" 2> "$WORK/bad.err"
check "wrong token → exit 1, no digest" "$? $(cat "$WORK/bad.out")" "1 "
check "token in no output or log" "$(cat "$WORK/push.err" "$WORK/bad.err" "$WORK/bad.out" | grep -c -e "$TOKEN" -e wrong-token)" "0"
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
