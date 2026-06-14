#!/bin/sh
# build/write-usb.sh -- THE ONLY velo script that writes to a real device.
#
# ############################################################################
# ##                                                                        ##
# ##   M4 HARD STOP.  THIS WRITES dist/velo79.img TO A RAW DISK DEVICE AND   ##
# ##   DESTROYS EVERYTHING ON IT.  IT IS *NEVER* RUN AUTONOMOUSLY.           ##
# ##                                                                        ##
# ##   No build step, no test, and no CI path invokes this file.  It is the  ##
# ##   final MANUAL step Anton performs with the USB stick physically in    ##
# ##   hand, after reading the new device node from `sysctl hw.disknames`.  ##
# ##                                                                        ##
# ##   On this project the external TOSHIBA-bridged SSD is `sda` = the      ##
# ##   Void-portable ROOT (project memory). A wrong target node bricks the  ##
# ##   daily-driver OS. Hence the guard stack below: ANY failing guard      ##
# ##   aborts BEFORE a single byte is written.                              ##
# ##                                                                        ##
# ############################################################################
#
# WHERE THIS RUNS
# ---------------------------------------------------------------------------
#   OpenBSD (the VM, or a real OpenBSD box) -- it speaks `disklabel`, `mount`,
#   `df`, `sysctl hw.disknames`, and writes the raw char device /dev/r<dev>c.
#   On the Void/Linux host the analogous manual command is documented in the
#   runbook (`dd ... of=/dev/sdX oflag=sync`); the CANONICAL velo write path is
#   this guarded script on OpenBSD.  Lint here with:
#       /usr/sbin/ksh -n build/write-usb.sh
#       bash          -n build/write-usb.sh
#       sh            -n build/write-usb.sh
#
# USAGE
# ---------------------------------------------------------------------------
#   VELO_I_AM_SURE=yes build/write-usb.sh dist/velo79.img sd2
#
#   - Requires BOTH an image path AND an explicit target device name.  There is
#     NO default device, ever -- the script will not guess.
#   - DEFAULTS TO DRY-RUN: with the env-arm unset it prints the exact dd it
#     WOULD run and exits 0 without writing.  Real writes require
#     VELO_I_AM_SURE=yes set by a human this session AND a typed confirmation.
#
# Target shell: POSIX /bin/sh (OpenBSD ksh).  No bashisms.  Parse-clean under
# sh -n, bash -n, and oksh -n.
# ============================================================================

set -eu

PROG=write-usb

say()  { echo "$PROG: $*"; }
die()  { echo "$PROG: ABORT: $*" >&2; exit 1; }
loud() { echo "" >&2; echo "############ $PROG ############" >&2; echo "$*" >&2; echo "###############################" >&2; echo "" >&2; }

# Locate + source the shared integrity helpers (build/ is this script's dir).
case "$0" in
*/*) _HERE=${0%/*} ;;
*)   _HERE=. ;;
esac
if [ -f "$_HERE/lib-integrity.sh" ]; then
	# shellcheck source=build/lib-integrity.sh
	. "$_HERE/lib-integrity.sh"
else
	die "missing $_HERE/lib-integrity.sh (integrity helpers) -- refusing to run"
fi

usage() {
	cat >&2 <<USAGE
usage: VELO_I_AM_SURE=yes $PROG <velo79.img> <target-device>

  M4 HARD STOP -- writes <velo79.img> to <target-device>, DESTROYING it.
  <target-device> is a bare OpenBSD disk name, e.g. sd2 (NOT /dev/sd2, NOT a
  partition like sd2a).  There is NO default device.

  Without VELO_I_AM_SURE=yes this is a DRY-RUN: it prints the dd it WOULD run
  and writes nothing.
USAGE
	exit 2
}

IMG=${1:-}
DEV=${2:-}
[ -n "$IMG" ] || usage
[ -n "$DEV" ] || die "no explicit target device given -- refusing to guess. Pass the device name (e.g. sd2)."

loud "M4 HARD STOP: this script writes a raw disk and DESTROYS it. Read every line."

# ===========================================================================
#  GUARD 0 -- the image must exist and be non-empty.
# ===========================================================================
[ -f "$IMG" ] || die "image not found: $IMG (run assemble-media.sh first)"
[ -s "$IMG" ] || die "image is empty: $IMG"

# GUARD 0b -- INTEGRITY.  If the producer (assemble-media / grow-media) dropped a
# .sha256 sidecar, the image MUST match it before we dd it -- a corrupted or
# wrong image aborts here, pre-write.  A missing sidecar is a LOUD WARN (older
# images predate it; the whole path is supervised), never a silent pass.
if [ -f "$IMG.sha256" ]; then
	if vi_sidecar_verify "$IMG"; then
		say "INTEGRITY OK: $IMG matches $IMG.sha256"
	else
		die "INTEGRITY FAIL: $IMG does not match $IMG.sha256 -- refusing to write a tampered/corrupted image. HARD REFUSAL."
	fi
else
	say "WARNING: no integrity sidecar $IMG.sha256 -- provenance unverifiable (older image?). Proceeding under supervision."
fi

# ===========================================================================
#  GUARD 1 -- the device argument must be a BARE whole-disk name (sdN / wdN),
#             never a partition (sd2a), never a /dev/ path, never metachars.
#             This is the same whitelist shape velo-install enforces.
# ===========================================================================
case "$DEV" in
sd[0-9]|sd[0-9][0-9]|wd[0-9]|wd[0-9][0-9]) : ;;
*) die "target [$DEV] is not a bare whole-disk name (sdN/wdN). Refusing. Do NOT pass /dev/..., a partition letter, or anything else." ;;
esac

# ===========================================================================
#  GUARD 2 -- ENV ARMING.  Refuse to write unless VELO_I_AM_SURE=yes was set in
#             the environment by a HUMAN this session.  No default; no
#             prompt-only bypass.  When unset, we proceed to a DRY-RUN that
#             prints the dd and writes nothing.
# ===========================================================================
ARMED=no
[ "${VELO_I_AM_SURE:-no}" = "yes" ] && ARMED=yes

# ===========================================================================
#  GUARD 3 -- the target must NOT be the ROOT/BOOT disk.  Derive the disk that
#             backs '/' from `df /` (strip /dev/ and the partition letter) and
#             refuse if it matches the target.  (df(1), mount(8).)
# ===========================================================================
ROOTDEV=$(df / 2>/dev/null | awk 'NR==2{print $1}')
# /dev/sd0a -> sd0  (strip the leading /dev/ and the trailing partition letter)
ROOTDISK=$(echo "$ROOTDEV" | sed 's,^/dev/,,; s,[a-p]$,,')
if [ -z "$ROOTDISK" ] && [ "$ARMED" = yes ]; then
	die "ARMED but cannot determine the root disk from 'df /' -- refusing a degraded-mode armed write. HARD REFUSAL."
fi
if [ -n "$ROOTDISK" ] && [ "$DEV" = "$ROOTDISK" ]; then
	die "target $DEV IS the ROOT disk ($ROOTDISK backs '/'). HARD REFUSAL."
fi
say "root disk is ${ROOTDISK:-<unknown>} (target $DEV differs -- good)"

# ===========================================================================
#  GUARD 4 -- the target must currently be UNMOUNTED everywhere.  Any mounted
#             partition of $DEV (sd2a, sd2d, ...) means it is in use -- refuse.
#             (mount(8) lists `/dev/<dev><letter> on ...`.)
# ===========================================================================
_mounttab=$(mount 2>/dev/null || true)
if [ -z "$_mounttab" ] && [ "$ARMED" = yes ]; then
	die "ARMED but mount(8) produced no output -- cannot verify $DEV is unmounted. Refusing a degraded-mode armed write. HARD REFUSAL."
fi
if echo "$_mounttab" | grep -q "^/dev/${DEV}[a-p] "; then
	echo "$PROG: mounted partitions on $DEV:" >&2
	echo "$_mounttab" | grep "^/dev/${DEV}[a-p] " >&2 || true
	die "$DEV has mounted partitions -- unmount them first, or it is the wrong disk. HARD REFUSAL."
fi

# ===========================================================================
#  GUARD 5 -- the device must actually EXIST as a known disk.  `sysctl -n
#             hw.disknames` lists every disk (name:DUID,...); refuse a target
#             that is not present (typo / phantom node).
# ===========================================================================
DISKNAMES=$(sysctl -n hw.disknames 2>/dev/null || true)
if [ -n "$DISKNAMES" ]; then
	_found=no
	_oifs=$IFS
	IFS=','
	for _tok in $DISKNAMES; do
		_name=${_tok%%:*}
		[ "$_name" = "$DEV" ] && _found=yes
	done
	IFS=$_oifs
	[ "$_found" = yes ] || die "$DEV is not in hw.disknames ([$DISKNAMES]) -- unknown/absent device. HARD REFUSAL."
	say "$DEV is present in hw.disknames"
else
	# FAIL CLOSED when ARMED: an armed write whose existence check could not even
	# run is a degraded-mode write -- exactly what we must never do.  Only the
	# unarmed DRY-RUN may proceed past an unreadable hw.disknames.
	if [ "$ARMED" = yes ]; then
		die "ARMED but hw.disknames is unreadable -- cannot verify $DEV exists. Refusing a degraded-mode armed write. HARD REFUSAL."
	fi
	say "WARNING: could not read hw.disknames (not on OpenBSD?) -- DRY-RUN only; an ARMED write here would HARD REFUSE"
fi

# ===========================================================================
#  GUARD 6 -- SIZE SANITY.  The image must FIT the device, and the device must
#             not be implausibly large (an internal SSD/HDD, not a USB stick).
#             Sizes from `disklabel` (total sectors * sector size).  If the
#             device is larger than VELO_MAX_DEV_BYTES (default 256 GiB),
#             refuse unless VELO_HUGE_OK=yes -- a USB install stick is small;
#             a 256 GB+ target is almost certainly the wrong (system) disk.
# ===========================================================================
IMG_BYTES=$(wc -c < "$IMG")
IMG_BYTES=${IMG_BYTES##* }

DEV_BYTES=""
_label=$(disklabel "$DEV" 2>/dev/null || true)
if [ -n "$_label" ]; then
	# `total sectors: N` and `sectors/track`/`bytes/sector` come from disklabel.
	_secsz=$(echo "$_label" | sed -n 's/^bytes\/sector: *\([0-9]*\).*/\1/p' | head -n1)
	_totsec=$(echo "$_label" | sed -n 's/^total sectors: *\([0-9]*\).*/\1/p' | head -n1)
	[ -z "$_secsz" ] && _secsz=512
	if [ -n "$_totsec" ]; then
		DEV_BYTES=$(( _totsec * _secsz ))
	fi
fi

MAX_DEV_BYTES=${VELO_MAX_DEV_BYTES:-274877906944}   # 256 GiB
if [ -n "$DEV_BYTES" ]; then
	say "image = $IMG_BYTES bytes; device $DEV = $DEV_BYTES bytes"
	if [ "$IMG_BYTES" -gt "$DEV_BYTES" ]; then
		die "image ($IMG_BYTES B) is LARGER than $DEV ($DEV_BYTES B) -- this is not the stick you think. HARD REFUSAL."
	fi
	if [ "$DEV_BYTES" -gt "$MAX_DEV_BYTES" ] && [ "${VELO_HUGE_OK:-no}" != "yes" ]; then
		die "$DEV is $DEV_BYTES B (> $MAX_DEV_BYTES B) -- implausibly large for a USB install stick; this looks like a SYSTEM DISK. Refusing. (Set VELO_HUGE_OK=yes only if you are 100% certain.)"
	fi
else
	# FAIL CLOSED when ARMED: if disklabel could not give us a size, the
	# image-fits and not-a-system-disk checks never ran.  An armed write with no
	# size sanity is a degraded-mode write -- refuse it.  Only the unarmed
	# DRY-RUN may proceed past an unreadable size.
	if [ "$ARMED" = yes ]; then
		die "ARMED but could not read $DEV size via disklabel -- size sanity could not run. Refusing a degraded-mode armed write. HARD REFUSAL."
	fi
	say "WARNING: could not read $DEV size via disklabel -- size sanity SKIPPED (DRY-RUN only; an ARMED write here would HARD REFUSE)."
fi

# ===========================================================================
#  Show the operator EXACTLY what they are about to erase, then demand a typed
#  confirmation of the device name -- GUARD 7.
# ===========================================================================
echo "" >&2
echo "----------------------------------------------------------------" >&2
echo "ABOUT TO OVERWRITE THE WHOLE DISK: $DEV  (/dev/r${DEV}c)" >&2
echo "  image : $IMG  ($IMG_BYTES bytes)" >&2
echo "  device: $DEV  ${DEV_BYTES:+($DEV_BYTES bytes)}" >&2
echo "  label :" >&2
disklabel "$DEV" 2>/dev/null | sed -n '1,8p' >&2 || echo "  (disklabel unavailable)" >&2
echo "----------------------------------------------------------------" >&2

# ===========================================================================
#  DRY-RUN vs REAL.  If not armed, print the dd we WOULD run and stop here.
# ===========================================================================
DD_CMD="dd if=\"$IMG\" of=/dev/r${DEV}c bs=1m status=progress"

if [ "$ARMED" != yes ]; then
	loud "DRY-RUN (VELO_I_AM_SURE is not 'yes'). NOTHING was written."
	echo "$PROG: would run:" >&2
	echo "    $DD_CMD" >&2
	echo "$PROG: to actually write, set VELO_I_AM_SURE=yes AND pass the typed confirmation." >&2
	exit 0
fi

# Armed: demand the typed confirmation phrase -- GUARD 7.  The operator must
# retype the EXACT device name; a mismatch aborts.
loud "ARMED (VELO_I_AM_SURE=yes). This WILL destroy $DEV."
printf '%s' "$PROG: type the device name again to confirm ($DEV): " >&2
IFS= read -r CONFIRM || die "no confirmation read -- aborted"
[ "$CONFIRM" = "$DEV" ] || die "confirmation [$CONFIRM] != [$DEV] -- aborted, nothing written."

# ===========================================================================
#  ALL GUARDS PASSED.  Write to the RAW char device (whole disk, /dev/r<dev>c).
# ===========================================================================
say "all guards passed -- writing $IMG to $DEV ..."
# shellcheck disable=SC2086
dd if="$IMG" of=/dev/r"${DEV}"c bs=1m status=progress
sync
say "DONE: wrote $IMG to $DEV. Eject safely before removing the stick."
