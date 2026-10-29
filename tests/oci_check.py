#!/usr/bin/env python3
"""An OCI image layout checker that shares no code with ufo (doc/kit.md §6).

    oci_check.py <layout>                 → checks, prints one JSON summary line
    oci_check.py <layout> --entries N     → also the tar entries of layer N, one per line

Checks: oci-layout version, index → manifest → config/layers resolve; every blob's
sha256 and size match its descriptor; media types; config.rootfs.diff_ids equal
sha256 of each gunzipped layer; JSON parses.  Exit 1 with a message on the first
violation.  Summary: {"manifest": digest, "layers": [{digest, diff_id, annotations,
media_type}], "arch": …, "ref": …}.
"""
import gzip
import hashlib
import json
import os
import sys
import tarfile


def fail(msg):
    print("oci_check: " + msg, file=sys.stderr)
    sys.exit(1)


def blob(root, desc, kind):
    dg = desc.get("digest", "")
    if not dg.startswith("sha256:"):
        fail(f"{kind}: digest {dg!r} is not sha256")
    path = os.path.join(root, "blobs", "sha256", dg[7:])
    if not os.path.isfile(path):
        fail(f"{kind}: blob {dg} missing")
    data = open(path, "rb").read()
    if "sha256:" + hashlib.sha256(data).hexdigest() != dg:
        fail(f"{kind}: blob {dg} does not match its digest")
    if desc.get("size") != len(data):
        fail(f"{kind}: size {desc.get('size')} != {len(data)}")
    return data


def main():
    root = sys.argv[1]
    want_entries = None
    if "--entries" in sys.argv:
        want_entries = int(sys.argv[sys.argv.index("--entries") + 1])
    lay = json.load(open(os.path.join(root, "oci-layout")))
    if lay.get("imageLayoutVersion") != "1.0.0":
        fail("oci-layout: imageLayoutVersion is not 1.0.0")
    index = json.load(open(os.path.join(root, "index.json")))
    if index.get("schemaVersion") != 2 or not index.get("manifests"):
        fail("index.json: schemaVersion 2 with at least one manifest expected")
    mref = index["manifests"][0]
    if mref.get("mediaType") != "application/vnd.oci.image.manifest.v1+json":
        fail("index.json: manifest media type " + str(mref.get("mediaType")))
    man = json.loads(blob(root, mref, "manifest"))
    if man.get("schemaVersion") != 2:
        fail("manifest: schemaVersion")
    cfg_desc = man["config"]
    if cfg_desc.get("mediaType") != "application/vnd.oci.image.config.v1+json":
        fail("config media type " + str(cfg_desc.get("mediaType")))
    cfg = json.loads(blob(root, cfg_desc, "config"))
    diff_ids = cfg.get("rootfs", {}).get("diff_ids", [])
    if cfg.get("rootfs", {}).get("type") != "layers":
        fail("config.rootfs.type is not layers")
    if len(diff_ids) != len(man.get("layers", [])):
        fail(f"{len(diff_ids)} diff_ids for {len(man.get('layers', []))} layers")
    layers = []
    for i, ld in enumerate(man.get("layers", [])):
        if ld.get("mediaType") != "application/vnd.oci.image.layer.v1.tar+gzip":
            fail(f"layer {i}: media type {ld.get('mediaType')}")
        gz = blob(root, ld, f"layer {i}")
        tar = gzip.decompress(gz)
        did = "sha256:" + hashlib.sha256(tar).hexdigest()
        if did != diff_ids[i]:
            fail(f"layer {i}: diff_id {diff_ids[i]} != sha256 of the tar {did}")
        layers.append({"digest": ld["digest"], "diff_id": did, "media_type": ld["mediaType"],
                       "annotations": ld.get("annotations", {})})
        if want_entries == i:
            import io
            with tarfile.open(fileobj=io.BytesIO(tar), format=tarfile.PAX_FORMAT) as tf:
                for m in tf.getmembers():
                    kind = {tarfile.REGTYPE: "f", tarfile.AREGTYPE: "f", tarfile.DIRTYPE: "d",
                            tarfile.SYMTYPE: "l", tarfile.LNKTYPE: "h", tarfile.CHRTYPE: "c",
                            tarfile.BLKTYPE: "b", tarfile.FIFOTYPE: "p"}.get(m.type, "?")
                    x = sorted(k[13:] for k in m.pax_headers if k.startswith("SCHILY.xattr."))
                    extra = m.linkname if kind in "lh" else (f"{m.devmajor}:{m.devminor}" if kind in "cb" else "")
                    print(f"{kind} {m.mode:04o} {m.uid}:{m.gid} {m.name} {extra} {','.join(x)}".rstrip())
    out = {"manifest": mref["digest"], "layers": layers,
           "arch": mref.get("platform", {}).get("architecture", cfg.get("architecture")),
           "ref": mref.get("annotations", {}).get("org.opencontainers.image.ref.name", "")}
    if want_entries is None:
        print(json.dumps(out, sort_keys=True))


main()
