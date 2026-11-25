#!/bin/sh
# ota_delta_to_full.sh BASE_PAYLOAD DELTA_PAYLOAD DELTA_DIR OUT_ZIP
#   BASE_PAYLOAD  full OTA payload (payload.bin or ZIP_STORED OTA zip)
#   DELTA_PAYLOAD incremental payload (payload.bin or ZIP_STORED OTA zip)
#   DELTA_DIR     dir holding delta metadata OR the delta OTA zip itself
#   OUT_ZIP       full payload OTA package to write        e.g. out/TB710FU_....zip
# No error handling, no progress reporting. Fails on the first bad command.
set -e

B=$1; D=$2; DD=$3; Z=$4
H=$(cd "$(dirname "$0")" && pwd)
W=$(dirname "$Z")/work
OTA=$H/bin/ota_extractor
DG=$H/bin/delta_generator
SEC=$H/keys/testkey

WATCH_PID=
stop_watch() {
	if [ -n "$WATCH_PID" ]; then
		kill "$WATCH_PID" 2>/dev/null || true
		wait "$WATCH_PID" 2>/dev/null || true
		WATCH_PID=
	fi
}
cleanup() {
	stop_watch
	if [ "${KEEP_WORK:-0}" != "1" ]; then
		rm -rf "$W"
	fi
}
trap cleanup EXIT INT TERM

rm -rf "$W"; mkdir -p "$W/base" "$W/new"
openssl pkcs8 -inform DER -in "$SEC.pk8" -out "$W/key.pem" -nocrypt

cat > "$W/tool.py" <<"PY"
import base64, hashlib, os, signal, struct, subprocess, sys, time, zipfile, zlib
sys.modules.pop("google", None)
sys.path.insert(0, os.environ["PYLIB"])
META_SIZE = 4096
MPB_SIZE = 4096
CHUNK_SIZE = 8 << 20
DELTA_META_FILES = (
    "META-INF/com/android/metadata",
    "META-INF/com/android/metadata.pb",
    "apex_info.pb",
    "care_map.pb",
)


def _fadvise_dontneed(fd, off=0, length=0):
    try:
        os.posix_fadvise(fd, off, length, os.POSIX_FADV_DONTNEED)
    except OSError:
        pass


def _drop_file_cache(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        _fadvise_dontneed(fd, 0, 0)
    finally:
        os.close(fd)


def drop_cache(paths):
    for p in paths:
        if not os.path.exists(p):
            continue
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for name in files:
                    _drop_file_cache(os.path.join(root, name))
        elif os.path.isfile(p):
            _drop_file_cache(p)


def watch_fadvise(interval_sec, paths):
    running = True

    def _stop(sig, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    while running:
        drop_cache(paths)
        steps = max(1, int(interval_sec * 5))
        for _ in range(steps):
            if not running:
                break
            time.sleep(0.2)


def extract_meta(zip_path, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(zip_path, "r") as zf:
        for entry in DELTA_META_FILES:
            zf.extract(entry, out_dir)


def stage_payload(src_path, src_offset, dst_path):
    with open(src_path, "rb") as f:
        magic = f.read(4)
    if magic == b"PK\x03\x04":
        with zipfile.ZipFile(src_path, "r") as zf:
            total = zf.getinfo("payload.bin").file_size
    else:
        total = os.path.getsize(src_path) - src_offset
    if total <= 0:
        raise ValueError("invalid staged payload size %d from %s" % (total, src_path))
    with open(src_path, "rb") as fin, open(dst_path, "wb") as fout:
        fin.seek(src_offset)
        pos = src_offset
        rem = total
        while rem > 0:
            b = fin.read(min(CHUNK_SIZE, rem))
            if not b:
                raise EOFError("unexpected EOF staging %s" % src_path)
            fout.write(b)
            _fadvise_dontneed(fin.fileno(), pos, len(b))
            pos += len(b)
            rem -= len(b)
        fout.flush()
        os.fsync(fout.fileno())


def offset(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic == b"CrAU":
            print(0)
            return
        if magic != b"PK\x03\x04":
            sys.stderr.write("error: %s is neither payload.bin nor a zip archive\n" % path)
            sys.exit(1)
    with zipfile.ZipFile(path, "r") as zf:
        zi = zf.getinfo("payload.bin")
        if zi.compress_type != zipfile.ZIP_STORED:
            sys.stderr.write("error: payload.bin in %s is compressed (must be ZIP_STORED)\n" % path)
            sys.exit(1)
        with open(path, "rb") as f:
            f.seek(zi.header_offset)
            hdr = f.read(30)
            if len(hdr) < 30 or hdr[:4] != b"PK\x03\x04":
                sys.stderr.write("error: invalid local header in %s\n" % path)
                sys.exit(1)
            nlen, elen = struct.unpack("<HH", hdr[26:30])
            data_off = zi.header_offset + 30 + nlen + elen
            f.seek(data_off)
            if f.read(4) != b"CrAU":
                sys.stderr.write("error: payload.bin at offset %d in %s does not start with CrAU\n" % (data_off, path))
                sys.exit(1)
            print(data_off)


def dump(delta, work, payload_offset=0):
    import update_metadata_pb2 as u
    with open(delta, "rb") as f:
        f.seek(payload_offset)
        h = f.read(24)
        if len(h) < 24 or h[:4] != b"CrAU":
            raise ValueError("invalid payload header at offset %d in %s" % (payload_offset, delta))
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


def sign_digest(digest_bytes, key_pem, max_sig_size):
    import update_metadata_pb2 as u
    res = subprocess.run(
        ["openssl", "pkeyutl", "-sign", "-inkey", key_pem, "-pkeyopt", "digest:sha256"],
        input=digest_bytes,
        check=True,
        stdout=subprocess.PIPE,
    )
    raw_sig = res.stdout
    if len(raw_sig) > max_sig_size:
        raise ValueError("signature length %d exceeds max_sig_size %d" % (len(raw_sig), max_sig_size))
    sigs = u.Signatures()
    s = sigs.signatures.add()
    s.unpadded_signature_size = len(raw_sig)
    s.data = raw_sig + b"\x00" * (max_sig_size - len(raw_sig))
    return sigs.SerializeToString()


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
    import update_metadata_pb2 as u
    import ota_metadata_pb2 as om

    unsigned_payload = work + "/payload_unsigned.bin"
    key_pem = work + "/key.pem"
    props = work + "/payload_properties.txt"
    max_sig_size = int(open(work + "/max_sig_size.txt", "r").read().strip())

    with open(unsigned_payload, "rb") as f:
        hdr = f.read(24)
        if len(hdr) < 24 or hdr[:4] != b"CrAU":
            raise ValueError("invalid unsigned payload header")
        major_version, old_manifest_size, old_meta_sig_size = struct.unpack(">QQI", hdr[4:24])
        if major_version != 2 or old_meta_sig_size != 0:
            raise ValueError("unexpected unsigned payload header: major=%d meta_sig=%d" % (major_version, old_meta_sig_size))
        m = u.DeltaArchiveManifest()
        m.ParseFromString(f.read(old_manifest_size))

    blobs_start = 24 + old_manifest_size
    blobs_size = os.path.getsize(unsigned_payload) - blobs_start
    sig_blob_len = len(sign_digest(b"\x00" * 32, key_pem, max_sig_size))

    m.signatures_offset = blobs_size
    m.signatures_size = sig_blob_len
    new_manifest = m.SerializeToString()
    new_header = b"CrAU" + struct.pack(">QQI", 2, len(new_manifest), sig_blob_len)
    metadata_size = 24 + len(new_manifest)
    metadata_hash = hashlib.sha256(new_header + new_manifest).digest()
    metadata_sig_blob = sign_digest(metadata_hash, key_pem, max_sig_size)
    if len(metadata_sig_blob) != sig_blob_len:
        raise ValueError("metadata signature size mismatch: %d != %d" % (len(metadata_sig_blob), sig_blob_len))
    total_signed_size = metadata_size + sig_blob_len + blobs_size + sig_blob_len

    entries = ["META-INF/com/android/metadata",
               "META-INF/com/android/metadata.pb",
               "apex_info.pb",
               "care_map.pb",
               "payload.bin",
               "payload_properties.txt",
               "META-INF/com/android/otacert"]
    with zipfile.ZipFile(outzip, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
        for name in entries:
            zi = zipfile.ZipInfo(name)
            zi.compress_type = zipfile.ZIP_STORED
            if name == "META-INF/com/android/metadata":
                zf.writestr(zi, b"\0" * META_SIZE)
            elif name == "META-INF/com/android/metadata.pb":
                zf.writestr(zi, b"\0" * MPB_SIZE)
            elif name in ("apex_info.pb", "care_map.pb"):
                src = ddir + "/" + name
                zi.file_size = os.path.getsize(src)
                with open(src, "rb") as fin, zf.open(zi, "w", force_zip64=True) as fout:
                    while True:
                        b = fin.read(CHUNK_SIZE)
                        if not b:
                            break
                        fout.write(b)
            elif name == "payload.bin":
                payload_sig_hasher = hashlib.sha256()
                file_hasher = hashlib.sha256()
                zi.file_size = total_signed_size
                with open(unsigned_payload, "rb") as fin, zf.open(zi, "w", force_zip64=True) as fout:
                    meta_bytes = new_header + new_manifest
                    fout.write(meta_bytes)
                    payload_sig_hasher.update(meta_bytes)
                    file_hasher.update(meta_bytes)

                    fout.write(metadata_sig_blob)
                    file_hasher.update(metadata_sig_blob)

                    fin.seek(blobs_start)
                    remaining = blobs_size
                    last_in = blobs_start
                    last_out = zf.fp.tell()
                    IN_EVICT = 64 << 20
                    OUT_EVICT = 256 << 20
                    while remaining > 0:
                        b = fin.read(min(CHUNK_SIZE, remaining))
                        if not b:
                            raise EOFError("unexpected EOF reading blobs from %s" % unsigned_payload)
                        fout.write(b)
                        payload_sig_hasher.update(b)
                        file_hasher.update(b)
                        remaining -= len(b)

                        cur_in = fin.tell()
                        if cur_in - last_in >= IN_EVICT:
                            _fadvise_dontneed(fin.fileno(), last_in, cur_in - last_in)
                            last_in = cur_in
                        cur_out = zf.fp.tell()
                        if cur_out - last_out >= OUT_EVICT:
                            zf.fp.flush()
                            try:
                                os.fdatasync(zf.fp.fileno())
                            except OSError:
                                pass
                            _fadvise_dontneed(zf.fp.fileno(), last_out, cur_out - last_out)
                            last_out = cur_out

                    _fadvise_dontneed(fin.fileno(), 0, 0)
                    payload_sig_blob = sign_digest(payload_sig_hasher.digest(), key_pem, max_sig_size)
                    if len(payload_sig_blob) != sig_blob_len:
                        raise ValueError("payload signature size mismatch: %d != %d" % (len(payload_sig_blob), sig_blob_len))
                    fout.write(payload_sig_blob)
                    file_hasher.update(payload_sig_blob)
                    zf.fp.flush()
                    try:
                        os.fdatasync(zf.fp.fileno())
                    except OSError:
                        pass
                    _fadvise_dontneed(zf.fp.fileno(), last_out, zf.fp.tell() - last_out)

                props_txt = (
                    "FILE_HASH=%s\n" % base64.b64encode(file_hasher.digest()).decode("ascii")
                    + "FILE_SIZE=%d\n" % total_signed_size
                    + "METADATA_HASH=%s\n" % base64.b64encode(metadata_hash).decode("ascii")
                    + "METADATA_SIZE=%d\n" % metadata_size
                )
                open(props, "w").write(props_txt)
            elif name == "payload_properties.txt":
                props_bytes = open(props, "rb").read()
                zf.writestr(zi, props_bytes)
            elif name == "META-INF/com/android/otacert":
                src = os.environ["CERT"]
                zi.file_size = os.path.getsize(src)
                with open(src, "rb") as fin, zf.open(zi, "w", force_zip64=True) as fout:
                    while True:
                        b = fin.read(CHUNK_SIZE)
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
    sz["payload_metadata.bin"] = metadata_size + sig_blob_len

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


def cms_sign(zip_path, key_pem, out_der):
    total = os.path.getsize(zip_path) - 2
    if total <= 0:
        raise ValueError("invalid zip size for cms_sign: %s" % zip_path)
    proc = subprocess.Popen(
        [
            "openssl", "cms", "-sign", "-binary", "-noattr", "-md", "sha256",
            "-signer", os.environ["CERT"], "-inkey", key_pem,
            "-outform", "DER", "-out", out_der, "-in", "/dev/stdin",
        ],
        stdin=subprocess.PIPE,
    )
    EVICT_STEP = 64 << 20
    last_evict = 0
    pos = 0
    try:
        with open(zip_path, "rb") as f:
            rem = total
            while rem > 0:
                b = f.read(min(CHUNK_SIZE, rem))
                if not b:
                    raise EOFError("unexpected EOF reading %s for cms_sign" % zip_path)
                proc.stdin.write(b)
                pos += len(b)
                rem -= len(b)
                if pos - last_evict >= EVICT_STEP:
                    _fadvise_dontneed(f.fileno(), last_evict, pos - last_evict)
                    last_evict = pos
            _fadvise_dontneed(f.fileno(), 0, 0)
    finally:
        if proc.stdin:
            proc.stdin.close()
    rc = proc.wait()
    if rc != 0:
        raise subprocess.CalledProcessError(rc, proc.args)


def sign(zp, sigfile):
    sig = open(sigfile, "rb").read()
    n = os.path.getsize(zp)
    c = len(sig) + 6
    with open(zp, "r+b") as f:
        f.seek(n - 2)
        f.write(struct.pack("<H", c) + sig + struct.pack("<H", c) + b"\xff\xff" + struct.pack("<H", c))
        f.flush()
        os.fsync(f.fileno())
        _fadvise_dontneed(f.fileno(), 0, 0)


cmd = sys.argv[1]
if cmd == "offset":
    offset(sys.argv[2])
elif cmd == "extract_meta":
    extract_meta(sys.argv[2], sys.argv[3])
elif cmd == "stage_payload":
    stage_payload(sys.argv[2], int(sys.argv[3]), sys.argv[4])
elif cmd == "drop_cache":
    drop_cache(sys.argv[2:])
elif cmd == "watch_fadvise":
    watch_fadvise(float(sys.argv[2]), sys.argv[3:])
elif cmd == "dump":
    dump(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 0)
elif cmd == "build":
    build(sys.argv[2], sys.argv[3], sys.argv[4])
elif cmd == "cms_sign":
    cms_sign(sys.argv[2], sys.argv[3], sys.argv[4])
elif cmd == "sign":
    sign(sys.argv[2], sys.argv[3])
PY

export PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
export PYLIB="$H/pylib"
export CERT="$H/keys/testkey.x509.pem"

if [ -f "$DD" ]; then
	python3 "$W/tool.py" extract_meta "$DD" "$W/delta_meta"
	DD="$W/delta_meta"
fi

BASE_OFF=${BASE_PAYLOAD_OFFSET:-$(python3 "$W/tool.py" offset "$B")}
DELTA_OFF=${DELTA_PAYLOAD_OFFSET:-$(python3 "$W/tool.py" offset "$D")}

case "$D" in
/mnt/[a-z]/*)
	python3 "$W/tool.py" stage_payload "$D" "$DELTA_OFF" "$W/delta_payload.bin"
	D="$W/delta_payload.bin"
	DELTA_OFF=0
	;;
esac

# 1. unpack base payload (actively evict clean page cache)
python3 "$W/tool.py" watch_fadvise 8 "$B" "$W/base" &
WATCH_PID=$!
$OTA --payload="$B" --payload_offset="$BASE_OFF" --output_dir="$W/base"
stop_watch
python3 "$W/tool.py" drop_cache "$B"

# 2. apply delta on top of the base images (single-threaded by default to cap delta RSS)
# shellcheck disable=SC2086
$OTA ${DELTA_EXTRACT_FLAGS:---single_thread} --payload="$D" --payload_offset="$DELTA_OFF" --input_dir="$W/base" --output_dir="$W/new"
rm -rf "$W/base"

# 3. dump partition list / dynamic partition metadata / timestamps from the delta manifest
python3 "$W/tool.py" dump "$D" "$W" "$DELTA_OFF"
rm -f "$W/delta_payload.bin"

NAMES=$(sed -n 1p "$W/parts.txt")
PATHS=$(sed -n 2p "$W/parts.txt")
MT=$(cut -d" " -f1 "$W/params.txt")
SPL=$(cut -d" " -f2 "$W/params.txt")

# 4. generate the unsigned full payload (keep VABC enabled, avoid nested N*N pools and full-file ReadFile signing)
$DG --private_key="$W/key.pem" --out_maximum_signature_size_file="$W/max_sig_size.txt"
python3 "$W/tool.py" watch_fadvise 8 "$W/new" "$W/payload_unsigned.bin" &
WATCH_PID=$!
$DG --partition_names="$NAMES" --new_partitions="$PATHS" \
    --dynamic_partition_info_file="$W/dyninfo.txt" \
    --apex_info_file="$DD/apex_info.pb" \
    --out_file="$W/payload_unsigned.bin" \
    --max_timestamp="$MT" --security_patch_level="$SPL" \
    --max_threads="${DELTA_MAX_THREADS:-1}"
stop_watch
rm -rf "$W/new"

# 5. stream-sign and pack the payload into a standard A/B payload OTA zip and whole-file sign it
python3 "$W/tool.py" build "$W" "$Z" "$DD"
rm -f "$W/payload_unsigned.bin"
python3 "$W/tool.py" cms_sign "$Z" "$W/key.pem" "$W/sig.der"
python3 "$W/tool.py" sign "$Z" "$W/sig.der"
