#!/bin/sh
# build/fetch-iwm-firmware.sh -- bake the non-free Intel iwm(4) WiFi firmware for
# the Wireless-AC 8265 (iwm0) into the shipped tree (site/etc/firmware/), so the
# installed system brings WiFi up OFFLINE on first boot.
#
# WHERE THIS RUNS
# ---------------------------------------------------------------------------
# On the OpenBSD 7.9 amd64 BUILD VM: it needs ftp(1), the OpenBSD firmware
# tarball layout, and NAT internet to reach firmware.openbsd.org.  It does NOT
# run on the Void host.  Run it right after build/fetch-pkg-closure.sh.
#
# WHY a pre-placed blob (and NOT fw_update at first boot)
# ---------------------------------------------------------------------------
# iwm(4) loads /etc/firmware/iwm-8265-36 from the filesystem at ifconfig-up --
# no registry, no network.  fw_update would need its own surviving dir + the
# signify pubkey + a live network; velo is offline.  So we ship the extracted
# blob directly and the iwm driver reads it as-is.  NOTE: the members inside the
# OpenBSD firmware tarball live under firmware/ (top-level), NOT etc/firmware/.
#
# Parse-clean under sh -n, bash -n, oksh -n.

set -eu

case "$0" in
*/*) _HERE=${0%/*} ;;
*)   _HERE=. ;;
esac
REPO=$(cd "$_HERE/.." && pwd)
FWDEST="$REPO/site/etc/firmware"
# Plain HTTP on purpose: firmware.openbsd.org presents a TLS altname mismatch.
# Plain HTTP is therefore NOT the integrity boundary -- signify is (see below).
FWURL="http://firmware.openbsd.org/firmware/7.9"
# OpenBSD signs the firmware SHA256.sig with the per-release *firmware* key
# (fw_update(8) FILES: /etc/signify/openbsd-XX-fw.pub) -- NOT the base key.
FWPUB="${VELO_FW_PUB:-/etc/signify/openbsd-79-fw.pub}"

# shellcheck source=build/lib-integrity.sh
. "$_HERE/lib-integrity.sh"

die() { echo "fetch-iwm-firmware: $*" >&2; exit 1; }

[ "$(uname -s)" = OpenBSD ] || die "must run on the OpenBSD 7.9 build VM (uname=$(uname -s)); needs ftp + OpenBSD tar layout."
command -v ftp >/dev/null 2>&1 || die "ftp not found."

CACHE=$(mktemp -d "${VELO_PKGCACHE_DIR:-/tmp}/velo-fwcache.XXXXXX") || die "mktemp failed."
trap 'rm -rf "$CACHE"' EXIT INT TERM
mkdir -p "$FWDEST" "$CACHE/fwx" || die "mkdir failed."

# Fetch the SIGNED manifest to a FILE (it is both the name source AND the
# integrity anchor) -- no hardcoded date, so an OpenBSD firmware bump within 7.9
# does not 404 us, and the exact bytes we name are the bytes we will verify.
ftp -o "$CACHE/SHA256.sig" "$FWURL/SHA256.sig" \
	|| die "could not fetch $FWURL/SHA256.sig (needed for signify verification)."
FWTGZ=$(sed -n 's/.*(\(iwm-firmware-[0-9]*\.tgz\)).*/\1/p' "$CACHE/SHA256.sig" | head -1)
[ -n "$FWTGZ" ] || die "could not resolve iwm-firmware tarball name from SHA256.sig"

echo "fetch-iwm-firmware: fetching $FWTGZ"
ftp -o "$CACHE/$FWTGZ" "$FWURL/$FWTGZ" || die "fetch failed."

# VERIFY before trusting the blob.  signify -C checks SHA256.sig's own signature
# with the release firmware pubkey AND that $FWTGZ matches its listed digest.
# This is the real integrity boundary (the transport was plain HTTP); FAIL CLOSED.
( cd "$CACHE" && vi_signify_release "$FWPUB" SHA256.sig "$FWTGZ" ) \
	|| die "signify verification of $FWTGZ FAILED (pubkey $FWPUB) -- refusing to ship unverified firmware."
echo "fetch-iwm-firmware: signify-verified $FWTGZ against $FWPUB"

tar -x -z -C "$CACHE/fwx" -f "$CACHE/$FWTGZ" || die "extract failed."

# Ship the whole iwm-8265-* family (a few MB, forward-compat across kernel
# firmware-revision bumps) plus the license; do NOT ship the full firmware/ tree.
cp "$CACHE/fwx/firmware/"iwm-8265-* "$FWDEST"/ || die "copy iwm-8265-* failed."
[ -f "$CACHE/fwx/firmware/iwm-license" ] && cp "$CACHE/fwx/firmware/iwm-license" "$FWDEST"/

# Fail-closed: the file iwm(4) actually names must exist and be non-empty.
[ -s "$FWDEST/iwm-8265-36" ] || die "iwm-8265-36 missing/empty after copy."

echo "fetch-iwm-firmware: baked [$(ls "$FWDEST" | tr '\n' ' ')] into $FWDEST"
