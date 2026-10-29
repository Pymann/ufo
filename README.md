# ufo

ufo is a git client written in aiml. On top of git it versions **layers**,
the filesystem results that cosmos pipeline stages leave behind. A layer is a
normal git commit, so layers can be diffed, fetched and pushed the way code
is, and identical results are stored once.

ufo writes what git reads, and reads what git writes:

- **Object store**: loose objects, packfiles (v2 + idx v2, OFS/REF deltas,
  large offsets), `index-pack` that writes idx files byte-identical to git's,
  packed refs, and revision syntax (`HEAD~2^2:dir/file`).
- **Smart HTTP**: `ls-remote`, `clone` and `fetch` over protocol v2, and
  `push` over receive-pack with report-status. Pushes that are not
  fast-forward are refused unless forced with `+`, and ref deletes work.
  Authentication uses `UFO_HTTP_TOKEN` (Bearer) or
  `UFO_HTTP_USER` + `UFO_HTTP_PASSWORD` (Basic).
- **Layers**: overlay upper directories go in as commits under
  `refs/layers/<pipeline>/<stage>`, and stacking them gives back a rootfs.

## Commands

```
ufo [-C <dir>] <command> …

init [--bare] [<dir>]             clone <url> [<dir>]          ls-remote <url>
remote add <name> <url>           fetch [<remote>]             push <remote|url> [+]<src>[:<dst>]…
hash-object [-w] <file>           cat-file (-t|-s|-p|<kind>) <obj>
write-tree <dir>                  ls-tree <tree>               checkout-tree <tree> <dir>
commit-tree <tree> [-p <p>]… -m <msg>                          update-ref <ref> <obj>
rev-parse <rev>   show-ref   log [<rev>]
pack-objects <base> <obj>…        index-pack <file.pack>       verify-pack <base>

layer commit <upper-dir> --pipeline <p> --stage <s> [--run <r>] [--step <k>] [--agent <a>]
             [--binding <k=v>]… [--base <layer>]… [--uid-shift <n>] [-m <note>] [--no-ref]
layer apply <dir> <layer>… [--upper | --oci]
layer list [<pipeline>]   layer log <p>/<s>   layer show <layer>   layer diff <old|-> <new|->
```

Where a command takes `<layer>`, you can give anything `rev-parse` accepts,
or `<pipeline>/<stage>[~N]` as a short form for `refs/layers/<pipeline>/<stage>`.
Commit identities come from `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, the same
variables git uses.

## Layers

A stage runs on an overlayfs. Its *upper* directory holds everything the
stage changed:

- files it added or modified;
- a char device 0:0 for each path it deleted (a whiteout);
- a directory with `trusted.overlay.opaque=y` (or `user.overlay.opaque`) when
  it replaced a directory as a whole.

`ufo layer commit` stores that upper directory as a git tree using the OCI
whiteout convention, which any git can read:

| tree entry | meaning |
|---|---|
| `<path>` | file / symlink / directory content (git modes 100644, 100755, 120000) |
| `<dir>/.wh.<name>` | `<name>` was deleted by this layer |
| `<dir>/.wh..wh..opq` | `<dir>` is opaque: everything the lower layers had there is gone |
| `<dir>/.ufo-keep` | `<dir>` is empty |
| `.ufo-attributes` | what a git tree cannot hold, sorted, one line per path |

`.ufo-attributes` has two kinds of line:

```
<kind> <perm> <uid> <gid> <dev> <path>      kind: f d l c b p s, perm octal, dev "maj:min" or "-"
x <xattr-name> <hex-value> <path>
```

A line is written only where a path differs from the defaults: owner 0:0,
0644 or 0755 according to the git mode, and no xattrs. That covers
setuid/setgid/sticky bits, private files, ownership, device nodes, fifos,
sockets and xattrs such as `security.capability`. Device nodes, fifos and
sockets also appear in the tree as an empty placeholder blob, so that
`layer diff` shows them. mtimes are not recorded, so that the same result
always gives the same tree. For uploads from a user namespace,
`--uid-shift <n>` maps host ids ≥ n back to 0….

The commit message is `layer <pipeline>/<stage> run <run>`, followed by trailers:

```
Ufo-Pipeline: demo
Ufo-Stage: build
Ufo-Run: 7
Ufo-Step: build/1
Ufo-Agent: agent-3
Ufo-Binding: arch=amd64          (one per binding)
Ufo-Base: <commit>               (the layers this one was built on)
```

The commit's parent is the previous run of the same stage, so `layer log`
gives the run history and `layer diff demo/build~1 demo/build` shows what
the last run changed (`A`/`D`/`M` paths, `W` whiteouts, `O` opaque
directories, `+a`/`-a` attribute lines).

`layer apply <dir> <lowest> … <highest>` stacks layers. Whiteouts delete
paths, opaque markers clear directories, and attributes are applied last
(owners and device nodes need root or a user namespace; otherwise ufo warns
and leaves placeholders). `--upper` writes a single layer back in overlay
form (char 0:0 whiteouts and the opaque xattr), which can be mounted
directly. `--oci` keeps `.wh.` files, so tarring the directory gives an OCI
layer.

Layer refs are ordinary refs:
`ufo push <git-url> refs/layers/demo/build` publishes them, and
`ufo fetch` / `git fetch '+refs/layers/*:refs/layers/*'` brings them back.

Limits: hard links are stored as separate files (the content is still
stored once), and `.ufo-attributes` and `.ufo-keep` are reserved names.

## Images

`ufo image` turns layers into OCI images and back, moves images to and from a
registry and records them as layer commits — the layer kit (doc/kit.md), which
cosmos uses too:

```
ufo image export-layers <layers> <layout> [--ref <name>] [--arch <arch>]   # <layers>/<n>/upper (+ layer.meta)
ufo image export-dir    <dir> <layout>    [--ref <name>] [--arch <arch>]   # one layer from a rootfs
ufo image import        <layout> <rootfs> [--arch <arch>]
ufo image push <layout> <repo>:<tag> (--registry <url> | --root <dir>) [--artifact-type <t>]
ufo image pull <repo>:<tag> <layout> (--registry <url> | --root <dir>)
ufo [-C <git-dir>] image record <layout> --pipeline <p>   # one layer commit per stage
```

Exports are reproducible (sorted pax tar, fixed timestamps in config and gzip):
the same upper directory always gives the same digest. Whiteouts, opaque
directories, owners, modes, device nodes, fifos, hard links, symlinks and
xattrs survive export and import. `--registry` talks to an OCI distribution
registry such as kontor (`UFO_REGISTRY_TOKEN` = Bearer token, never on the
command line, never logged); `--root` uses a directory of layouts instead.

In aiml code the kit is one contract, `ufo.kit.LayerKit` (lib/kit/api.aiml),
with two implementations, `ufo.kit.KontorKit` and `ufo.kit.LayoutKit`.

## Building

ufo needs an aiml compiler with the `bytes`, `hash.sha1` and `fsmeta`
builtins and method calls on `shared<Class>` — aiml `mem-v3-compiler` from 34c3340 on
(feature/git-support-memv3 and fix/shared-method-call-memv3 are merged there) — and memV3
(`AIML_MEM_V3=1`). `ufo image` additionally needs classgroup interfaces, the
file-streaming `bytes` builtins and the fixes for namespaced classes/classgroups
and the HTTP client — aiml `mem-v3-compiler` from 58efe0c on.

```
exodus build                      # ./ufo, with ../aiml as in exodus.json
exodus build -c exodus.local.json # an untracked config pointing at your own aiml build
AIML_MEM_V3=1 aiml ufo.aiml -- <command> …   # without building (JIT)
```

## Tests

```
UFO=./ufo tests/interop.sh   # object store / packs against git (18 checks)
UFO=./ufo tests/remote.sh    # smart HTTP against git http-backend (26 checks)
UFO=./ufo tests/layer.sh     # layers against a real overlayfs mount (33 checks; root)
UFO=./ufo AIML=aiml tests/venv_layer.sh   # the aiml venv (aiml spec/68) as a layer and back (8 checks)
AIML_MEM_V3=1 aiml tests/test_object.aiml
AIML_BIN=aiml KONTOR_DIR=../kontor tests/package.sh   # package → kontor → download → run
UFO=./ufo tests/kit.sh       # images: export/import/registry/history (39 checks with cosmos; root)
AIML_BIN=aiml KONTOR_DIR=../kontor UFO=./ufo tests/kit_kontor.sh   # KontorKit against a live kontor
AIML_MEM_V3=1 aiml tests/test_kit_contract.aiml                    # one user, two kits
```
`tests/kit.sh` part B runs when `COSMOS_RT_OCI` (cosmos' `cosmos-oci`) and
`COSMOS_BASE` are set.

## Distribution through kontor

`scripts/package.sh` writes `out/ufo-<version>.tar.gz`, a reproducible source
archive (the same sources always give the same bytes).
`scripts/publish.sh` uploads it to kontor's exodus repository:

```
KONTOR_URL=https://kontor.example.org KONTOR_TOKEN=… scripts/publish.sh
#  PUT /exodus/ufo/<version>/exodus.json
#  PUT /exodus/ufo/<version>/package
```

Consumers download `/exodus/ufo/<version>/package` and unpack it. They can
then run `exodus build` in `ufo-<version>/`, or import the modules
(`lib/repo.aiml`, `lib/pack.aiml`, `lib/remote.aiml`, `lib/layer.aiml`, …;
namespaces `ufo.*`) into their own aiml project.

## Layout

```
ufo.aiml           entry point
lib/object.aiml    object framing, trees, commits
lib/repo.aiml      repository: objects, refs, revisions
lib/pack.aiml      reading packs (+ deltas)
lib/packwrite.aiml writing packs, index-pack
lib/walk.aiml      reachability (what to send)
lib/pktline.aiml   pkt-line framing
lib/remote.aiml    smart HTTP transport, fetch, push
lib/worktree.aiml  directory ⇄ tree
lib/layer.aiml     layer scan / commit / apply
lib/layerdiff.aiml layer diff
lib/layercli.aiml  `ufo layer …`
lib/tarlayer.aiml  tar reader (streaming) + layer tree from a tar
lib/identity.aiml  commit identity from the environment
lib/kit/           the layer kit: contract (api, contracts), OciImages, tar
                   writer/applier, Layout, DirRegistry, HttpRegistry,
                   LayerHistory, LayoutKit, KontorKit
lib/imagecli.aiml  `ufo image …`
lib/cli.aiml       the command line
```
