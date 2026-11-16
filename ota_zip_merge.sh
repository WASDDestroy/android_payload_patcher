#!/bin/sh
# ota_zip_merge.sh --base_zip BASE_OTA.zip --delta_zip DELTA_OTA.zip
#                  [--out_zip OUT.zip] [--dry_run]
#
# Wrapper around ota_delta_to_full.sh: unpack the base OTA zip and the
# incremental (delta) OTA zip, then hand their payloads to the merge script to
# build a full-payload OTA zip.
#
#   base  zip -> $H/base    (payload.bin + OTA metadata)
#   delta zip -> $H/delta   (payload.bin + OTA metadata)
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

die() {
	printf '%s: %s\n' "$prog" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: $prog --base_zip BASE_OTA.zip --delta_zip DELTA_OTA.zip [--out_zip OUT.zip] [--dry_run]

Unpack both payload OTAs, then run ota_delta_to_full.sh on their payloads.

  --base_zip PATH   full OTA zip of the base build
                    e.g. TB710FU_ZUXOS_2.5.02.089_xxxx.zip
  --delta_zip PATH  incremental OTA zip
                    e.g. ..._18.5.02.089_..._to_..._18.5.10.102_....zip
  --out_zip PATH    full OTA zip to write
                    default: $H/delta_out/<post-build-incremental of the delta>.zip
  --dry_run         unpack and print the merge command, but do not run it
  -h, --help        show this help

Windows paths (F:\\dir\\file.zip) are mapped to /mnt/f/dir/file.zip.
Unpack destinations (reused, files are overwritten):
  $BASE_DIR/
  $DELTA_DIR/
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

# Drop what the previous run left behind: if unpacking dies halfway, the checks
# below must fail instead of silently merging a stale payload.
rm -f "$BASE_DIR/payload.bin" "$DELTA_DIR/payload.bin" \
	"$DELTA_DIR/META-INF/com/android/metadata" \
	"$DELTA_DIR/META-INF/com/android/metadata.pb" \
	"$DELTA_DIR/apex_info.pb" "$DELTA_DIR/care_map.pb"

unpack() { # zip dir label
	echo "==> unpacking $3"
	printf '    %s\n    -> %s\n' "$1" "$2"
	mkdir -p "$2" || die "cannot create $2"
	echo "    (multi-GB payloads take a few minutes; unzip stays quiet)"
	start=$(date +%s)
	unzip -q -o "$1" -d "$2" || die "failed to unpack $1"
	printf '    unpacked in %ss\n' "$(( $(date +%s) - start ))"
}

unpack "$BASE_ZIP" "$BASE_DIR" base
unpack "$DELTA_ZIP" "$DELTA_DIR" delta

BASE_PAYLOAD=$BASE_DIR/payload.bin
DELTA_PAYLOAD=$DELTA_DIR/payload.bin

for f in "$BASE_PAYLOAD" "$DELTA_PAYLOAD"; do
	[ -s "$f" ] || die "expected payload missing after unpack: $f"
done
for f in META-INF/com/android/metadata META-INF/com/android/metadata.pb apex_info.pb care_map.pb; do
	[ -f "$DELTA_DIR/$f" ] || die "expected delta metadata missing after unpack: $DELTA_DIR/$f"
done

echo "==> merging"
printf '    "%s" "%s" "%s" "%s" "%s"\n' \
	"$H/ota_delta_to_full.sh" "$BASE_PAYLOAD" "$DELTA_PAYLOAD" "$DELTA_DIR" "$OUT_ZIP"

if [ "$DRY_RUN" -eq 1 ]; then
	echo "==> dry run, not starting the merge"
	exit 0
fi

exec "$H/ota_delta_to_full.sh" "$BASE_PAYLOAD" "$DELTA_PAYLOAD" "$DELTA_DIR" "$OUT_ZIP"
