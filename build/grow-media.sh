#!/bin/ksh
# build/grow-media.sh -- assemble a LARGER bootable velo install image so the
# offline package closure (the fat site79.tgz) fits beside the sets.
#
# ============================================================================
#  WHY THIS EXISTS (vs build/assemble-media.sh)
#  --------------------------------------------------------------------------
#  assemble-media.sh swaps the patched bsd.rd + a SMALL site79.tgz into a COPY
#  of install79.img IN PLACE.  That works only while site79.tgz fits the ~33 MB
#  of slack left on the stock 799.5 MiB OpenBSD partition.  Once site79.tgz
#  carries the L1/L2/L3 offline pkg closure (~131 MB) it no longer fits, and
#  OpenBSD base has NO growfs(8) -- an FFS cannot be grown in place.  So this
#  script REBUILDS the OpenBSD FFS at a larger size:
#    1. start a fresh sparse image of the target size;
#    2. inherit the stock MBR boot record + the (working) EFI system partition
#       BYTE-FOR-BYTE from install79.img (sectors 0..1023) -- never re-create
#       the ESP (fdisk -b leaves it UNFORMATTED; the stock one already boots);
#    3. grow the MBR OpenBSD partition (#3) to cover the new space;
#    4. lay a fresh, larger disklabel 'a' (4.2BSD) and newfs it;
#    5. copy the ENTIRE stock 7.9 set tree onto it (sets, /boot, /bsd, boot.conf,
#       7.9/amd64/*), then REPLACE 7.9/amd64/bsd.rd with the velo-patched ramdisk
#       and ADD the fat site79.tgz beside the sets;
#    6. installboot(8) to re-lay the legacy MBR/biosboot chain (newfs wiped the
#       partition's boot area); the UEFI path rides the preserved ESP.
#
#  WHERE THIS RUNS
#  --------------------------------------------------------------------------
#  RUNS INSIDE the OpenBSD 7.9 VM (needs vnconfig/disklabel/newfs/mount/
#  installboot/fdisk).  On the Void host it can only be PARSE-LINTED:
#      /usr/sbin/ksh -n build/grow-media.sh
#      bash          -n build/grow-media.sh
#
#  INPUTS / OUTPUT
#  --------------------------------------------------------------------------
#      IN:   install79.img    (stock USB image: MBR + 0xEF EFI + 0xA6 OpenBSD)
#            dist/bsd.rd.velo  (from build/build-velo.sh -- velo-patched ramdisk)
#            dist/site79.tgz   (from build/make-site-tgz.sh -- WITH the closure)
#      OUT:  dist/velo79.img   (~1.33 GiB: bigger FFS carrying sets + patched
#                               bsd.rd + the fat site79.tgz; boots like the stock
#                               medium on legacy BIOS and UEFI)
#
#  SAFETY POSTURE (identical doctrine to assemble-media.sh)
#  --------------------------------------------------------------------------
#   - FILE IMAGE ONLY.  vnconfig is pointed at $OUT / $IMG_IN (regular files),
#     never a /dev/* disk node.  There is NO `dd of=/dev/...` device write here;
#     the only dd targets are the image FILE ($OUT).  The dd-to-USB is the
#     SEPARATE, heavily-guarded M4 build/write-usb.sh, never this script.
#   - The download (install79.img) is never mutated -- we read its first 1024
#     sectors and (read-only) mount it to copy the set tree out.
#   - SHA256/.sig on the medium are invalidated by the bsd.rd swap + site add;
#     EXPECTED + harmless -- velo installs OFFLINE with verification off.
#
#  Target shell: the VM's /bin/ksh; parse-clean under host oksh/bash.
# ============================================================================

set -eu

PROG=grow-media

log() { echo "$PROG: $*"; }
die() { echo "$PROG: ERROR: $*" >&2; exit 1; }

# _le4 FILE OFFSET -- echo the 4-byte little-endian unsigned int stored at byte
# OFFSET in FILE (the MBR stores LBAs little-endian; amd64 od reads native = LE).
# Used to inspect/verify the MBR partition table directly from the image file,
# because fdisk(8) operates on a disk DEVICE, not a regular file.
# awk normalises od's zero-padded field (e.g. "0000001024") to a clean base-10
# decimal -- avoids both string-compare mismatches and the $((0NNN))=octal trap.
_le4() { dd if="$1" bs=1 skip="$2" count=4 2>/dev/null | od -An -tu4 | awk '{printf "%d", $1; exit}'; }
_u1()  { dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | awk '{printf "%d", $1; exit}'; }

usage() {
	echo "usage: $PROG <install79.img> <bsd.rd.velo> <site79.tgz> [out.img] [a-sectors]" >&2
	echo "  RUNS IN THE OpenBSD 7.9 VM (needs vnconfig/disklabel/newfs/installboot)." >&2
	echo "  File image only; the dd-to-USB is the SEPARATE M4 write-usb.sh." >&2
	exit 2
}

case "$0" in
*/*) _HERE=${0%/*} ;;
*)   _HERE=. ;;
esac
REPO=$(cd "$_HERE/.." && pwd)

# shellcheck source=build/lib-integrity.sh
. "$_HERE/lib-integrity.sh"

IMG_IN=${1:-}
RD=${2:-}
SITE=${3:-}
[ -n "$IMG_IN" ] && [ -n "$RD" ] && [ -n "$SITE" ] || usage
OUT=${4:-$REPO/dist/velo79.img}

# Size of the OpenBSD partition (disklabel 'a') in 512-byte sectors.  Default
# 2,800,000 sectors ~= 1.335 GiB: comfortably holds the stock sets (~766 MiB) +
# the fat site79.tgz (~131 MiB) + FFS overhead + slack.  Override as the 5th arg.
A_SECTORS=${5:-2800000}

# The OpenBSD MBR partition starts at sector 1024 on the stock image (0xEF EFI
# occupies sectors 64..1023).  These are fixed by the stock install79.img layout
# (verified: fdisk shows part3 start=1024; disklabel 'a' offset=1024, 'i' MSDOS
# offset=64 size=960).  We preserve sectors 0..1023 verbatim.
PART_START=1024
PRESERVE_SECTORS=1024           # MBR (sector 0) + EFI system partition (64..1023)
TOTAL_SECTORS=$((PART_START + A_SECTORS))

# Byte offset of MBR partition-entry #3's 4-byte little-endian size field:
#   table base 446 (0x1BE) + entry 3 * 16 + 12 (size field) = 506.
MBR_P3_SIZE_OFF=506

# --- preflight -------------------------------------------------------------
[ -f "$IMG_IN" ] || die "input image not found: $IMG_IN"
[ -f "$RD" ]     || die "patched bsd.rd not found: $RD (run build-velo.sh first)"
[ -f "$SITE" ]   || die "site tarball not found: $SITE (run make-site-tgz.sh first)"

case "$A_SECTORS" in
''|*[!0-9]*) die "a-sectors must be a positive integer (got [$A_SECTORS])" ;;
esac
[ "$A_SECTORS" -ge 1700000 ] || die "a-sectors $A_SECTORS too small (need >~1.7M to hold sets+closure)"

if [ "$IMG_IN" = "$OUT" ]; then
	die "refusing: output ($OUT) equals input -- choose a different out path so the download is never mutated"
fi

# Enforce the "file image only" posture: OUT must be a regular file, never a
# block/char device node (a mistyped 4th arg pointing at /dev/sdX would be dd'd).
if [ -e "$OUT" ] && [ ! -f "$OUT" ]; then
	die "refusing: output ($OUT) exists but is not a regular file (device node?) -- file images only"
fi

for _t in vnconfig disklabel newfs mount umount installboot dd od; do
	command -v "$_t" >/dev/null 2>&1 || \
		die "'$_t' not found -- this script must run on OpenBSD (the VM), not the Void host. Lint here with: ksh -n / bash -n"
done

# Refuse if the stock image's OpenBSD partition is not where we expect (so a
# future tooling change can't silently corrupt the boot layout).  Read the MBR
# partition-3 entry directly from the file: start LBA at byte 502, type at 498.
_p3start=$(_le4 "$IMG_IN" 502)
_p3type=$(_u1 "$IMG_IN" 498)
[ "$_p3type" = "166" ] || \
	die "stock image MBR part#3 type is [$_p3type], expected 166 (0xA6 OpenBSD) -- layout changed, refusing"
[ "$_p3start" = "$PART_START" ] || \
	die "stock image MBR part#3 starts at sector [$_p3start], expected $PART_START -- layout changed, refusing"

mkdir -p "$(dirname "$OUT")"

# --- 1. fresh sparse image of the target size ------------------------------
rm -f "$OUT"
# write a single zero sector at the last LBA -> a sparse file of TOTAL_SECTORS.
dd if=/dev/zero of="$OUT" bs=512 count=1 seek=$((TOTAL_SECTORS - 1)) 2>/dev/null \
	|| die "could not create $OUT"
log "created $OUT ($TOTAL_SECTORS sectors = $((TOTAL_SECTORS / 2048)) MiB, sparse)"

# --- 2. inherit MBR + EFI system partition byte-for-byte (sectors 0..1023) --
dd if="$IMG_IN" of="$OUT" bs=512 count="$PRESERVE_SECTORS" conv=notrunc 2>/dev/null \
	|| die "could not copy MBR+ESP from $IMG_IN"
log "inherited MBR + EFI system partition ($PRESERVE_SECTORS sectors) from $IMG_IN"

# --- 3. grow MBR partition #3 (OpenBSD) to A_SECTORS ------------------------
# Patch only the 4-byte LE size field; start LBA (1024) and the maxed-out ending
# CHS ("use LBA") are unchanged, so the boot MBR keeps using LBA addressing.
_s=$A_SECTORS
_o0=$(printf '%o' $((_s & 255)))
_o1=$(printf '%o' $(((_s >> 8) & 255)))
_o2=$(printf '%o' $(((_s >> 16) & 255)))
_o3=$(printf '%o' $(((_s >> 24) & 255)))
printf "\\$_o0\\$_o1\\$_o2\\$_o3" \
	| dd of="$OUT" bs=1 seek="$MBR_P3_SIZE_OFF" count=4 conv=notrunc 2>/dev/null \
	|| die "could not patch MBR partition-3 size"
log "grew MBR OpenBSD partition #3 to $A_SECTORS sectors"
log "MBR part#3 now: start=$(_le4 "$OUT" 502) size=$(_le4 "$OUT" 506) (type=$(_u1 "$OUT" 498))"

# --- attach the COPY; from here a trap detaches the vnd + unmounts ----------
VND=""; VND_OLD=""
MNT_NEW=$(mktemp -d "${TMPDIR:-/tmp}/velo-grow-new.XXXXXX") || die "mktemp failed"
MNT_OLD=$(mktemp -d "${TMPDIR:-/tmp}/velo-grow-old.XXXXXX") || die "mktemp failed"
cleanup() {
	umount "$MNT_NEW" 2>/dev/null || true
	umount "$MNT_OLD" 2>/dev/null || true
	[ -n "$VND" ]     && vnconfig -u "$VND"     2>/dev/null || true
	[ -n "$VND_OLD" ] && vnconfig -u "$VND_OLD" 2>/dev/null || true
	rmdir "$MNT_NEW" "$MNT_OLD" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

VND=$(vnconfig "$OUT") || die "vnconfig failed on $OUT"
case "$VND" in vnd[0-9]*) : ;; *) die "vnconfig returned an unexpected unit: [$VND]" ;; esac
log "attached $OUT as /dev/$VND (boundend should now reflect the grown partition)"

# --- 4. lay a fresh, larger disklabel 'a' and newfs it ---------------------
# disklabel derives boundstart/boundend from the (just-grown) MBR OpenBSD
# partition.  Delete any inherited 'a', then add 'a' = offset 1024, fill (*),
# 4.2BSD.  (Proven flow: d a / a a / 1024 / * / 4.2BSD / w / q.)
printf 'd a\na a\n%s\n*\n4.2BSD\nw\nq\n' "$PART_START" | disklabel -E "$VND" >/dev/null 2>&1 \
	|| die "disklabel -E failed to lay partition 'a'"

# Verify 'a' came out at the expected offset/size before we newfs it.
_aline=$(disklabel "$VND" 2>/dev/null | grep -E '^  a:' | head -1)
log "disklabel 'a': $_aline"
case "$_aline" in
*" $A_SECTORS "*" $PART_START "*4.2BSD*) : ;;
*) die "disklabel 'a' is not [$A_SECTORS @ $PART_START 4.2BSD] -- refusing to newfs. Saw: [$_aline]" ;;
esac

newfs "/dev/r${VND}a" >/dev/null 2>&1 || die "newfs /dev/r${VND}a failed"
log "newfs'd a fresh FFS on /dev/${VND}a"

# --- 5. populate: copy the whole stock set tree, then swap bsd.rd + add site -
VND_OLD=$(vnconfig "$IMG_IN") || die "vnconfig failed on $IMG_IN (source)"
case "$VND_OLD" in vnd[0-9]*) : ;; *) die "vnconfig(source) unexpected unit: [$VND_OLD]" ;; esac
mount -r "/dev/${VND_OLD}a" "$MNT_OLD" || die "read-only mount of stock set partition failed"
mount    "/dev/${VND}a"     "$MNT_NEW" || die "mount of new FFS failed"

log "copying the stock 7.9 set tree (sets, /boot, /bsd, boot.conf, 7.9/amd64) ..."
# -p preserve modes; pax/tar preserves owners (we run as root) and hardlinks.
( cd "$MNT_OLD" && tar cpf - . ) | ( cd "$MNT_NEW" && tar xpf - ) \
	|| die "set-tree copy failed"

_dest="$MNT_NEW/7.9/amd64"
[ -d "$_dest" ] || die "$_dest missing after copy -- set tree did not land"
[ -f "$_dest/bsd.rd" ] || die "$_dest/bsd.rd missing -- not a 7.9 set tree"

install -o root -g wheel -m 0644 "$RD"   "$_dest/bsd.rd"
install -o root -g wheel -m 0644 "$SITE" "$_dest/site79.tgz"
log "replaced $_dest/bsd.rd with the patched ramdisk; added $_dest/site79.tgz"

sync
umount "$MNT_OLD"; vnconfig -u "$VND_OLD"; VND_OLD=""

# --- 6. re-lay the legacy boot chain (newfs wiped the partition boot area) --
# installboot reinstalls /boot into the FS and writes biosboot to the partition;
# the UEFI path rides the EFI system partition we preserved in step 2.
# Stage paths are given EXPLICITLY (the build host's /usr/mdec) because an install
# medium has no /usr/mdec for `-r` to find -- only `-r $MNT_NEW` (where /boot is
# copied + the block list computed) plus the host's biosboot/boot stages.
installboot -v -r "$MNT_NEW" "$VND" /usr/mdec/biosboot /usr/mdec/boot \
	|| die "installboot failed"
log "installboot re-laid the MBR/biosboot legacy chain"

# --- report ----------------------------------------------------------------
log "final disklabel:"
disklabel "$VND" 2>/dev/null | sed -n '/^16 partitions/,$p'
log "final usage of the new FFS:"
df -h "$MNT_NEW" | sed -n '1,2p'
log "set directory:"
ls -la "$_dest" | sed -n '1,40p'

sync
umount "$MNT_NEW"; vnconfig -u "$VND"; VND=""
trap - EXIT INT TERM
rmdir "$MNT_NEW" "$MNT_OLD" 2>/dev/null || true

log "assembled $OUT (grown FFS: patched bsd.rd + fat site79.tgz)"

# Provenance sidecar: the writers (write-usb / flash-sda-guarded) verify the
# image against this BEFORE dd, so a corrupted/wrong image is caught pre-write.
_side=$(vi_sidecar_emit "$OUT") || die "could not emit sha256 sidecar for $OUT"
log "wrote integrity sidecar $_side -- $(cat "$_side")"

log "NOTE: the medium's SHA256/.sig are now invalid BY DESIGN -- velo installs"
log "      offline with verification off. Accept the verify-off prompt."
log "Next: test-boot $OUT against a BLANK virtual disk (legacy + UEFI) before any install."
