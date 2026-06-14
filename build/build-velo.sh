#!/bin/ksh
# build/build-velo.sh -- patch a pristine OpenBSD 7.9 bsd.rd with the velo TUI
# installer + the /.profile launch hook.
#
# ============================================================================
#  WHERE THIS RUNS
#  --------------------------------------------------------------------------
#  This script RUNS INSIDE the OpenBSD 7.9 VM (or on real OpenBSD).  It needs
#  base tools that DO NOT EXIST on the Void/Linux build host:
#      rdsetroot(8)  vnconfig(8)  mount(8)/umount(8)  disklabel(8)  install(1)
#  On the Void host it can only be PARSE-LINTED:
#      /usr/sbin/ksh -n build/build-velo.sh
#      bash          -n build/build-velo.sh
#  Every OpenBSD command below is grounded in its man page and the reference
#  rd-patch projects (echothrust/openbsd-patchrd, ezaquarii/openbsd-autoinstall);
#  see docs/m3-design.md s1 and docs/constraints.md s6.
#
#  WHAT IT PRODUCES
#  --------------------------------------------------------------------------
#  IN:   a pristine 7.9 bsd.rd (extracted from install79.iso/.img's
#        7.9/amd64/bsd.rd, or fetched from a 7.9 mirror -- same patch level
#        as the sets on the media).
#  OUT:  dist/bsd.rd.velo -- a gzip'd ramdisk kernel byte-identical to stock
#        EXCEPT its embedded root filesystem now carries:
#            /velo-tui.ksh        (from src/velo-tui.ksh,        0644)
#            /velo-install        (from src/velo-install,        0755)
#            /velo-rd-hook.sh     (from build/velo-rd-hook.sh,   0755)
#        and ONE sentinel-guarded line spliced into /.profile -- INSERTED just
#        ABOVE the stock interactive menu loop ('while :; do ... read REPLY')
#        so velo runs FIRST, around the menu (not appended after it).
#  It changes nothing else: same kernel, same instbin crunch, same install.sub.
#
#  SAFETY POSTURE
#  --------------------------------------------------------------------------
#   - FILE IMAGES ONLY.  vnconfig is pointed at a temp FILE (the extracted
#     disk.fs), never a /dev/* device node.  There is NO `dd of=/dev/...` here.
#     This is what makes build-velo safe to run autonomously in the VM.
#   - IDEMPOTENT.  The /.profile hook is sentinel-guarded; re-running on an
#     already-patched rd does not double-insert.  The pristine input is never
#     mutated (we work on a COPY).
#   - It REFUSES to proceed if auto_install.conf is present in the ramdisk
#     (that file arms a 5s timeout that bypasses the interactive menu -- the
#     one bright-line constraints rule; docs/constraints.md s6).  It never
#     CREATES auto_install.conf.
#   - SIZE CEILING enforced: rdsetroot -s prints the reserved rd_root_image
#     budget; if our additions overflow it, the script FAILS LOUDLY before
#     write-back rather than corrupting the kernel.
#
#  Target shell: the VM's /bin/ksh.  Authored to also parse clean under the
#  host's oksh and bash (the M1/M2 rule: a construct that passes one shell but
#  not another is a bug).
# ============================================================================

set -eu

PROG=build-velo

log() { echo "$PROG: $*"; }
die() { echo "$PROG: ERROR: $*" >&2; exit 1; }

usage() {
	echo "usage: $PROG <pristine-bsd.rd> [out-bsd.rd]" >&2
	echo "  RUNS IN THE OpenBSD 7.9 VM (needs rdsetroot/vnconfig/mount)." >&2
	echo "  Operates on FILE IMAGES only; never touches a /dev/* device." >&2
	exit 2
}

# --- locate the repo root from THIS script's path (build/ is one level down) -
# `dirname` is absent in the install ramdisk; use parameter expansion (same
# pattern as make-site-tgz.sh and velo-install).  This script runs in the VM
# where dirname DOES exist, but we keep the portable idiom for consistency.
case "$0" in
*/*) _HERE=${0%/*} ;;
*)   _HERE=. ;;
esac
REPO=$(cd "$_HERE/.." && pwd)

RD_IN=${1:-}
[ -n "$RD_IN" ] || usage
RD_OUT=${2:-$REPO/dist/bsd.rd.velo}

SRC_TUI="$REPO/src/velo-tui.ksh"
SRC_INSTALL="$REPO/src/velo-install"
SRC_HOOK="$REPO/build/velo-rd-hook.sh"

# --- preflight: refuse early on obvious mistakes ---------------------------
[ -f "$RD_IN" ]      || die "input bsd.rd not found: $RD_IN"
[ -f "$SRC_TUI" ]    || die "missing $SRC_TUI"
[ -f "$SRC_INSTALL" ]|| die "missing $SRC_INSTALL"
[ -f "$SRC_HOOK" ]   || die "missing $SRC_HOOK (the ramdisk launcher)"

# Refuse to write back over the pristine input by accident.
if [ "$RD_IN" = "$RD_OUT" ]; then
	die "refusing: output ($RD_OUT) equals input -- choose a different out path"
fi

# This is an OpenBSD-only step.  Fail clearly if the base tools are missing
# (e.g. someone ran it on the Void host instead of linting it).
for _t in rdsetroot vnconfig mount umount install gzip; do
	command -v "$_t" >/dev/null 2>&1 || \
		die "'$_t' not found -- this script must run on OpenBSD (the VM), not the Void host. Lint here with: ksh -n / bash -n"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/velo-rd.XXXXXX") || die "mktemp failed"
FS="$WORK/disk.fs"
MNT="$WORK/mnt"
RAW="$WORK/bsd.rd.raw"
mkdir -p "$MNT"

# Clean up on ANY exit: unmount, detach vnd, drop the workdir.  VND is captured
# once vnconfig succeeds; the trap tolerates an empty VND (nothing to detach).
# Order matters: umount BEFORE vnconfig -u.
VND=""
cleanup() {
	if [ -n "$VND" ]; then
		umount "$MNT" 2>/dev/null || true
		vnconfig -u "$VND" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Work on a COPY so the pristine bsd.rd is never mutated.
# ---------------------------------------------------------------------------
cp "$RD_IN" "$WORK/bsd.rd.in"

# ---------------------------------------------------------------------------
# 2. bsd.rd ships gzip'd; rdsetroot needs the uncompressed kernel.  `gzip -t`
#    detects the format so we are robust to an already-raw input (rare).
# ---------------------------------------------------------------------------
# Detect gzip by MAGIC (1f 8b), NOT by `gzip -t FILE`: OpenBSD's gzip(1) refuses a
# file whose name lacks a recognized suffix ("unknown suffix: ignored", exit 2), so
# a suffix-based test mis-detects a gzip'd bsd.rd as raw and feeds it to rdsetroot
# ("not an elf").  amd64 7.9 ships bsd.rd gzip'd.  Read the 2-byte magic, and
# decompress from STDIN so gzip never applies its suffix logic.  (od/tr are base,
# present in the full VM where this runs; absent only in the install ramdisk.)
MAGIC=$(od -An -tx1 -N2 "$WORK/bsd.rd.in" | tr -d ' \n')
if [ "$MAGIC" = "1f8b" ]; then
	log "input is gzip'd (magic 1f8b) -- decompressing"
	gzip -dc < "$WORK/bsd.rd.in" > "$RAW"
else
	log "input is already an uncompressed kernel (magic $MAGIC)"
	cp "$WORK/bsd.rd.in" "$RAW"
fi

# ---------------------------------------------------------------------------
# 3. SIZE CEILING.  rdsetroot -s prints the reserved rd_root_image size in
#    bytes without modifying anything (rdsetroot(8) -s).  This is the hard
#    in-place budget; capture it BEFORE we grow the fs so we can refuse early.
#    (docs/constraints.md UNVERIFIED #5.)
# ---------------------------------------------------------------------------
CEIL=$(rdsetroot -s "$RAW") || die "rdsetroot -s failed (is this a RAMDISK kernel?)"
case "$CEIL" in
''|*[!0-9]*) die "rdsetroot -s returned a non-numeric ceiling: [$CEIL]" ;;
esac
log "rd_root_image ceiling = $CEIL bytes"

# ---------------------------------------------------------------------------
# 4. EXTRACT the embedded filesystem image out of the kernel.
#    rdsetroot -x <kernel> <fsfile>  copies the rd section OUT (rdsetroot(8) -x).
# ---------------------------------------------------------------------------
rdsetroot -x "$RAW" "$FS" || die "rdsetroot -x failed (could not extract rd image)"
[ -s "$FS" ] || die "extracted fs image is empty"

# ---------------------------------------------------------------------------
# 5. ATTACH the fs image to a vnd(4) pseudo-device.  vnconfig attaches a
#    REGULAR FILE as a block device and prints the unit it chose; capture it,
#    never hardcode vnd0 (another build may already hold it).  (vnconfig(8).)
# ---------------------------------------------------------------------------
VND=$(vnconfig "$FS") || die "vnconfig failed on the fs image"
case "$VND" in
vnd[0-9]*) : ;;
*) die "vnconfig returned an unexpected unit: [$VND]" ;;
esac
log "attached fs image as /dev/$VND"

# ---------------------------------------------------------------------------
# 6. MOUNT the ramdisk fs read-write.  The install rd is a single FFS slice
#    'a' (patchrd uses exactly `mount -t ffs /dev/vnd0a /mnt`).
# ---------------------------------------------------------------------------
mount /dev/"${VND}"a "$MNT" || die "mount of /dev/${VND}a failed"

# ---------------------------------------------------------------------------
# 7. SANITY: this really is the install ramdisk (carries install.sub and a
#    dot.profile-derived /.profile), and -- the bright-line rule -- it has NO
#    auto_install.conf.  Assert BEFORE we touch anything.
# ---------------------------------------------------------------------------
[ -f "$MNT/install.sub" ] || die "not an install ramdisk? (no /install.sub on the image)"
[ -f "$MNT/.profile" ]    || die "ramdisk has no /.profile to hook (unexpected layout)"
if [ -e "$MNT/auto_install.conf" ]; then
	die "REFUSING -- auto_install.conf present in the ramdisk (it arms a 5s timeout that bypasses the interactive menu). velo never creates or tolerates it."
fi

# ---------------------------------------------------------------------------
# 8. INJECT the velo files.  install(1) sets owner root:wheel and the mode in
#    one atomic step.  velo-install is executable; the library and hook get the
#    same modes they carry in the repo.
# ---------------------------------------------------------------------------
install -o root -g wheel -m 0644 "$SRC_TUI"     "$MNT/velo-tui.ksh"
install -o root -g wheel -m 0755 "$SRC_INSTALL" "$MNT/velo-install"
install -o root -g wheel -m 0755 "$SRC_HOOK"    "$MNT/velo-rd-hook.sh"
log "injected /velo-tui.ksh /velo-install /velo-rd-hook.sh"

# ---------------------------------------------------------------------------
# 9. HOOK /.profile -- INSERT one sentinel-guarded source line *BEFORE* the
#    stock interactive menu loop, not after.  An append after the closing 'fi'
#    runs only once the operator has already left the menu (or never, since the
#    menu's `&& break` exits the loop *and* the enclosing block) -- too late to
#    wrap the menu.  velo must run FIRST, around the menu, so we splice the hook
#    line in on the line ABOVE the menu loop.
#
#    ANCHOR (and why it is stable):
#      The stock 7.9 dot.profile (distrib/miniroot/dot.profile, $OpenBSD rev
#      1.52) drives the installer choice with a single interactive loop that
#      opens with the literal line:
#
#          \twhile :; do                      (one leading TAB, inside the
#                                              `if [[ -z $DONEPROFILE ]]` block)
#          \t\tread REPLY?'(I)nstall, (U)pgrade, (A)utoinstall or (S)hell? '
#          ...
#
#      We anchor on `while :; do` (matched anywhere on the line, tab-indented or
#      not).  That loop header is the ONE structurally invariant feature of the
#      menu across every modern release: the prompt wording, the autoinstall
#      timeout block above it, and the case arms below it have all churned over
#      versions, but the menu has always been a `while :; do ... read REPLY ...
#      done` loop.  Inserting on the line above it puts the velo launcher just
#      before the first `read REPLY`, so velo owns the console first; on
#      ESC/cancel/non-tty the hook RETURNS and the still-pending stock menu's
#      first `read REPLY` runs, so (I)/(U)/(A)/(S) remain reachable.
#
#    We refuse if the anchor is absent (an unexpected dot.profile layout) rather
#    than silently appending to the wrong place.  The sentinel marker makes a
#    re-run idempotent (mirrors the M2 install.site sentinel-guard idiom);
#    grep -qF matches the marker as a literal substring.
# ---------------------------------------------------------------------------
HOOK_MARK="# --- velo hook (injected by build-velo) ---"
if grep -qF -- "$HOOK_MARK" "$MNT/.profile"; then
	log "/.profile already carries the velo hook -- not re-inserting (idempotent)"
else
	grep -qE '^[[:space:]]*while :; do' "$MNT/.profile" || \
		die "could not find the stock menu loop anchor ('while :; do') in /.profile -- unexpected dot.profile layout; refusing to hook blindly."
	# Splice the 3-line hook block in on the line ABOVE the first menu loop.
	# Single-pass awk: on the first `while :; do`, emit the hook block, then the
	# line, then disarm so we never touch a second (there is only one, but be
	# precise).  Preserves the rest of the file byte-for-byte.  Write to a temp
	# and move so a failed awk never truncates /.profile.
	awk -v mark="$HOOK_MARK" '
		!done && /^[[:space:]]*while :; do/ {
			print mark
			print ". /velo-rd-hook.sh"
			print ""
			done = 1
		}
		{ print }
	' "$MNT/.profile" > "$MNT/.profile.velo.$$" || die "awk hook insertion failed"
	# Confirm the splice actually landed before replacing the original.
	grep -qF -- "$HOOK_MARK" "$MNT/.profile.velo.$$" || \
		die "hook insertion produced no marker -- aborting, /.profile left untouched"
	cat "$MNT/.profile.velo.$$" > "$MNT/.profile"
	rm -f "$MNT/.profile.velo.$$"
	log "inserted the velo hook into /.profile just above the stock menu loop"
fi

# ---------------------------------------------------------------------------
# 10. UNMOUNT + DETACH cleanly (umount BEFORE vnconfig -u).  Clear VND so the
#     EXIT trap does not try to detach an already-detached unit.
# ---------------------------------------------------------------------------
sync
umount "$MNT"
vnconfig -u "$VND"
VND=""

# ---------------------------------------------------------------------------
# 11. SIZE CHECK before write-back: the (possibly grown) fs image must still
#     fit the kernel's reserved rd section.  If it overflows, FAIL LOUDLY --
#     the fix is to rebuild the RAMDISK kernel with a bigger image (a separate,
#     larger task flagged in docs/constraints.md UNVERIFIED #5).  v0.1 expects
#     our few-KB additions to fit the slack the stock rd carries.
# ---------------------------------------------------------------------------
FSZ=$(wc -c < "$FS")
FSZ=${FSZ##* }            # wc may pad with leading spaces; keep the number only
case "$FSZ" in
''|*[!0-9]*) die "could not read patched fs size" ;;
esac
if [ "$FSZ" -gt "$CEIL" ]; then
	die "patched fs $FSZ B > ceiling $CEIL B -- will not fit in place. Rebuild the RAMDISK kernel with a larger rd_root_image (docs/constraints.md UNVERIFIED #5)."
fi
log "patched fs $FSZ B fits ceiling $CEIL B (slack $((CEIL - FSZ)) B)"

# ---------------------------------------------------------------------------
# 12. WRITE the patched fs back INTO the kernel's rd section.  Plain rdsetroot
#     (no -x) copies fsfile IN -- the inverse of -x (rdsetroot(8)).
# ---------------------------------------------------------------------------
rdsetroot "$RAW" "$FS" || die "rdsetroot write-back failed"

# ---------------------------------------------------------------------------
# 13. RE-COMPRESS to the shipped gzip form and emit atomically.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$RD_OUT")"
gzip -9 -c < "$RAW" > "$RD_OUT.tmp.$$"     # stdin form: no OpenBSD gzip suffix quirk
mv -f "$RD_OUT.tmp.$$" "$RD_OUT"
log "wrote $RD_OUT"
log "done. Next: build/assemble-media.sh <install79.img> $RD_OUT <site79.tgz>"
