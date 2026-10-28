#!/bin/bash
# ufo layers: overlay upper dirs as git commits, stacked back into a rootfs.
#   UFO=./ufo tests/layer.sh        (root: device nodes, owners, trusted.* xattrs;
#                                    the overlayfs part is skipped where mount fails)
set -u
cd "$(dirname "$0")/.."
UFO="${UFO:-./ufo}"
WORK="$(mktemp -d)"
trap 'umount "$WORK/merged" 2>/dev/null; rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
xset() { python3 -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode(), follow_symlinks=False)' "$@"; }
xget() { python3 -c 'import os,sys
try: print(os.getxattr(sys.argv[1], sys.argv[2], follow_symlinks=False).decode())
except OSError: print("")' "$@"; }
# a listing that covers what a rootfs is: type, mode, owner, device, target, content
listing() { (cd "$1" && find . -mindepth 1 ! -name .ufo-attributes -printf '%y %m %U:%G %p %l\n' | sort; \
             find . -type f ! -name .ufo-attributes -exec md5sum {} + | sort -k2; \
             find . -type c -o -type b | sort | while read -r d; do echo "$d $(stat -c '%t:%T' "$d")"; done); }
export GIT_COMMITTER_NAME=cosmos GIT_COMMITTER_EMAIL=cosmos@example.org GIT_COMMITTER_DATE="1700000000 +0000"
R="$WORK/repo"
$UFO init "$R" > /dev/null

echo "base layer (a plain directory)"
B="$WORK/base"; mkdir -p "$B"/{etc,usr/bin,opt/alt/deep,var/empty,home/user}
printf 'root:x:0:0\n' > "$B/etc/passwd"; printf 'old\n' > "$B/etc/marke"
printf '#!/bin/sh\necho hi\n' > "$B/usr/bin/hi"; chmod 755 "$B/usr/bin/hi"
ln -s hi "$B/usr/bin/hello"
printf 'a\n' > "$B/opt/alt/a"; printf 'b\n' > "$B/opt/alt/deep/b"
chmod 1777 "$B/var/empty"; chown 1000:1000 "$B/home/user"; chmod 700 "$B/home/user"
printf 'secret\n' > "$B/etc/shadow"; chmod 600 "$B/etc/shadow"
chmod 4755 "$B/usr/bin/hi"
mknod "$B/etc/null" c 1 3; mkfifo "$B/etc/pipe"
xset "$B/usr/bin/hi" user.origin base
BASE=$($UFO -C "$R" layer commit "$B" --pipeline demo --stage base --run 1 --agent a1 2>/dev/null)
check "commit prints an id" "${#BASE}" "40"
check "git reads it" "$(git -C "$R" cat-file -t "$BASE")" "commit"
check "git fsck" "$(git -C "$R" fsck --strict 2>&1 | grep -vc '^Checking\|^notice')" "0"
check "ref moved" "$(git -C "$R" rev-parse refs/layers/demo/base)" "$BASE"
check "trailers" "$(git -C "$R" log -1 --format=%B "$BASE" | grep '^Ufo-' | tr '\n' ,)" "Ufo-Pipeline: demo,Ufo-Stage: base,Ufo-Run: 1,Ufo-Agent: a1,"
check "empty dir kept" "$(git -C "$R" ls-tree --name-only "$BASE:var/empty")" ".ufo-keep"
ATTRS="$(git -C "$R" show "$BASE:.ufo-attributes")"
check "attr: sticky dir" "$(echo "$ATTRS" | grep -c '^d 1777 0 0 - var/empty$')" "1"
check "attr: owner" "$(echo "$ATTRS" | grep -c '^d 0700 1000 1000 - home/user$')" "1"
check "attr: setuid" "$(echo "$ATTRS" | grep -c '^f 4755 0 0 - usr/bin/hi$')" "1"
check "attr: 0600" "$(echo "$ATTRS" | grep -c '^f 0600 0 0 - etc/shadow$')" "1"
check "attr: char device" "$(echo "$ATTRS" | grep -c '^c 0644 0 0 1:3 etc/null$')" "1"
check "attr: fifo" "$(echo "$ATTRS" | grep -c '^p 0644 0 0 - etc/pipe$')" "1"
check "attr: xattr" "$(echo "$ATTRS" | grep -c "^x user.origin $(printf base | od -An -tx1 | tr -d ' \n') usr/bin/hi$")" "1"
check "defaults not recorded" "$(echo "$ATTRS" | grep -c 'etc/passwd')" "0"
check "symlink in git" "$(git -C "$R" cat-file -p "$BASE:usr/bin/hello")" "hi"

echo "again: same bytes → same tree, history grows"
AGAIN=$($UFO -C "$R" layer commit "$B" -p demo -s base --run 2 2>/dev/null)
check "same tree" "$(git -C "$R" rev-parse "$AGAIN^{tree}")" "$(git -C "$R" rev-parse "$BASE^{tree}")"
check "parent = previous run" "$(git -C "$R" rev-parse "$AGAIN^")" "$BASE"
check "layer log" "$($UFO -C "$R" layer log demo/base | awk '{print $5}' | tr '\n' ,)" "2,1,"
check "layer diff of equal runs" "$($UFO -C "$R" layer diff demo/base~1 demo/base)" ""

echo "stack: base → rootfs"
$UFO -C "$R" layer apply "$WORK/root1" demo/base 2>/dev/null
check "rootfs = base dir" "$(listing "$WORK/root1")" "$(listing "$B")"
check "xattr restored" "$(xget "$WORK/root1/usr/bin/hi" user.origin)" "base"

echo "an upper dir as overlayfs leaves it"
if mkdir -p "$WORK"/{upper,ovw,merged} && mount -t overlay overlay -o "lowerdir=$WORK/root1,upperdir=$WORK/upper,workdir=$WORK/ovw" "$WORK/merged" 2>/dev/null; then
  M="$WORK/merged"
  rm "$M/etc/marke"                              # whiteout
  rm -rf "$M/opt/alt"; mkdir "$M/opt/alt"; printf 'new\n' > "$M/opt/alt/n"   # opaque dir
  printf 'root:x:0:0\nuser:x:1000:1000\n' > "$M/etc/passwd"                  # changed
  mkdir -p "$M/srv/data"; printf 'd\n' > "$M/srv/data/d"; chown 33:33 "$M/srv/data"
  chmod 644 "$M/usr/bin/hi"                       # metadata-only change (copy-up)
  rm "$M/usr/bin/hello"
  EXPECT="$(listing "$M")"
  umount "$M"
  check "kernel wrote whiteouts" "$(stat -c '%F %t:%T' "$WORK/upper/etc/marke")" "character special file 0:0"
  check "kernel marked opaque" "$(xget "$WORK/upper/opt/alt" trusted.overlay.opaque)" "y"
  L2=$($UFO -C "$R" layer commit "$WORK/upper" -p demo -s build --run 7 --step build/1 --binding arch=amd64 --binding os=linux --base demo/base -m "built by test" 2>/dev/null)
  check "layer tree: whiteouts" "$(git -C "$R" ls-tree -r --name-only "$L2" | grep '\.wh\.' | tr '\n' ,)" "etc/.wh.marke,opt/alt/.wh..wh..opq,usr/bin/.wh.hello,"
  check "show" "$($UFO -C "$R" layer show "$L2" | grep -E '^(stage|run|binding|base|content)' | tr -s ' ' | tr '\n' ,)" "stage build,run 7,binding arch=amd64,binding os=linux,base $AGAIN,content 4 paths, 2 whiteouts, 1 opaque dirs, 2 attribute lines,"
  $UFO -C "$R" layer apply "$WORK/root2" demo/base demo/build 2>/dev/null
  check "base + layer = what overlayfs showed" "$(listing "$WORK/root2")" "$EXPECT"
  # overlay form back, then mount it: the same view again
  $UFO -C "$R" layer apply "$WORK/upper2" demo/build --upper 2>/dev/null
  check "--upper: whiteout device" "$(stat -c '%F %t:%T' "$WORK/upper2/etc/marke")" "character special file 0:0"
  check "--upper: opaque xattr" "$(xget "$WORK/upper2/opt/alt" trusted.overlay.opaque)" "y"
  mkdir -p "$WORK/ovw2" "$WORK/merged2"
  mount -t overlay overlay -o "lowerdir=$WORK/root1,upperdir=$WORK/upper2,workdir=$WORK/ovw2" "$WORK/merged2"
  check "--upper mounts to the same view" "$(listing "$WORK/merged2")" "$EXPECT"
  umount "$WORK/merged2"
  $UFO -C "$R" layer apply "$WORK/oci" demo/build --oci 2>/dev/null
  check "--oci: .wh. files" "$(cd "$WORK/oci" && find . -name '.wh.*' | sort | tr '\n' ,)" "./etc/.wh.marke,./opt/alt/.wh..wh..opq,./usr/bin/.wh.hello,"
  check "diff base→build" "$($UFO -C "$R" layer diff - demo/build | grep -v '^+a' | tr '\n' ,)" "A etc/passwd,A opt/alt/n,A srv/data/d,A usr/bin/hi,O opt/alt/,W etc/marke,W usr/bin/hello,"
  # the next run changes one file and drops a whiteout
  mount -t overlay overlay -o "lowerdir=$WORK/root1,upperdir=$WORK/upper,workdir=$WORK/ovw" "$WORK/merged"
  printf 'changed\n' > "$WORK/merged/srv/data/d"; printf 'back\n' > "$WORK/merged/etc/marke"
  umount "$WORK/merged"
  L3=$($UFO -C "$R" layer commit "$WORK/upper" -p demo -s build --run 8 2>/dev/null)
  check "diff run 7 → 8" "$($UFO -C "$R" layer diff demo/build~1 demo/build | tr '\n' ,)" "A etc/marke,D etc/.wh.marke,M srv/data/d,"
  check "list" "$($UFO -C "$R" layer list demo | awk '{print $2, $3}' | tr '\n' ,)" "demo/base 2,demo/build 8,"
else
  echo "  skip overlayfs part (mount not permitted)"
fi

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
