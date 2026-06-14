#!/bin/bash
# build/flash-sda-guarded.sh -- Linux-host guarded writer for dist/velo79.img.
#
# ############################################################################
# ##   M4 HARD STOP.  THIS WRITES dist/velo79.img TO A RAW BLOCK DEVICE AND  ##
# ##   DESTROYS EVERYTHING ON IT.  IT IS *NEVER* RUN AUTONOMOUSLY.           ##
# ##                                                                        ##
# ##   This is the LINUX-HOST analogue of build/write-usb.sh (the OpenBSD    ##
# ##   canonical path).  It identifies the target BY CONTENT (RM/TRAN/size/  ##
# ##   not-root/not-nvme/unmounted), NEVER by a hardcoded letter, and aborts ##
# ##   BEFORE a single byte if ANY guard fails.  On the Void host the        ##
# ##   external TOSHIBA-bridged SSD has historically been /dev/sda = the     ##
# ##   Void-portable ROOT; a wrong target node bricks the daily-driver OS.   ##
# ##   Hence: there is NO default device, ever -- the operator MUST name it. ##
# ############################################################################
#
# USAGE
# ---------------------------------------------------------------------------
#   VELO_I_AM_SURE=yes build/flash-sda-guarded.sh dist/velo79.img /dev/sdX
#
#   - Requires BOTH an image path AND an explicit target device.  There is NO
#     default device, ever -- the script will not guess (no more /dev/sda).
#   - DEFAULTS TO DRY-RUN: with VELO_I_AM_SURE unset it runs every guard and
#     prints the exact dd it WOULD run, then exits 0 WITHOUT writing.
#   - A real write requires VELO_I_AM_SURE=yes set by a human this session AND
#     a typed confirmation of the target's basename at the prompt.
set -u
PROG=flash-sda-guarded
say(){ echo "=== [$(date +%H:%M:%S)] $* ==="; }
die(){ echo "$PROG: ABORT: $*" >&2; exit 1; }

cd "$(dirname "$0")/.." || die "cannot cd to repo root"

# shellcheck source=build/lib-integrity.sh
. ./build/lib-integrity.sh

usage(){
	cat >&2 <<USAGE
usage: VELO_I_AM_SURE=yes $PROG <velo79.img> <target-device>

  M4 HARD STOP -- writes <velo79.img> to <target-device>, DESTROYING it.
  <target-device> is a block device path, e.g. /dev/sdc (NOT a partition like
  /dev/sdc1).  There is NO default device.
  Without VELO_I_AM_SURE=yes this is a DRY-RUN: runs all guards, prints the dd
  it WOULD run, writes nothing.
USAGE
	exit 2
}

IMG=${1:-}
DEV=${2:-}
[ -n "$IMG" ] || usage
[ -n "$DEV" ] || die "no explicit target device given -- refusing to guess. Pass the device (e.g. /dev/sdc)."

# Normalize: accept either 'sdc' or '/dev/sdc'; reject partitions and metachars.
case "$DEV" in
/dev/*) : ;;
*)      DEV=/dev/$DEV ;;
esac
BASE=${DEV#/dev/}
case "$BASE" in
sd[a-z]|sd[a-z][a-z]) : ;;
*) die "target [$DEV] is not a bare whole-disk name (/dev/sdX). Refusing. Do NOT pass a partition (sdc1) or anything else." ;;
esac

ARMED=no
[ "${VELO_I_AM_SURE:-no}" = yes ] && ARMED=yes
if [ "$ARMED" = yes ]; then
	say "ARMED (VELO_I_AM_SURE=yes) -- this run will WRITE after confirmation"
else
	say "DRY-RUN (VELO_I_AM_SURE unset) -- guards only, no write"
fi

# ---- GUARD 0: image present, non-empty, plausibly large ----
[ -f "$IMG" ] || die "image not found: $IMG"
IMG_SZ=$(stat -c %s "$IMG") || die "cannot stat $IMG"
[ "$IMG_SZ" -gt 100000000 ] || die "image suspiciously small ($IMG_SZ B)"
say "image $IMG = $IMG_SZ bytes, cksum $(cksum "$IMG" | awk '{print $1}')"

# ---- GUARD 0b: INTEGRITY -- if the producer dropped a .sha256 sidecar, the
#      image MUST match it (a corrupted/wrong image aborts BEFORE any dd).  A
#      missing sidecar is a LOUD WARN, not a hard stop: older images predate the
#      sidecar, and this whole path is supervised (M4 HARD STOP) anyway.
if [ -f "$IMG.sha256" ]; then
	if vi_sidecar_verify "$IMG"; then
		say "INTEGRITY OK: $IMG matches $IMG.sha256"
	else
		die "INTEGRITY FAIL: $IMG does not match $IMG.sha256 -- refusing to flash a tampered/corrupted image"
	fi
else
	say "WARNING: no integrity sidecar $IMG.sha256 -- cannot verify provenance (older image?). Proceeding under supervision."
fi

# ---- GUARD 1: target is a block device ----
[ -b "$DEV" ] || die "$DEV is not a block device"

# ---- GUARD 2: REMOVABLE (RM=1) ----
RM=$(lsblk -dno RM "$DEV" 2>/dev/null | tr -d ' ')
[ "$RM" = 1 ] || die "$DEV RM=$RM (not removable) -- refusing"

# ---- GUARD 3: transport == usb ----
TRAN=$(lsblk -dno TRAN "$DEV" 2>/dev/null | tr -d ' ')
[ "$TRAN" = usb ] || die "$DEV TRAN=$TRAN (not usb) -- refusing"

# ---- GUARD 4: size sane (20G..64G), and image fits ----
DEV_SZ=$(blockdev --getsize64 "$DEV") || die "cannot read size of $DEV"
[ "$DEV_SZ" -ge 21000000000 ] || die "$DEV size $DEV_SZ < 20G -- refusing"
[ "$DEV_SZ" -le 68719476736 ] || die "$DEV size $DEV_SZ > 64G -- too big for a velo stick, refusing"
[ "$IMG_SZ" -lt "$DEV_SZ" ] || die "image larger than device -- refusing"

# ---- GUARD 5: NOT the root/system device, NOT nvme ----
case "$DEV" in *nvme*) die "$DEV looks like nvme -- the SYSTEM disk, refusing" ;; esac
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null)
case "$ROOTSRC" in
*"$BASE"*) die "root is on $ROOTSRC which involves $BASE -- refusing" ;;
esac

# ---- GUARD 6: no partition of the target is mounted ----
if lsblk -lno NAME,MOUNTPOINTS "$DEV" | awk 'NF>1{print; found=1} END{exit !found}'; then
	die "a partition of $DEV is mounted (see above) -- refusing"
fi

MODEL=$(lsblk -dno MODEL "$DEV" 2>/dev/null)
say "TARGET CONFIRMED: $DEV  RM=$RM TRAN=$TRAN size=$DEV_SZ model='$MODEL' root=$ROOTSRC"
say "all 6 guards passed"

# ---- DRY-RUN stops here ----
if [ "$ARMED" != yes ]; then
	say "DRY-RUN: would run -- dd if=$IMG of=$DEV bs=4M conv=fsync"
	say "Re-run with VELO_I_AM_SURE=yes to write for real."
	exit 0
fi

# ---- TYPED CONFIRMATION (armed only) ----
echo "" >&2
echo "$PROG: ABOUT TO DESTROY $DEV (model '$MODEL', $DEV_SZ bytes)." >&2
printf "%s: type the device basename '%s' to proceed: " "$PROG" "$BASE" >&2
read -r _ans
[ "$_ans" = "$BASE" ] || die "confirmation mismatch (got '$_ans', expected '$BASE') -- not writing"

# ---- WRITE ----
say "writing $IMG -> $DEV"
dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress || die "dd failed"
sync
blockdev --flushbufs "$DEV" 2>/dev/null || true
say "write complete; re-reading device for byte verification"

# drop caches so cmp reads the DEVICE, not the page cache
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

# ---- VERIFY: image bytes must equal the first IMG_SZ bytes of the device ----
if cmp -n "$IMG_SZ" "$IMG" "$DEV"; then
	say "VERIFY OK: first $IMG_SZ bytes of $DEV are byte-identical to $IMG"
	say "FLASH-DONE-OK"
	exit 0
else
	die "VERIFY FAILED: device does not match image"
fi
