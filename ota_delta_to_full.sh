#!/bin/sh
# ota_delta_to_full.sh BASE_PAYLOAD DELTA_PAYLOAD DELTA_DIR OUT_ZIP
#   BASE_PAYLOAD  full OTA payload of the base build      e.g. base/payload.bin
#   DELTA_PAYLOAD incremental payload                      e.g. delta/payload.bin
#   DELTA_DIR     dir holding the delta OTA metadata       e.g. delta
#   OUT_ZIP       full payload OTA package to write        e.g. out/TB710FU_....zip
# No error handling, no progress reporting. Fails on the first bad command.
set -e

B=$1; D=$2; DD=$3; Z=$4
H=$(cd "$(dirname "$0")" && pwd)
W=$(dirname "$Z")/work
OTA=$H/bin/ota_extractor
DG=$H/bin/delta_generator
SEC=$H/keys/testkey

rm -rf "$W"; mkdir -p "$W/base" "$W/new"

# 1. unpack base payload
$OTA --payload="$B" --output_dir="$W/base"

# 2. apply delta on top of the base images
$OTA --payload="$D" --input_dir="$W/base" --output_dir="$W/new"

# 3. dump partition list / dynamic partition metadata / timestamps from the delta manifest
openssl pkcs8 -inform DER -in "$SEC.pk8" -out "$W/key.pem" -nocrypt
cat > "$W/tool.py" <<"PY"
import os, sys, struct, zipfile, zlib
sys.modules.pop("google", None)
sys.path.insert(0, os.environ["PYLIB"])
META_SIZE = 4096
MPB_SIZE = 4096


def dump(delta, work):
    import update_metadata_pb2 as u
    f = open(delta, "rb")
    h = f.read(24)
    m = u.DeltaArchiveManifest()
    m.ParseFromString(f.read(struct.unpack(">Q", h[12:20])[0]))
    parts = [p.partition_name for p in m.partitions]
    open(work + "/parts.txt", "w").write(
        ":".join(parts) + "\n" + ":".join(work + "/new/" + p + ".img" for p in parts) + "\n")
    d = m.dynamic_partition_metadata
    o = ["super_partition_groups=" + " ".join(g.name for g in d.groups)]
    for g in d.groups:
        o.append("super_%s_group_size=%d" % (g.name, g.size))
        o.append("super_%s_partition_list=%s" % (g.name, " ".join(g.partition_names)))
    o.append("virtual_ab=%s" % ("true" if d.snapshot_enabled else "false"))
    o.append("virtual_ab_compression=%s" % ("true" if d.vabc_enabled else "false"))
    o.append("virtual_ab_compression_method=%s" % d.vabc_compression_param)
    o.append("virtual_ab_cow_version=%d" % d.cow_version)
    o.append("virtual_ab_compression_factor=%d" % d.compression_factor)
    o.append("disable_ublk=%s" % ("true" if d.disable_ublk else "false"))
    open(work + "/dyninfo.txt", "w").write("\n".join(o) + "\n")
    open(work + "/params.txt", "w").write("%d %s\n" % (m.max_timestamp, m.security_patch_level))


def crc_patch(zp, names):
    z = zipfile.ZipFile(zp)
    with open(zp, "r+b") as f:
        f.seek(0, 2)
        end = f.tell()
        start = max(0, end - 70000)
        f.seek(start)
        tail = f.read()
        for nm in names:
            i = z.getinfo(nm)
            f.seek(i.header_offset)
            h = f.read(30)
            nlen, elen = struct.unpack("<HH", h[26:30])
            usize = struct.unpack("<I", h[18:22])[0]
            f.seek(i.header_offset + 30 + nlen + elen)
            crc = zlib.crc32(f.read(usize)) & 0xffffffff
            f.seek(i.header_offset + 14)
            f.write(struct.pack("<I", crc))
            p = 0
            while True:
                j = tail.find(nm.encode(), p)
                if j < 0:
                    break
                if start + j - 46 >= start:
                    f.seek(start + j - 46)
                    if f.read(4) == b"PK\x01\x02":
                        f.seek(start + j - 46 + 16)
                        f.write(struct.pack("<I", crc))
                        break
                p = j + 1


def build(work, outzip, ddir):
    import ota_metadata_pb2 as om
    payload = work + "/payload.bin"
    props = work + "/payload_properties.txt"
    entries = [("META-INF/com/android/metadata", None, META_SIZE),
               ("META-INF/com/android/metadata.pb", None, MPB_SIZE),
               ("apex_info.pb", ddir + "/apex_info.pb", None),
               ("care_map.pb", ddir + "/care_map.pb", None),
               ("payload.bin", payload, None),
               ("payload_properties.txt", props, None),
               ("META-INF/com/android/otacert", os.environ["CERT"], None)]
    with zipfile.ZipFile(outzip, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        for name, src, fixed in entries:
            zi = zipfile.ZipInfo(name)
            zi.compress_type = zipfile.ZIP_STORED
            if src is None:
                zf.writestr(zi, b"\0" * fixed)
            else:
                zi.file_size = os.path.getsize(src)
                with open(src, "rb") as fin, zf.open(zi, "w", force_zip64=True) as fout:
                    while True:
                        b = fin.read(8 << 20)
                        if not b:
                            break
                        fout.write(b)
    with zipfile.ZipFile(outzip) as zf, open(outzip, "rb") as f:
        off, sz = {}, {}
        for i in zf.infolist():
            f.seek(i.header_offset)
            nlen, elen = struct.unpack("<HH", f.read(30)[26:30])
            off[i.filename] = i.header_offset + 30 + nlen + elen
            sz[i.filename] = i.file_size
    short = {"metadata": "META-INF/com/android/metadata",
             "metadata.pb": "META-INF/com/android/metadata.pb"}
    for k, v in short.items():
        off[k] = off[v]
        sz[k] = sz[v]
    off["payload_metadata.bin"] = off["payload.bin"]
    sz["payload_metadata.bin"] = META_SIZE + MPB_SIZE

    def line(keys):
        return ",".join("%s:%d:%d" % (k, off[k], sz[k]) for k in keys)
    pf = line(["payload_metadata.bin", "payload.bin", "payload_properties.txt",
               "apex_info.pb", "care_map.pb", "metadata", "metadata.pb"])
    sf = line(["payload.bin", "payload_properties.txt", "apex_info.pb",
               "care_map.pb", "metadata", "metadata.pb"])

    kv = {}
    src = ddir + "/META-INF/com/android/metadata"
    if os.path.exists(src):
        for l in open(src, encoding="utf-8", errors="ignore"):
            if "=" in l:
                k, v = l.rstrip("\n").split("=", 1)
                kv[k.strip()] = v.strip()
    txt = ("ota-property-files=%s\n" % pf
           + "ota-required-cache=0\n"
           + "ota-streaming-property-files=%s\n" % sf
           + "ota-type=AB\n"
           + "post-build=%s\n" % kv.get("post-build", "")
           + "post-build-incremental=%s\n" % kv.get("post-build-incremental", "")
           + "post-sdk-level=%s\n" % kv.get("post-sdk-level", "")
           + "post-security-patch-level=%s\n" % kv.get("post-security-patch-level", "")
           + "post-timestamp=%s\n" % kv.get("post-timestamp", "0")
           + "pre-device=%s\n" % kv.get("pre-device", ""))
    meta = txt.encode()
    meta += b" " * (META_SIZE - len(meta))

    m = om.OtaMetadata()
    m.ParseFromString(open(ddir + "/META-INF/com/android/metadata.pb", "rb").read())
    if m.HasField("precondition"):
        m.ClearField("precondition")
    m.ClearField("property_files")
    m.property_files["ota-property-files"] = pf
    m.property_files["ota-streaming-property-files"] = sf
    raw = m.SerializeToString()
    need = MPB_SIZE - len(raw)
    filler = b""
    for f in range(need, -1, -1):
        v, n = f, 1
        while v >= 0x80:
            v >>= 7
            n += 1
        if 2 + n == need - f:
            e = bytearray()
            v = f
            while True:
                b = v & 0x7f
                v >>= 7
                if v:
                    e.append(b | 0x80)
                else:
                    e.append(b)
                    break
            filler = b"\xc2\x3e" + bytes(e) + b"\0" * f
            break
    mpb = raw + filler
    with open(outzip, "r+b") as f:
        f.seek(off["metadata"])
        f.write(meta)
        f.seek(off["metadata.pb"])
        f.write(mpb)
    crc_patch(outzip, ["META-INF/com/android/metadata", "META-INF/com/android/metadata.pb"])


def sign(zp, sigfile):
    sig = open(sigfile, "rb").read()
    n = os.path.getsize(zp)
    c = len(sig) + 6
    with open(zp, "r+b") as f:
        f.seek(n - 2)
        f.write(struct.pack("<H", c) + sig + struct.pack("<H", c) + b"\xff\xff" + struct.pack("<H", c))


cmd = sys.argv[1]
if cmd == "dump":
    dump(sys.argv[2], sys.argv[3])
elif cmd == "build":
    build(sys.argv[2], sys.argv[3], sys.argv[4])
elif cmd == "sign":
    sign(sys.argv[2], sys.argv[3])
PY

export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
export PYLIB="$H/pylib"
export CERT="$H/keys/testkey.x509.pem"
python3 "$W/tool.py" dump "$D" "$W"

NAMES=$(sed -n 1p "$W/parts.txt")
PATHS=$(sed -n 2p "$W/parts.txt")
MT=$(cut -d" " -f1 "$W/params.txt")
SPL=$(cut -d" " -f2 "$W/params.txt")

# 4. generate the full payload
$DG --partition_names="$NAMES" --new_partitions="$PATHS" \
    --dynamic_partition_info_file="$W/dyninfo.txt" \
    --apex_info_file="$DD/apex_info.pb" \
    --out_file="$W/payload.bin" \
    --max_timestamp="$MT" --security_patch_level="$SPL" \
    --private_key="$W/key.pem" --max_threads="$(nproc)"
$DG --in_file="$W/payload.bin" --properties_file="$W/payload_properties.txt" \
    --properties_format=key-value

# 5. pack the payload into a standard A/B payload OTA zip and whole-file sign it
python3 "$W/tool.py" build "$W" "$Z" "$DD"
head -c $(( $(stat -c %s "$Z") - 2 )) "$Z" | openssl cms -sign -binary -noattr -md sha256 \
    -signer "$CERT" -inkey "$W/key.pem" -outform DER -out "$W/sig.der" -in /dev/stdin
python3 "$W/tool.py" sign "$Z" "$W/sig.der"
