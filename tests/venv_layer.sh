#!/bin/bash
# The aiml venv as a layer (aiml spec/69 §5): a stage creates it in its root, the upper
# directory goes in as a layer, and `ufo layer apply` gives back a venv that works where it
# lands — after `aiml venv` there rewrote its env (F69-14).
#   UFO=./ufo AIML=<build-tree or venv aiml> tests/venv_layer.sh
set -u
cd "$(dirname "$0")/.."
UFO="${UFO:-./ufo}"
AIML="${AIML:-$(command -v aiml)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
[ -x "$AIML" ] || { echo "  FAIL no aiml compiler (set AIML)"; exit 1; }
export GIT_COMMITTER_NAME=cosmos GIT_COMMITTER_EMAIL=cosmos@example.org GIT_COMMITTER_DATE="1700000000 +0000"
R="$WORK/repo"
$UFO init "$R" > /dev/null

echo "the venv stage: aiml venv into the stage's root"
UPPER="$WORK/upper"
"$AIML" venv "$UPPER/opt/aiml" > /dev/null 2>&1
check "venv created" "$([ -f "$UPPER/opt/aiml/env" ] && echo yes)" "yes"
VENV=$($UFO -C "$R" layer commit "$UPPER" --pipeline aiml --stage venv --run 1 2>/dev/null)
check "committed as a layer" "${#VENV}" "40"
check "the layer holds only the venv" "$(git -C "$R" ls-tree --name-only -r "$VENV" | grep -v '^\.ufo-attributes$' | sort | tr '\n' ,)" \
  "opt/aiml/bin/aiml,opt/aiml/env,opt/aiml/lib/aiml/aiml.packages.json,opt/aiml/lib/libaiml.so,"

echo "checked out elsewhere"
ROOT="$WORK/root"
$UFO -C "$R" layer apply "$ROOT" aiml/venv 2>/dev/null
check "bin/aiml executable" "$([ -x "$ROOT/opt/aiml/bin/aiml" ] && echo yes)" "yes"
check "same compiler bytes" "$(cmp -s "$UPPER/opt/aiml/bin/aiml" "$ROOT/opt/aiml/bin/aiml" && echo same)" "same"
"$ROOT/opt/aiml/bin/aiml" venv "$ROOT/opt/aiml" > /dev/null 2>&1
check "aiml venv rewrites env for the new place" "$(sh -c ". '$ROOT/opt/aiml/env'; echo \$AIML")" "$ROOT/opt/aiml/bin/aiml"
printf -- '- def:\n    name: main\n    return: i32\n    body:\n      - print: ["hallo aus dem layer"]\n      - return: 0\n' > "$WORK/hallo.aiml"
check "aiml from PATH runs a program" \
  "$(cd "$WORK" && env -i HOME="$WORK" AIML_CACHE="$WORK/cache" sh -c ". '$ROOT/opt/aiml/env'; aiml hallo.aiml" 2>&1)" "hallo aus dem layer"
check "nothing outside the venv was needed" "$(ls "$ROOT")" "opt"

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
