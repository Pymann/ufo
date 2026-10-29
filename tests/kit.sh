#!/bin/bash
# ufo.kit (doc/kit.md §6): layers ⇄ OCI image, through the LayoutKit — no network.
#   UFO=./ufo tests/kit.sh            (root: overlayfs, device nodes, owners, trusted.* xattrs)
#   COSMOS_RT_OCI=/path/to/cosmos-oci COSMOS_BASE=/path/to/rt_base  → part B as well
#   (COSMOS_RT: the cosmos-rt helper it runs, default: next to COSMOS_RT_OCI)
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
# what a rootfs is: type, mode, owner, path, link target; contents; device numbers
listing() { (cd "$1" && find . -mindepth 1 -printf '%y %m %U:%G %p %l\n' | sort; \
             find . -type f -exec md5sum {} + | sort -k2; \
             find . \( -type c -o -type b \) | sort | while read -r d; do echo "$d $(stat -c '%t:%T' "$d")"; done); }
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1"; }
export GIT_COMMITTER_NAME=cosmos GIT_COMMITTER_EMAIL=cosmos@example.org GIT_COMMITTER_DATE="1700000000 +0000"

echo "A. export / import / registry (LayoutKit)"
B="$WORK/base"; mkdir -p "$B"/{etc,usr/bin,opt/alt/deep,var/empty,home/user,srv}
printf 'root:x:0:0\n' > "$B/etc/passwd"; printf 'old\n' > "$B/etc/marke"
printf '#!/bin/sh\necho hi\n' > "$B/usr/bin/hi"; chmod 4755 "$B/usr/bin/hi"
ln -s hi "$B/usr/bin/hello"; ln "$B/etc/passwd" "$B/etc/passwd.hard"
printf 'a\n' > "$B/opt/alt/a"; printf 'b\n' > "$B/opt/alt/deep/b"
chmod 1777 "$B/var/empty"; chown 1000:1000 "$B/home/user"; chmod 700 "$B/home/user"
mknod "$B/etc/null" c 1 3; mkfifo "$B/etc/pipe"
long="$B/srv/$(printf 'n%.0s' $(seq 1 120))"; mkdir -p "$long"; printf 'deep\n' > "$long/file-with-a-long-path"
xset "$B/usr/bin/hi" user.origin base
L="$WORK/layers"; mkdir -p "$L/0"; cp -a "$B" "$L/0/upper"
printf 'stage=base\nrun=r7\nagent=a1\n' > "$L/0/layer.meta"
mkdir -p "$WORK"/{ovw,merged} "$L/1/upper"
if mount -t overlay overlay -o "lowerdir=$B,upperdir=$L/1/upper,workdir=$WORK/ovw" "$WORK/merged" 2>/dev/null; then
  M="$WORK/merged"
  rm "$M/etc/marke"                                                       # whiteout
  rm -rf "$M/opt/alt"; mkdir "$M/opt/alt"; printf 'new\n' > "$M/opt/alt/n" # opaque
  printf 'root:x:0:0\nuser:x:1000:1000\n' > "$M/etc/passwd"
  mkdir -p "$M/srv/data"; printf 'd\n' > "$M/srv/data/d"; chown 33:33 "$M/srv/data"
  rm "$M/usr/bin/hello"
  EXPECT="$(listing "$M")"
  umount "$M"
else
  echo "  (no overlayfs here — building the upper the way the kernel would)"
  U="$L/1/upper"; mkdir -p "$U/etc" "$U/opt/alt" "$U/srv/data" "$U/usr/bin"
  mknod "$U/etc/marke" c 0 0; mknod "$U/usr/bin/hello" c 0 0
  xset "$U/opt/alt" trusted.overlay.opaque y; printf 'new\n' > "$U/opt/alt/n"
  printf 'root:x:0:0\nuser:x:1000:1000\n' > "$U/etc/passwd"; printf 'd\n' > "$U/srv/data/d"; chown 33:33 "$U/srv/data"
  R0="$WORK/expect"; cp -a "$B" "$R0"; rm "$R0/etc/marke" "$R0/usr/bin/hello"; rm -rf "$R0/opt/alt"; mkdir "$R0/opt/alt"
  printf 'new\n' > "$R0/opt/alt/n"; cp "$U/etc/passwd" "$R0/etc/passwd"; mkdir -p "$R0/srv/data"; printf 'd\n' > "$R0/srv/data/d"; chown 33:33 "$R0/srv/data"
  EXPECT="$(listing "$R0")"
fi
printf 'stage=build\nbindings=arch=amd64\nrun=r7\nagent=a1\n' > "$L/1/layer.meta"

$UFO image export-layers "$L" "$WORK/img1" --ref build --arch amd64 > "$WORK/exp.log" 2>&1
check "export-layers exits 0" "$?" "0"
python3 tests/oci_check.py "$WORK/img1" > "$WORK/sum1.json" 2> "$WORK/chk.err"
check "an independent reader accepts the layout" "$? $(cat "$WORK/chk.err")" "0 "
check "two stages, two layers" "$(json "$WORK/sum1.json" "len(j['layers'])")" "2"
check "layer annotations from layer.meta" "$(json "$WORK/sum1.json" "sorted(j['layers'][1]['annotations'].items())")" \
      "[('cosmos.agent', 'a1'), ('cosmos.bindings', 'arch=amd64'), ('cosmos.run', 'r7'), ('cosmos.stage', 'build')]"
check "ref name and arch" "$(json "$WORK/sum1.json" "j['ref'] + ' ' + j['arch']")" "build amd64"
ENTRIES1="$(python3 tests/oci_check.py "$WORK/img1" --entries 1)"
check "whiteouts in the tar" "$(echo "$ENTRIES1" | grep -cE '^f 0[0-7]+ 0:0 (\./)?(etc/\.wh\.marke|usr/bin/\.wh\.hello)$')" "2"
check "opaque marker in the tar" "$(echo "$ENTRIES1" | grep -cE '(\./)?opt/alt/\.wh\.\.wh\.\.opq')" "1"
check "no overlay xattr in the tar" "$(echo "$ENTRIES1" | grep -c 'overlay')" "0"
check "owner 33:33 kept" "$(echo "$ENTRIES1" | grep -cE '^d [0-7]+ 33:33 (\./)?srv/data$')" "1"
ENTRIES0="$(python3 tests/oci_check.py "$WORK/img1" --entries 0)"
check "setuid kept" "$(echo "$ENTRIES0" | grep -cE '^f 4755 0:0 (\./)?usr/bin/hi .*user.origin')" "1"
check "device node" "$(echo "$ENTRIES0" | grep -cE '^c 0644 0:0 (\./)?etc/null 1:3')" "1"
check "fifo" "$(echo "$ENTRIES0" | grep -cE '^p [0-7]+ 0:0 (\./)?etc/pipe')" "1"
check "hard link" "$(echo "$ENTRIES0" | grep -cE '^h [0-7]+ 0:0 (\./)?etc/passwd(\.hard)? (\./)?etc/passwd(\.hard)?$')" "1"
check "symlink" "$(echo "$ENTRIES0" | grep -cE '^l [0-7]+ 0:0 (\./)?usr/bin/hello hi')" "1"
check "long path (pax)" "$(echo "$ENTRIES0" | grep -c 'file-with-a-long-path')" "1"
$UFO image export-layers "$L" "$WORK/img2" --ref build --arch amd64 > /dev/null 2>&1
check "reproducible: same upper, same digest" "$(python3 tests/oci_check.py "$WORK/img2" | json /dev/stdin "j['manifest']")" "$(json "$WORK/sum1.json" "j['manifest']")"

$UFO image import "$WORK/img1" "$WORK/root1" --arch amd64 > "$WORK/imp.log" 2>&1
check "import exits 0" "$?" "0"
check "import = what overlayfs showed" "$(listing "$WORK/root1")" "$EXPECT"
check "xattr restored" "$(xget "$WORK/root1/usr/bin/hi" user.origin)" "base"
check "no marker files in the rootfs" "$(find "$WORK/root1" -name '.wh.*' | wc -l)" "0"

D1=$($UFO image push "$WORK/img1" demo/app:v1 --root "$WORK/reg" 2>/dev/null)
check "push prints the manifest digest" "$D1" "$(json "$WORK/sum1.json" "j['manifest']")"
D2=$($UFO image pull demo/app:v1 "$WORK/img3" --root "$WORK/reg" 2>/dev/null)
check "pull: same digest" "$D2" "$D1"
$UFO image import "$WORK/img3" "$WORK/root3" > /dev/null 2>&1
check "pulled image imports to the same rootfs" "$(listing "$WORK/root3")" "$EXPECT"
$UFO image push "$WORK/img1" demo/app:run-layers --root "$WORK/reg" --artifact-type application/vnd.cosmos.run-layers.v1+json > /dev/null 2>&1
check "artifact type in the pushed manifest" "$(python3 -c "
import json,sys,os
r=sys.argv[1]; i=json.load(open(os.path.join(r,'index.json'))); d=i['manifests'][0]['digest'][7:]
print(json.load(open(os.path.join(r,'blobs','sha256',d))).get('artifactType',''))" "$WORK/reg/demo/app/run-layers")" "application/vnd.cosmos.run-layers.v1+json"

$UFO image export-dir "$B" "$WORK/imgd" --ref base > /dev/null 2>&1
check "export-dir: one layer" "$(python3 tests/oci_check.py "$WORK/imgd" | json /dev/stdin "len(j['layers'])")" "1"
$UFO image import "$WORK/imgd" "$WORK/rootd" > /dev/null 2>&1
check "export-dir + import = the directory" "$(listing "$WORK/rootd")" "$(listing "$B")"

echo "A. errors"
check "export-layers of a missing dir" "$($UFO image export-layers "$WORK/nope" "$WORK/x" 2>&1 | grep -c 'is not a directory')" "1"
mkdir -p "$WORK/emptylayers"
check "no layers" "$($UFO image export-layers "$WORK/emptylayers" "$WORK/x" 2>&1 | grep -c 'no layers under')" "1"
check "import, wrong arch" "$($UFO image import "$WORK/img1" "$WORK/rx" --arch arm64 2>&1 | grep -c 'no manifest for arm64')" "1"
cp -r "$WORK/img1" "$WORK/bad"; L0=$(json "$WORK/sum1.json" "j['layers'][0]['digest'][7:]"); printf 'x' >> "$WORK/bad/blobs/sha256/$L0"
check "import, corrupted blob" "$($UFO image import "$WORK/bad" "$WORK/rb" 2>&1 | grep -c 'does not match its digest')" "1"

if [ -n "${COSMOS_RT_OCI:-}" ] && [ -x "$COSMOS_RT_OCI" ]; then
  echo "B. cosmos compatibility"
  # cosmos' converter runs tar/cp in a user namespace: no real device nodes, no
  # owners outside its mapping (whiteouts 0:0 are fine).  So part B uses the
  # same layers without those two shapes and compares against ufo's own import.
  CRT="${COSMOS_RT:-$(dirname "$COSMOS_RT_OCI")/cosmos-rt}"
  LB="$WORK/layers_b"; cp -a "$L" "$LB"; rm -f "$LB/0/upper/etc/null"
  chown -hR 0:0 "$LB"; chmod 4755 "$LB/0/upper/usr/bin/hi"; chmod 700 "$LB/0/upper/home/user"
  $UFO image export-layers "$LB" "$WORK/imgb" --ref build > /dev/null 2>&1
  $UFO image import "$WORK/imgb" "$WORK/rootb" > /dev/null 2>&1
  REF_B="$(listing "$WORK/rootb")"
  "$COSMOS_RT_OCI" --image "$WORK/imgb" --bundle "$WORK/cb" --base "$COSMOS_BASE" --rtbin "$CRT" --work "$WORK/cwork" > "$WORK/cos1.log" 2>&1 || grep -iE "tar:|ERROR" "$WORK/cos1.log" | head -5
  # the bundle's /dev holds cosmos' own mount targets — not part of the image
  check "cosmos imports what ufo exported" "$(listing "$WORK/cb/rootfs" | grep -vE '\./dev( |/|$)')" "$REF_B"
  "$COSMOS_RT_OCI" --layers "$LB" --image "$WORK/cimg" --ref-name build --base "$COSMOS_BASE" --rtbin "$CRT" --work "$WORK/cwork" > "$WORK/cos2.log" 2>&1 || grep -iE "tar:|ERROR" "$WORK/cos2.log" | head -5
  $UFO image import "$WORK/cimg" "$WORK/cr" > /dev/null 2>&1
  check "ufo imports what cosmos exported" "$(listing "$WORK/cr")" "$REF_B"
else
  echo "B. cosmos compatibility: skipped (COSMOS_RT_OCI not set)"
fi

echo "C. history"
$UFO init "$WORK/repo" > /dev/null
check "record: two layers" "$($UFO -C "$WORK/repo" image record "$WORK/img1" --pipeline demo 2>/dev/null)" "2"
check "refs per stage" "$(git -C "$WORK/repo" for-each-ref --format='%(refname)' refs/layers/ | tr '\n' ,)" "refs/layers/demo/base,refs/layers/demo/build,"
check "trailers" "$(git -C "$WORK/repo" log -1 --format=%B refs/layers/demo/build | grep -E '^Ufo-(Stage|Run|Agent|Binding|Digest)' | cut -d: -f1 | tr '\n' ,)" "Ufo-Stage,Ufo-Run,Ufo-Agent,Ufo-Binding,Ufo-Digest,"
check "digest trailer = layer digest" "$(git -C "$WORK/repo" log -1 --format=%B refs/layers/demo/build | sed -n 's/^Ufo-Digest: //p')" "$(json "$WORK/sum1.json" "j['layers'][1]['digest']")"
check "git fsck" "$(git -C "$WORK/repo" fsck --strict 2>&1 | grep -vc '^Checking\|^notice')" "0"
DIRECT=$($UFO -C "$WORK/repo" layer commit "$L/1/upper" -p direct -s build --no-ref 2>/dev/null)
check "tree from the tar = tree from the upper dir" "$(git -C "$WORK/repo" rev-parse refs/layers/demo/build^{tree})" "$(git -C "$WORK/repo" rev-parse "$DIRECT^{tree}")"
check "recording again changes nothing" "$($UFO -C "$WORK/repo" image record "$WORK/img1" --pipeline demo 2>/dev/null) $(git -C "$WORK/repo" rev-list --count refs/layers/demo/build)" "0 1"

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
