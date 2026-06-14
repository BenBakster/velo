#!/bin/ksh
# build/assemble-media.sh -- assemble the bootable velo install image.
#
# ============================================================================
#  WHERE THIS RUNS
#  --------------------------------------------------------------------------
#  RUNS INSIDE the OpenBSD 7.9 VM (needs vnconfig/mount/disklabel/install).
#  On the Void host it can only be PARSE-LINTED:
#      /usr/sbin/ksh -n build/assemble-media.sh
#      bash          -n build/assemble-media.sh
#
#  WHAT IT PRODUCES
#  --------------------------------------------------------------------------
#  Swaps the patched bsd.rd into a COPY of install79.img and drops site79.tgz
#  beside the sets, producing dist/velo79.img:
#      IN:   install79.img   (the stock USB image; MBR + EFI + 0xA6 OpenBSD
#                             partition carrying 7.9/amd64/ with the sets)
#            dist/bsd.rd.velo (from build/build-velo.sh)
#            dist/site79.tgz  (from build/make-site-tgz.sh, the M2 packer)
#      OUT:  dist/velo79.img  = a copy of install79.img with
#                - 7.9/amd64/bsd.rd  REPLACED by the patched bsd.rd.velo, and
#                - 7.9/amd64/site79.tgz ADDED beside base79.tgz etc.
#  The booted installer IS the velo-patched ramdisk; the same medium hosts the
#  sets + site79.tgz.  One self-contained stick.  (docs/m3-design.md s3.)
#
#  SAFETY POSTURE
#  --------------------------------------------------------------------------
#   - FILE IMAGE ONLY.  It works on a COPY ($OUT); vnconfig is pointed at that
#     file, never a /dev/* device.  There is NO `dd of=/dev/...` here.  The dd
#     to a real USB is the SEPARATE, heavily-guarded M4 script
#     (build/write-usb.sh), never this one.
#   - The download (install79.img) is never mutated.
#   - SHA256/.sig on the medium are invalidated by the bsd.rd swap + site add;
#     that is EXPECTED and harmless -- velo installs OFFLINE with verification
#     off (the operator accepts the verify-off prompt).  We do NOT re-sign.
#
#  FLAGGED for the VM (docs/m3-design.md s3.2): the exact disklabel partition
#  letter that carries 7.9/amd64/ on the .img.  Default 'a'; override via
#  SETS_PART=<letter> or the 4th positional arg after inspecting `disklabel`.
#
#  Target shell: the VM's /bin/ksh; parse-clean under host oksh/bash.
# ============================================================================

set -eu

PROG=assemble-media

log() { echo "$PROG: $*"; }
die() { echo "$PROG: ERROR: $*" >&2; exit 1; }

usage() {
	echo "usage: $PROG <install79.img> <bsd.rd.velo> <site79.tgz> [out.img] [sets-part-letter]" >&2
	echo "  RUNS IN THE OpenBSD 7.9 VM (needs vnconfig/mount/disklabel)." >&2
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
# The set directory lives on the disklabel partition reported as 4.2BSD.  On
# the stock install79.img this is 'a'; confirm in the VM with `disklabel $VND`.
SETS_PART=${5:-${SETS_PART:-a}}

# --- preflight -------------------------------------------------------------
[ -f "$IMG_IN" ] || die "input image not found: $IMG_IN"
[ -f "$RD" ]     || die "patched bsd.rd not found: $RD (run build-velo.sh first)"
[ -f "$SITE" ]   || die "site tarball not found: $SITE (run make-site-tgz.sh first)"

case "$SETS_PART" in
[a-p]) : ;;
*) die "sets-part-letter must be a single disklabel partition letter a-p (got [$SETS_PART])" ;;
esac

if [ "$IMG_IN" = "$OUT" ]; then
	die "refusing: output ($OUT) equals input -- choose a different out path so the download is never mutated"
fi

for _t in vnconfig mount umount disklabel install; do
	command -v "$_t" >/dev/null 2>&1 || \
		die "'$_t' not found -- this script must run on OpenBSD (the VM), not the Void host. Lint here with: ksh -n / bash -n"
done

# --- work on a COPY; never mutate the download -----------------------------
mkdir -p "$(dirname "$OUT")"
log "copying $IMG_IN -> $OUT (working on a copy)"
cp "$IMG_IN" "$OUT"

# vnconfig the COPY (a FILE), then mount the set partition.  Capture the unit;
# never hardcode vnd0.  (vnconfig(8), disklabel(8), mount(8).)
VND=""
MNT=$(mktemp -d "${TMPDIR:-/tmp}/velo-media.XXXXXX") || die "mktemp failed"
cleanup() {
	if [ -n "$VND" ]; then
		umount "$MNT" 2>/dev/null || true
		vnconfig -u "$VND" 2>/dev/null || true
	fi
	rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

VND=$(vnconfig "$OUT") || die "vnconfig failed on $OUT"
case "$VND" in
vnd[0-9]*) : ;;
*) die "vnconfig returned an unexpected unit: [$VND]" ;;
esac
log "attached $OUT as /dev/$VND"

# Surface the live label so the operator can confirm SETS_PART in the VM.
log "disklabel $VND (confirm the 4.2BSD set partition letter; using '$SETS_PART'):"
disklabel "$VND" 2>/dev/null | sed -n '/partitions/,$p' || true

mount /dev/"${VND}${SETS_PART}" "$MNT" || \
	die "mount of /dev/${VND}${SETS_PART} failed -- wrong partition letter? Re-run with the correct trailing letter after inspecting the label above."

DEST="$MNT/7.9/amd64"
[ -d "$DEST" ] || die "$DEST not found on the image (is '$SETS_PART' the set partition? check the disklabel above)"
[ -f "$DEST/bsd.rd" ] || die "$DEST/bsd.rd missing -- this does not look like a 7.9 install medium"

# --- replace bsd.rd; add site79.tgz beside the sets ------------------------
install -o root -g wheel -m 0644 "$RD"   "$DEST/bsd.rd"
install -o root -g wheel -m 0644 "$SITE" "$DEST/site79.tgz"
log "replaced $DEST/bsd.rd with the patched ramdisk"
log "added    $DEST/site79.tgz beside the sets"

sync
umount "$MNT"
vnconfig -u "$VND"
VND=""

log "assembled $OUT (patched bsd.rd + site79.tgz in 7.9/amd64/)"

# Provenance sidecar: the writers (write-usb / flash-sda-guarded) verify the
# image against this BEFORE dd, so a corrupted/wrong image is caught pre-write.
_side=$(vi_sidecar_emit "$OUT") || die "could not emit sha256 sidecar for $OUT"
log "wrote integrity sidecar $_side -- $(cat "$_side")"

log "NOTE: the medium's SHA256/.sig are now invalid BY DESIGN -- velo installs"
log "      offline with verification off. Accept the verify-off prompt."
log "Next (M4 HARD STOP -- Anton present, stick in hand): build/write-usb.sh $OUT <device>"
