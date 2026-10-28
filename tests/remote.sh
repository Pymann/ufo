#!/bin/bash
# ufo ⇄ a real git server over smart HTTP (git http-backend), both directions.
#   UFO=./ufo tests/remote.sh
#
#   ls-remote / clone / fetch (protocol v2) from a repository git made
#   push (receive-pack) into a bare repository, then `git clone` + fsck it
#   push a branch update, a new ref outside refs/heads, a delete; auth
set -u
cd "$(dirname "$0")/.."
UFO="${UFO:-./ufo}"
WORK="$(mktemp -d)"
PORT="${PORT:-18471}"
PIDS=""
trap 'kill $PIDS 2>/dev/null; rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
export GIT_AUTHOR_NAME=ufo GIT_AUTHOR_EMAIL=ufo@example.org GIT_AUTHOR_DATE="1700000000 +0000"
export GIT_COMMITTER_NAME=ufo GIT_COMMITTER_EMAIL=ufo@example.org GIT_COMMITTER_DATE="1700000000 +0000"

mkdir -p "$WORK/srv"
# a source repository with history, a tag and an extra ref namespace
git init -q -b main "$WORK/seed"
for i in 1 2 3 4 5; do seq 1 $((100 * i)) > "$WORK/seed/data.txt"; git -C "$WORK/seed" add -A; git -C "$WORK/seed" commit -q -m "c$i"; done
git -C "$WORK/seed" tag v1
git -C "$WORK/seed" update-ref refs/layers/demo/build HEAD~1
git clone -q --bare "$WORK/seed" "$WORK/srv/source.git"
git -C "$WORK/seed" push -q "$WORK/srv/source.git" refs/layers/demo/build
git -C "$WORK/srv/source.git" gc -q
git init -q --bare -b main "$WORK/srv/target.git"
git -C "$WORK/srv/target.git" config http.receivepack true
python3 tests/git_http_server.py "$PORT" "$WORK/srv" 2> "$WORK/server.log" & PIDS="$PIDS $!"
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/source.git/info/refs?service=git-upload-pack" && break; sleep 0.1; done
URL="http://127.0.0.1:$PORT"

echo "fetch"
check "ls-remote" "$($UFO ls-remote "$URL/source.git" | sort)" "$(git ls-remote "$WORK/srv/source.git" | grep -v '\^{}' | sort)"
$UFO clone "$URL/source.git" "$WORK/clone" > "$WORK/clone.log" 2>&1
check "clone: HEAD" "$(git -C "$WORK/clone" rev-parse HEAD)" "$(git -C "$WORK/seed" rev-parse main)"
check "clone: git fsck" "$(git -C "$WORK/clone" fsck --strict 2>&1 | grep -vc '^Checking\|^notice')" "0"
check "clone: work tree" "$(md5sum < "$WORK/clone/data.txt")" "$(md5sum < "$WORK/seed/data.txt")"
check "clone: tag" "$(git -C "$WORK/clone" rev-parse refs/tags/v1)" "$(git -C "$WORK/seed" rev-parse v1)"
check "clone: layer ref" "$(git -C "$WORK/clone" rev-parse refs/layers/demo/build)" "$(git -C "$WORK/seed" rev-parse HEAD~1)"
check "clone: git log" "$(git -C "$WORK/clone" log --format=%s | tr '\n' ,)" "c5,c4,c3,c2,c1,"
# incremental fetch: only the new commit comes
printf 'more\n' >> "$WORK/seed/data.txt"; git -C "$WORK/seed" commit -qam c6
git -C "$WORK/seed" push -q "$WORK/srv/source.git" main
$UFO -C "$WORK/clone" fetch origin > "$WORK/fetch.log" 2>&1
check "fetch: new tip" "$(git -C "$WORK/clone" rev-parse refs/remotes/origin/main)" "$(git -C "$WORK/seed" rev-parse main)"
check "fetch: only what was missing" "$(grep -o 'fetched [0-9]* object' "$WORK/fetch.log")" "fetched 3 object"
check "fetch: fsck" "$(git -C "$WORK/clone" fsck --strict 2>&1 | grep -vc '^Checking\|^notice')" "0"

echo "push"
$UFO init "$WORK/mine" > /dev/null
mkdir -p "$WORK/content/sub"; printf 'pushed by ufo\n' > "$WORK/content/README"; printf 'x\n' > "$WORK/content/sub/x"
T1=$($UFO -C "$WORK/mine" write-tree "$WORK/content")
C1=$($UFO -C "$WORK/mine" commit-tree "$T1" -m "from ufo")
$UFO -C "$WORK/mine" update-ref refs/heads/main "$C1"
check "push main" "$($UFO -C "$WORK/mine" push "$URL/target.git" main)" "ok refs/heads/main "
check "server has it" "$(git -C "$WORK/srv/target.git" rev-parse main)" "$C1"
check "server fsck" "$(git -C "$WORK/srv/target.git" fsck --strict 2>&1 | grep -vc '^Checking\|^notice')" "0"
git clone -q "$WORK/srv/target.git" "$WORK/gitclone"
check "git clone of the pushed repo" "$(cat "$WORK/gitclone/README")" "pushed by ufo"
printf 'second\n' > "$WORK/content/README"
T2=$($UFO -C "$WORK/mine" write-tree "$WORK/content")
C2=$($UFO -C "$WORK/mine" commit-tree "$T2" -p "$C1" -m "second")
$UFO -C "$WORK/mine" update-ref refs/heads/main "$C2"
check "push update + layer ref" "$($UFO -C "$WORK/mine" push "$URL/target.git" main "$C1:refs/layers/demo/build" | tr '\n' ,)" "ok refs/heads/main ,ok refs/layers/demo/build ,"
check "server tip" "$(git -C "$WORK/srv/target.git" rev-parse main)" "$C2"
check "push again: up to date" "$($UFO -C "$WORK/mine" push "$URL/target.git" main)" "ok refs/heads/main up to date"
check "delete ref" "$($UFO -C "$WORK/mine" push "$URL/target.git" :refs/layers/demo/build)" "ok refs/layers/demo/build "
check "ref gone" "$(git -C "$WORK/srv/target.git" show-ref | grep -c layers)" "0"
check "non-fast-forward is refused" "$($UFO -C "$WORK/mine" push "$URL/target.git" "$C1:main" 2>&1 | grep -c '^ng refs/heads/main')" "1"

echo "auth"
kill $PIDS 2>/dev/null; sleep 0.3
python3 tests/git_http_server.py "$PORT" "$WORK/srv" "alice:s3cret" 2>> "$WORK/server.log" & PIDS="$!"
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
check "no credentials → refused" "$($UFO ls-remote "$URL/source.git" > /dev/null 2>&1; echo $?)" "1"
check "Basic credentials" "$(UFO_HTTP_USER=alice UFO_HTTP_PASSWORD=s3cret $UFO ls-remote "$URL/source.git" | grep -c refs/heads/main)" "1"

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
