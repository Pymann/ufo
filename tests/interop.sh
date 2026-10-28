#!/bin/bash
# ufo ⇄ real git, object store and packs.
#   UFO=./ufo tests/interop.sh          (or UFO="aiml ufo.aiml --")
#
#   1. ufo writes blobs/trees/commits/refs  → git fsck --strict, git log, git cat-file agree
#   2. git writes and packs (gc: deltas)     → ufo reads every object back with the right id
#   3. ufo index-pack on git's pack          → byte-identical .idx
#   4. ufo pack-objects                      → git index-pack / verify-pack accept it
#   5. ufo checkout-tree                     → same files as git checkout (modes, symlinks)
set -u
cd "$(dirname "$0")/.."
UFO="${UFO:-./ufo}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
export GIT_AUTHOR_NAME=ufo GIT_AUTHOR_EMAIL=ufo@example.org GIT_AUTHOR_DATE="1700000000 +0000"
export GIT_COMMITTER_NAME=ufo GIT_COMMITTER_EMAIL=ufo@example.org GIT_COMMITTER_DATE="1700000000 +0000"

echo "1. ufo writes, git reads"
R1="$WORK/r1"
$UFO init "$R1" > /dev/null
mkdir -p "$WORK/src/bin" "$WORK/src/etc/empty-not-stored" "$WORK/src/deep/er"
printf 'hello\n' > "$WORK/src/a.txt"
printf '#!/bin/sh\necho hi\n' > "$WORK/src/bin/run"; chmod +x "$WORK/src/bin/run"
printf 'x' > "$WORK/src/deep/er/leaf"
head -c 70000 /dev/urandom > "$WORK/src/blob.bin"
ln -s a.txt "$WORK/src/link"
TREE=$($UFO -C "$R1" write-tree "$WORK/src")
check "write-tree = git's tree for the same files" "$TREE" "$(cd "$WORK/src" && git init -q . 2>/dev/null; git add -A . && git write-tree; rm -rf .git)"
C1=$($UFO -C "$R1" commit-tree "$TREE" -m "first layer")
check "commit-tree id = git commit-tree id" "$C1" "$(git -C "$R1" commit-tree "$TREE" -m "first layer")"
printf 'changed\n' > "$WORK/src/a.txt"
TREE2=$($UFO -C "$R1" write-tree "$WORK/src")
C2=$($UFO -C "$R1" commit-tree "$TREE2" -p "$C1" -m "second layer")
$UFO -C "$R1" update-ref refs/heads/main "$C2"
check "git fsck --strict" "$(git -C "$R1" fsck --strict 2>&1 | grep -v '^Checking' | wc -l)" "0"
check "git log" "$(git -C "$R1" log --format=%s | tr '\n' ,)" "second layer,first layer,"
check "git cat-file blob" "$(git -C "$R1" show main:a.txt)" "changed"
check "ufo log" "$($UFO -C "$R1" log | cut -d' ' -f2- | tr '\n' ,)" "second layer,first layer,"

echo "2. git writes and packs, ufo reads"
R2="$WORK/r2"
git init -q "$R2"
for i in $(seq 1 30); do
  seq 1 $((200 + i)) > "$R2/numbers.txt"            # deltas against earlier versions
  printf 'v%s\n' "$i" > "$R2/version"
  git -C "$R2" add -A && git -C "$R2" commit -q -m "rev $i"
done
git -C "$R2" tag -a v1 -m "annotated" > /dev/null
git -C "$R2" gc -q --aggressive
PACK=$(ls "$R2"/.git/objects/pack/*.pack | head -1)
check "git made a delta pack" "$([ "$(git verify-pack -v "${PACK%.pack}.idx" | grep -c ' delta ')" -gt 0 ] || [ "$(git verify-pack -v "${PACK%.pack}.idx" | grep -cE 'chain length')" -gt 0 ] && echo yes)" "yes"
OBJS=$(git -C "$R2" rev-list --objects --all | cut -d' ' -f1)
BAD=0; N=0
for o in $OBJS; do
  N=$((N + 1))
  [ "$($UFO -C "$R2" cat-file -t "$o")" = "$(git -C "$R2" cat-file -t "$o")" ] || BAD=$((BAD + 1))
done
check "ufo cat-file -t on all $N objects" "$BAD" "0"
check "ufo cat-file blob from a delta" "$($UFO -C "$R2" cat-file -p HEAD~3:numbers.txt | md5sum)" "$(git -C "$R2" cat-file -p HEAD~3:numbers.txt | md5sum)"
check "ufo verify-pack (ids recomputed)" "$($UFO verify-pack "${PACK%.pack}" | tail -1)" "$(git -C "$R2" count-objects -v | awk '/in-pack/{print $2}') object(s), 0 bad"
check "ufo rev-parse packed tag" "$($UFO -C "$R2" rev-parse refs/tags/v1)" "$(git -C "$R2" rev-parse refs/tags/v1)"
check "ufo log on packed history" "$($UFO -C "$R2" log | wc -l)" "30"

echo "3. index-pack"
cp "$PACK" "$WORK/copy.pack"
$UFO index-pack "$WORK/copy.pack" > /dev/null
check "ufo .idx byte-identical to git's" "$(cmp -s "$WORK/copy.idx" "${PACK%.pack}.idx" && echo same)" "same"

echo "4. pack-objects"
LIST=$(git -C "$R1" rev-list --objects main | cut -d' ' -f1 | tr '\n' ' ')
$UFO -C "$R1" pack-objects "$WORK/ours" $LIST > /dev/null
check "git verify-pack accepts ufo's pack" "$(git verify-pack "$WORK/ours.idx" > /dev/null 2>&1 && echo ok)" "ok"
mkdir "$WORK/gitidx"; cp "$WORK/ours.pack" "$WORK/gitidx/"
git index-pack "$WORK/gitidx/ours.pack" > /dev/null 2>&1
check "git index-pack = ufo's .idx" "$(cmp -s "$WORK/gitidx/ours.idx" "$WORK/ours.idx" && echo same)" "same"

echo "5. checkout-tree"
$UFO -C "$R1" checkout-tree main "$WORK/out" > /dev/null
git -C "$R1" --work-tree="$WORK/gitout" checkout -q main -- . 2>/dev/null || { mkdir -p "$WORK/gitout"; git -C "$R1" --work-tree="$WORK/gitout" checkout -q main -- .; }
check "same files" "$(diff -r "$WORK/out" "$WORK/gitout" > /dev/null && echo same)" "same"
check "exec bit kept" "$([ -x "$WORK/out/bin/run" ] && echo x)" "x"
check "symlink kept" "$(readlink "$WORK/out/link")" "a.txt"

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
