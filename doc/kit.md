# ufo.kit — the layer kit (a group interface, aiml spec/58 §12)

Status: **implemented 2026-10-28** — tests/kit.sh 39/39 (incl. part B against
cosmos-oci), tests/kit_kontor.sh 9/9 against a live kontor,
tests/test_kit_contract.aiml PASS, memcheck clean (0 errors).

Implementation notes:
- One tar reader for everything (`ufo.tarlayer.read_tar` → `TarSink`): the
  applier (import) and the importer (history) are two sinks.  It reads headers
  only; contents stay in the file.
- Import walks each layer twice: markers first (opaque clears, `.wh.` removes),
  then the entries — independent of where a marker sits in the tar.  Paths with
  `..` and writes through a symlinked parent are refused.
- Known limit: the aiml HTTP client buffers a response body in memory before
  `save_to` writes it, so `pull` of a multi-GB layer needs that much RAM
  (aiml runtime, to be streamed).
- Part B uses a fixture without real device nodes and foreign owners: cosmos'
  converter runs tar/cp in a user namespace that cannot create them.  Once
  cosmos imports through this kit that restriction disappears.

cosmos produces one filesystem layer per pipeline stage, exports them as an OCI
image, pushes that to kontor, pulls images back and lays them out as a rootfs.
Until now cosmos did this with its own code: a shell converter (`cp -al`, `find`,
`tar`, `gzip`, `sha256sum` in a helper container) and a kontor client.  ufo does
the same work for its own layer commits.  **One implementation, in ufo** — cosmos
imports it as an exodus package (`- import: "@ufo/lib/kit/…"`, aiml spec/21 §3.1)
and depends only on the contract.

## 1. The contract

```yaml
# @ufo/lib/kit/api.aiml — namespace ufo.kit
- interface:
    name: Images                 # layers ⇄ OCI image layout (a directory)
    methods:
      - [export_layers, i32, [[layers, string], [layout, string], [ref_name, string], [arch, string]]]
      - [export_dir,    i32, [[dir, string], [layout, string], [ref_name, string], [arch, string]]]
      - [import_image,  i32, [[layout, string], [rootfs, string], [arch, string]]]
- interface:
    name: Registry               # an OCI layout ⇄ a repository:tag
    methods:
      - [push, string, [[layout, string], [reference, string], [artifact_type, string]]]
      - [pull, string, [[reference, string], [layout, string]]]
- interface:
    name: History                # an image's layers as ufo layer commits (git)
    methods:
      - [record, i32, [[layout, string], [pipeline, string]]]

- groupinterface:
    name: LayerKit
    exports:
      - [images, Images]
      - [registry, Registry]
      - [history, History]
```

Two implementations, both in `@ufo/lib/kit/`:

| group | `registry` talks to | params |
|---|---|---|
| `ufo.kit.KontorKit` | an OCI distribution registry over HTTP (kontor's `/v2/`) | `url`, `token` (Bearer; empty = anonymous), `git_dir`, `work_dir` |
| `ufo.kit.LayoutKit` | a directory of layouts on disk (`<root>/<repo>/<tag>/`) — offline, tests, `oci:` targets | `root`, `git_dir`, `work_dir` |

`images` and `history` are the same classes in both.  A user builds one kit at its
composition root and hands it on as `ptr<ufo.kit.LayerKit>`:

```yaml
- decl: [kit, ptr<ufo.kit.LayerKit>, { new: ufo.kit.KontorKit, url: "https://kontor", token: tok, git_dir: g, work_dir: w }]
- decl: [rc, i32, { call: [kit.images.export_layers, layers, layout, "build", "amd64"] }]
- decl: [digest, string, { call: [kit.registry.push, layout, "cosmos-layers/demo:run-7", ""] }]
```

## 2. `images`

### 2.1 `export_layers(layers, layout, ref_name, arch) → 0 | 1`

`layers` is a cosmos run's layer root: `<layers>/0/upper`, `<layers>/1/upper`, …
(the numbers are stage positions; gaps are skipped), each optionally with
`<n>/layer.meta` (`key=value` lines).  Result: an OCI image layout at `layout`
(`oci-layout`, `index.json`, `blobs/sha256/…`) with **one layer per stage**, in
order, plus config and manifest.

Each layer is the stage's **upper directory as overlayfs left it**, turned into an
OCI layer tar:

- a char device 0:0 → an empty file `.wh.<name>` (whiteout);
- a directory with xattr `trusted.overlay.opaque=y` or `user.overlay.opaque=y` →
  an empty `.wh..wh..opq` inside it;
- every other xattr except `trusted.overlay.*` / `user.overlay.*` → a pax
  `SCHILY.xattr.<name>` record (e.g. `security.capability`);
- owner as numbers (uid/gid), mode incl. setuid/setgid/sticky, device nodes, fifos,
  symlinks; a second name of a hard-linked file → a tar hard link;
- **reproducible**: entries sorted by path, POSIX (pax) format with fixed header
  names, no atime/ctime, each entry's mtime from the file itself (a marker gets
  the mtime of the entry it replaces / of its directory), gzip without name and
  time.  The same upper directory always gives the same digest.
- streaming: no file is held in memory as a whole; layers of many GB work.

Per layer: `diff_id` = sha256 of the uncompressed tar, blob = gzip of it
(`application/vnd.oci.image.layer.v1.tar+gzip`), descriptor annotations
`cosmos.<key>` for every `layer.meta` line (`stage`, `bindings`, `agent`, `run`, …,
kontor doc/ecosystem.md §3).

Config (`application/vnd.oci.image.config.v1+json`): `architecture: arch`,
`os: linux`, `rootfs: {type: layers, diff_ids: […]}`, `config: {Env: [PATH=…],
Cmd: ["/bin/sh"]}`, `created` fixed to `1970-01-01T00:00:00Z` (reproducible).
Manifest: `schemaVersion: 2`, media type
`application/vnd.oci.image.manifest.v1+json`.  `index.json`: one manifest with
`platform {architecture: arch, os: linux}` and annotation
`org.opencontainers.image.ref.name: ref_name`.  JSON is written with sorted keys
and no whitespace, so digests are reproducible too.

Errors (return 1, message to the log): `layers` is not a directory; no
`<n>/upper` under it ("no layers under …"); a file cannot be read.

### 2.2 `export_dir(dir, layout, ref_name, arch) → 0 | 1`

One layer from a plain directory (a rootfs), same rules as §2.1 (there are simply no
whiteouts in it).  Errors: `dir` missing or empty.

### 2.3 `import_image(layout, rootfs, arch) → 0 | 1`

Reads `index.json`, picks the manifest for `arch` (error if none), verifies each
blob's sha256 against its descriptor, and applies the layers **in order** onto
`rootfs` (created if missing): an opaque marker clears the directory's lower
content first, a `.wh.<name>` removes `<name>`, then the entries are written —
mode, owner (when permitted: root or a user namespace; otherwise ignored), device
nodes and fifos (when permitted), symlinks, hard links, xattrs, mtimes.  Marker
files never appear in the rootfs.  Errors: no `index.json`, no manifest for
`arch`, a digest mismatch ("blob … does not match its digest").

## 3. `registry`

`reference` = `<repository>:<tag>` or `<repository>@sha256:<hex>`.

### 3.1 `push(layout, reference, artifact_type) → manifest digest | ""`

Uploads every blob the manifest names that the registry does not have yet
(`HEAD` → skip; else `POST /v2/<repo>/blobs/uploads/` + `PUT …?digest=`, monolithic,
streamed from the file), then `PUT /v2/<repo>/manifests/<tag>`.  A non-empty
`artifact_type` is written into the manifest (`artifactType`, e.g.
`application/vnd.cosmos.run-layers.v1+json`).  Returns the manifest's digest
(`sha256:…`, as the registry reports it, else computed).  `LayoutKit` copies the
layout to `<root>/<repo>/<tag>/` instead and returns the same digest.

### 3.2 `pull(reference, layout) → manifest digest | ""`

The reverse: manifest (`Accept`: OCI manifest + index, Docker v2 manifest + list;
an index → the `linux/<arch>` entry of the host's architecture is NOT guessed —
the first manifest is taken and its platform recorded in `index.json`), config and
layer blobs, each verified against its digest while it is written, into a fresh
layout.

Auth (`KontorKit`): `token` → `Authorization: Bearer <token>`; the token is never
written to a log.  An HTTP error → `""` and a log line with the status, never the
token.

## 4. `history`

### 4.1 `record(layout, pipeline) → number of layers recorded | -1`

Reads the image in `layout` and turns **each layer** into a ufo layer commit in the
git repository `git_dir` (ufo layer format, README "Layers"): tree from the tar
headers (no unpacking, so owners/devices/xattrs need no privileges), parent = the
current `refs/layers/<pipeline>/<stage>`, trailers from the descriptor annotations
(`Ufo-Stage` from `cosmos.stage`, `Ufo-Run` from `cosmos.run`, `Ufo-Agent`,
`Ufo-Binding` per binding) plus `Ufo-Digest: <layer digest>` and
`Ufo-Image: <manifest digest>`.  A layer without `cosmos.stage` is named `layer<N>`.
The same layer recorded twice for the same run is not committed again.

This is the base of the converter that shows file changes from layer to layer like
`git diff` (later: one "rootfs commit" per stage, the stacked result, so
`git diff refs/rootfs/<p>/<a> refs/rootfs/<p>/<b>` is a real diff).

## 5. Command line (thin over the kit)

```
ufo image export-layers <layers> <layout> [--ref <name>] [--arch <arch>]
ufo image export-dir    <dir> <layout>    [--ref <name>] [--arch <arch>]
ufo image import        <layout> <rootfs> [--arch <arch>]
ufo image push <layout> <reference> (--registry <url> | --root <dir>) [--artifact-type <t>]
ufo image pull <reference> <layout> (--registry <url> | --root <dir>)
ufo [-C <git-dir>] image record <layout> --pipeline <p>
```

`--registry` builds a `KontorKit` (token from `UFO_REGISTRY_TOKEN`, never from the
command line), `--root` a `LayoutKit`; `--ref` defaults to `latest`, `--arch` to
`amd64`.  push/pull print the manifest digest; every command exits 0 on success, 1
with a message otherwise.  The CLI holds only `ptr<ufo.kit.LayerKit>` — it is the
first user of the contract.

## 6. Tests

| test | checks |
|---|---|
| `tests/kit.sh` part A (LayoutKit, no network) | an overlay upper as the kernel writes it (real overlayfs mount where permitted, else the same shapes via mknod/xattrs): `export_layers` → layout passes a reader written independently in Python (digests, diff_ids, sizes, media types, annotations); reproducible (two exports, one digest); `import_image` → rootfs equals the merged overlay view (types, modes, owners, devices, symlinks, contents, xattr); push/pull through `LayoutKit` keep the digest |
| `tests/kit.sh` part B (cosmos compatibility) | the layout ufo writes is read by cosmos' existing importer; a layout cosmos' exporter wrote is imported by ufo — same rootfs |
| `tests/kit.sh` part C (history) | `record` → one commit per stage under `refs/layers/<p>/<stage>` with the trailers; `git fsck` clean; the tree equals `ufo layer commit` of the same upper |
| `tests/kit_kontor.sh` (KontorKit, live kontor) | push → kontor's `/api/v1/layers/<p>/<run>` lists the stages with their annotations; pull into a fresh layout → same manifest digest, same rootfs; wrong token → `""`, token not in any log |
| `tests/test_kit_contract.aiml` | user code that names only `ptr<ufo.kit.LayerKit>` drives both kits (aiml spec/58 §12) |
| valgrind | the contract test under memcheck: no memory errors, no leak from generated code |
