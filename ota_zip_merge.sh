#!/bin/sh
# ota_zip_merge.sh --base_zip BASE_OTA.zip --delta_zip DELTA_OTA.zip
#                  [--out_zip OUT.zip] [--dry_run]
#
# Wrapper around ota_delta_to_full.sh: inspect both OTA zips (reading
# ZIP_STORED payload.bin and delta metadata directly without writing residual
# files into base/ or delta/ when possible), then hand them to ota_delta_to_full.sh
# to build a full-payload OTA zip.
#
#   base  zip -> direct offset if ZIP_STORED, else temporary unpack dir
#   delta zip -> direct offset + metadata if ZIP_STORED, else temporary unpack dir
#   out zip   -> delta_out/<post-build-incremental>.zip   unless --out_zip
set -eu

H=$(cd "$(dirname "$0")" && pwd)
BASE_DIR=$H/base
DELTA_DIR=$H/delta
BASE_ZIP=
DELTA_ZIP=
OUT_ZIP=
DRY_RUN=0
prog=$(basename "$0")
UNPACK_TMP=

cleanup() {
	if [ -n "$UNPACK_TMP" ]; then
		rm -rf "$UNPACK_TMP"
	fi
}
trap cleanup EXIT INT TERM

die() {
	printf '%s: %s\n' "$prog" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: $prog --base_zip BASE_OTA.zip --delta_zip DELTA_OTA.zip [--out_zip OUT.zip] [--dry_run]

Validate both payload OTAs, then run ota_delta_to_full.sh to synthesize a
full-payload OTA zip. When payload.bin is ZIP_STORED (standard Android A/B OTA),
no files are unpacked into base/ or delta/.

  --base_zip PATH   full OTA zip of the base build
                    e.g. TB710FU_ZUXOS_2.5.02.089_xxxx.zip
  --delta_zip PATH  incremental OTA zip
                    e.g. ..._18.5.02.089_..._to_..._18.5.10.102_....zip
  --out_zip PATH    full OTA zip to write
                    default: $H/delta_out/<post-build-incremental of the delta>.zip
  --dry_run         check archives and print the merge command, but do not run it
  -h, --help        show this help

Windows paths (F:\\dir\\file.zip) are mapped to /mnt/f/dir/file.zip.
EOF
}

# Turn "F:\dir\file.zip" / "F:/dir/file.zip" into "/mnt/f/dir/file.zip".
wsl_path() {
	case $1 in
	[A-Za-z]:\\* | [A-Za-z]:/*)
		_d=$(printf '%s' "$1" | cut -c1 | tr 'A-Z' 'a-z')
		_r=$(printf '%s' "$1" | cut -c3- | tr '\\' '/')
		printf '/mnt/%s%s\n' "$_d" "$_r"
		;;
	*)
		printf '%s\n' "$1"
		;;
	esac
}

while [ $# -gt 0 ]; do
	case $1 in
	--base_zip | --base-zip)
		[ $# -ge 2 ] || die "$1 needs a value"
		BASE_ZIP=$2
		shift 2
		;;
	--base_zip=* | --base-zip=*)
		BASE_ZIP=${1#*=}
		shift
		;;
	--delta_zip | --delta-zip)
		[ $# -ge 2 ] || die "$1 needs a value"
		DELTA_ZIP=$2
		shift 2
		;;
	--delta_zip=* | --delta-zip=*)
		DELTA_ZIP=${1#*=}
		shift
		;;
	--out_zip | --out-zip)
		[ $# -ge 2 ] || die "$1 needs a value"
		OUT_ZIP=$2
		shift 2
		;;
	--out_zip=* | --out-zip=*)
		OUT_ZIP=${1#*=}
		shift
		;;
	--dry_run | --dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1 (see --help)"
		;;
	esac
done

[ -n "$BASE_ZIP" ] || die "missing --base_zip (see --help)"
[ -n "$DELTA_ZIP" ] || die "missing --delta_zip (see --help)"

BASE_ZIP=$(wsl_path "$BASE_ZIP")
DELTA_ZIP=$(wsl_path "$DELTA_ZIP")
if [ -n "$OUT_ZIP" ]; then
	OUT_ZIP=$(wsl_path "$OUT_ZIP")
fi

# Cheap sanity checks before copying gigabytes around.
require_zip() {
	[ -e "$1" ] || die "$2 zip not found: $1"
	[ -f "$1" ] || die "$2 zip is not a regular file: $1"
	[ -r "$1" ] || die "$2 zip not readable: $1"
	unzip -Z1 "$1" >/dev/null 2>&1 || die "$2 zip is not a valid zip archive: $1"
}
require_entry() {
	unzip -Z1 "$1" | grep -qxF -- "$2" || die "$(basename "$1"): missing $2"
}
zip_stored_offset() {
	python3 - "$1" <<'PY'
import struct, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "r") as zf:
    zi = zf.getinfo("payload.bin")
    if zi.compress_type != zipfile.ZIP_STORED:
        sys.exit(1)
    with open(sys.argv[1], "rb") as f:
        f.seek(zi.header_offset)
        hdr = f.read(30)
        if len(hdr) < 30 or hdr[:4] != b"PK\x03\x04":
            sys.exit(1)
        nlen, elen = struct.unpack("<HH", hdr[26:30])
        off = zi.header_offset + 30 + nlen + elen
        f.seek(off)
        if f.read(4) != b"CrAU":
            sys.exit(1)
        print(off)
PY
}

require_zip "$BASE_ZIP" base
require_zip "$DELTA_ZIP" delta
require_entry "$BASE_ZIP" payload.bin
require_entry "$DELTA_ZIP" payload.bin
require_entry "$DELTA_ZIP" META-INF/com/android/metadata
require_entry "$DELTA_ZIP" META-INF/com/android/metadata.pb
require_entry "$DELTA_ZIP" apex_info.pb
require_entry "$DELTA_ZIP" care_map.pb

# Default name: the delta's post-build-incremental (e.g. TB710FU_..._ST_261112),
# never its post-build, which is an Android build fingerprint full of / and :.
if [ -z "$OUT_ZIP" ]; then
	meta=$(unzip -p "$DELTA_ZIP" META-INF/com/android/metadata 2>/dev/null || true)
	meta=$(printf '%s\n' "$meta" | tr -d '\r')
	build=$(printf '%s\n' "$meta" | sed -n 's/^post-build-incremental=//p' | head -n 1)
	if [ -z "$build" ]; then
		build=$(printf '%s\n' "$meta" | sed -n 's/^post-build=//p' | head -n 1)
	fi
	[ -n "$build" ] || build=merged_ota
	build=$(printf '%s\n' "$build" | tr '/: ' '___')
	OUT_ZIP=$H/delta_out/$build.zip
fi
mkdir -p "$(dirname "$OUT_ZIP")" || die "cannot create $(dirname "$OUT_ZIP")"

unpack() { # zip dir label
	echo "==> unpacking $3"
	printf '    %s\n    -> %s\n' "$1" "$2"
	mkdir -p "$2" || die "cannot create $2"
	echo "    (multi-GB payloads take a few minutes; unzip stays quiet)"
	start=$(date +%s)
	unzip -q -o "$1" -d "$2" || die "failed to unpack $1"
	printf '    unpacked in %ss\n' "$(( $(date +%s) - start ))"
}

ensure_unpack_tmp() {
	if [ -z "$UNPACK_TMP" ]; then
		UNPACK_TMP=$(mktemp -d "$(dirname "$OUT_ZIP")/.ota_unpack.XXXXXX") || die "cannot create temp unpack dir"
	fi
}

if BASE_OFFSET=$(zip_stored_offset "$BASE_ZIP"); then
	echo "==> base payload is ZIP_STORED (offset=$BASE_OFFSET), skipping unzip"
	BASE_PAYLOAD=$BASE_ZIP
else
	if [ "$DRY_RUN" -eq 1 ]; then
		rm -f "$BASE_DIR/payload.bin"
		unpack "$BASE_ZIP" "$BASE_DIR" base
		BASE_PAYLOAD=$BASE_DIR/payload.bin
	else
		ensure_unpack_tmp
		unpack "$BASE_ZIP" "$UNPACK_TMP/base" base
		BASE_PAYLOAD=$UNPACK_TMP/base/payload.bin
	fi
	BASE_OFFSET=0
	[ -s "$BASE_PAYLOAD" ] || die "expected payload missing after unpack: $BASE_PAYLOAD"
fi

if DELTA_OFFSET=$(zip_stored_offset "$DELTA_ZIP"); then
	echo "==> delta payload is ZIP_STORED (offset=$DELTA_OFFSET), skipping unzip"
	DELTA_PAYLOAD=$DELTA_ZIP
	DELTA_META_ARG=$DELTA_ZIP
else
	if [ "$DRY_RUN" -eq 1 ]; then
		rm -f "$DELTA_DIR/payload.bin" \
			"$DELTA_DIR/META-INF/com/android/metadata" \
			"$DELTA_DIR/META-INF/com/android/metadata.pb" \
			"$DELTA_DIR/apex_info.pb" "$DELTA_DIR/care_map.pb"
		unpack "$DELTA_ZIP" "$DELTA_DIR" delta
		DELTA_PAYLOAD=$DELTA_DIR/payload.bin
		DELTA_META_ARG=$DELTA_DIR
	else
		ensure_unpack_tmp
		unpack "$DELTA_ZIP" "$UNPACK_TMP/delta" delta
		DELTA_PAYLOAD=$UNPACK_TMP/delta/payload.bin
		DELTA_META_ARG=$UNPACK_TMP/delta
	fi
	DELTA_OFFSET=0
	[ -s "$DELTA_PAYLOAD" ] || die "expected payload missing after unpack: $DELTA_PAYLOAD"
	for f in META-INF/com/android/metadata META-INF/com/android/metadata.pb apex_info.pb care_map.pb; do
		[ -f "$DELTA_META_ARG/$f" ] || die "expected delta metadata missing after unpack: $DELTA_META_ARG/$f"
	done
fi

echo "==> merging"
printf '    BASE_PAYLOAD_OFFSET="%s" DELTA_PAYLOAD_OFFSET="%s" "%s" "%s" "%s" "%s" "%s"\n' \
	"$BASE_OFFSET" "$DELTA_OFFSET" "$H/ota_delta_to_full.sh" "$BASE_PAYLOAD" "$DELTA_PAYLOAD" "$DELTA_META_ARG" "$OUT_ZIP"

if [ "$DRY_RUN" -eq 1 ]; then
	echo "==> dry run, not starting the merge"
	exit 0
fi

BASE_PAYLOAD_OFFSET="$BASE_OFFSET" DELTA_PAYLOAD_OFFSET="$DELTA_OFFSET" \
	"$H/ota_delta_to_full.sh" "$BASE_PAYLOAD" "$DELTA_PAYLOAD" "$DELTA_META_ARG" "$OUT_ZIP"
