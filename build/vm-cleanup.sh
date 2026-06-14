#!/bin/sh
# build/vm-cleanup.sh -- list and optionally remove stale VM artefacts.
#
# By default runs in DRY-RUN mode: only prints what WOULD be removed.
# Pass --delete to actually delete AFTER reviewing the dry-run output.
#
# NEVER deletes:
#   - vm/homely-test-target.img  (current working acceptance disk)
#   - vm/*.png                   (acceptance screenshots -- evidence)
#   - vm/homely-*.log            (acceptance logs)
#   - vm/vga-accept*.{png,log}   (VGA acceptance evidence)
#   - vm/sercon-port.bin         (required by every boot script)
#   - dist/velo79.img            (current release installer image)
#   - dist/site79.tgz            (current release site archive)
#
# Candidates for removal:
#   - vm/*.img  matching failed/interrupted/pre-fix naming patterns
#   - vm/etap*-target.img        (old etap test disks, superseded by homely)
#   - vm/spike-target.img        (gateA spike disk)
#   - vm/blank5.img              (build-host blank -- only needed during build)
#   - vm/*.ppm                   (uncompressed screendumps, PNG equivalents kept)
#   - vm/build-host.img          (if it exists -- only needed during initial build)
#   - dist/build-host.img        (same)

set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
VM="$REPO/vm"
DIST="$REPO/dist"
DRY=1
[ "${1:-}" = "--delete" ] && DRY=0

say()  { printf '   %s\n' "$1"; }
mark() { printf '  [CANDIDATE] %s\n' "$1"; }

echo "=== velo vm-cleanup ${DRY:+DRY-RUN }==="
echo ""

# ---- KEEP list (never touch) -----------------------------------------------
echo "--- KEEP (protected) ---"
for f in \
    "$VM/homely-test-target.img" \
    "$VM/sercon-port.bin" \
    "$DIST/velo79.img" \
    "$DIST/site79.tgz"
do
    [ -e "$f" ] && say "KEEP  $f" || say "KEEP  $f  (not present)"
done
# PNG screendumps + acceptance logs
for f in "$VM"/*.png "$VM"/homely-*.log "$VM"/vga-accept*.log "$VM"/vga-accept*.png; do
    [ -e "$f" ] && say "KEEP  $f"
done 2>/dev/null || true
echo ""

# ---- CANDIDATES ------------------------------------------------------------
echo "--- CANDIDATES FOR REMOVAL ---"
TOTAL=0
add_candidate() {
    _f=$1
    [ -e "$_f" ] || return 0
    _sz=$(du -sh "$_f" 2>/dev/null | cut -f1)
    mark "$_f  ($_sz)"
    TOTAL=$((TOTAL + 1))
    if [ "$DRY" = 0 ]; then
        rm -rf "$_f" && printf '  [DELETED]   %s\n' "$_f"
    fi
}

# Homely failed/interrupted artefacts
for f in "$VM"/homely-test-target.failed-*.img \
         "$VM"/homely-test-target.interrupted-*.img \
         "$VM"/homely-test-target.pre-*.img; do
    add_candidate "$f" 2>/dev/null || true
done

# Old etap/stage disks superseded by homely pipeline
for f in "$VM"/etap4-l3target.img \
         "$VM"/etapB-target.img \
         "$VM"/etap8-target.img \
         "$VM"/velo-test-target.img \
         "$VM"/spike-target.img \
         "$VM"/desktop-test-target.img; do
    add_candidate "$f" 2>/dev/null || true
done

# Blank disks only needed during active build/test phases
add_candidate "$VM/blank5.img" 2>/dev/null || true
add_candidate "$VM/etap4-blank.img" 2>/dev/null || true
add_candidate "$VM/blank.img" 2>/dev/null || true

# Build-host images (large, only needed during initial build phase)
for f in "$VM"/build-host*.img "$DIST"/build-host*.img; do
    add_candidate "$f" 2>/dev/null || true
done

# Uncompressed PPM screendumps (large; PNG equivalents exist or old evidence)
for f in "$VM"/*.ppm; do
    add_candidate "$f" 2>/dev/null || true
done

# Old QEMU error logs (not acceptance logs)
for f in "$VM"/etap*-qemu.err "$VM"/etapB-*-qemu.err \
         "$VM"/gateA-*-qemu.err "$VM"/desktop-*-qemu.err \
         "$VM"/s10-*.err; do
    add_candidate "$f" 2>/dev/null || true
done

echo ""
if [ "$DRY" = 1 ]; then
    echo "DRY-RUN: $TOTAL candidate(s) listed above."
    echo "Review, then rerun with --delete to remove."
else
    echo "DONE: $TOTAL candidate(s) processed."
fi
