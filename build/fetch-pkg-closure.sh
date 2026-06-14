#!/bin/sh
# build/fetch-pkg-closure.sh -- populate the OFFLINE package closure that velo
# ships in site79.tgz (site/usr/obj/_pkgs/*.tgz).
#
# WHERE THIS RUNS
# ---------------------------------------------------------------------------
# On the OpenBSD 7.9 amd64 BUILD VM (it needs pkg_add + a working package
# mirror).  It does NOT run on the Void host -- pkg_add is OpenBSD-only.  The
# Void-host packer build/make-site-tgz.sh only checks the closure; THIS script
# is the step that fills it (the "M3-VM step" make-site-tgz's header refers to).
#
# WHY
# ---------------------------------------------------------------------------
# velo is an OFFLINE installer: /etc/rc.firsttime runs `pkg_add` from the local
# closure (PKG_PATH=/usr/obj/_pkgs) with NO network guaranteed.  So EVERY package
# any profile can request -- AND its full dependency tree -- must be present as a
# .tgz blob here, or first-boot pkg_add installs only `quirks` and bails (exactly
# the desktop-never-came-up bug found live 2026-06-06: the closure held the
# fortress set but no xfce/firefox/chromium/mpv).
#
# HOW
# ---------------------------------------------------------------------------
# The build VM is DISPOSABLE, so we let pkg_add actually install the UNION of all
# profile lists with PKG_CACHE pointed at a scratch dir.  pkg_add caches EVERY
# file it downloads -- top-level packages AND their dependency closure -- as
# complete .tgz blobs there.  We then copy those blobs into site/usr/obj/_pkgs/.
# (Caching-via-install is the reliable way to get the FULL closure; `-n` does not
# fetch complete files.)
#
# Package set = the UNION of site/usr/obj/_pkgs/{minimal,desktop,fortress}.list,
# which make-site-tgz.sh self-checks against profile_pkgs() in src/velo-install,
# so this script and the wizard can never disagree on what to fetch.
#
# Override the mirror with PKG_PATH (else /etc/installurl is used), e.g.
#   PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/7.9/packages/amd64/ \
#       doas build/fetch-pkg-closure.sh
#
# After it finishes, RE-RUN build/make-site-tgz.sh -- its blob-presence guard
# (step 1b) now passes, and dist/site79.tgz carries a complete desktop closure.
#
# Parse-clean under sh -n, bash -n, oksh -n.

set -eu

# --- locate the repo root from THIS script's path (build/ is one level down) ---
case "$0" in
*/*) _HERE=${0%/*} ;;
*)   _HERE=. ;;
esac
REPO=$(cd "$_HERE/.." && pwd)
DEST="$REPO/site/usr/obj/_pkgs"

die() { echo "fetch-pkg-closure: $*" >&2; exit 1; }

# --- guards: OpenBSD + pkg_add + the closure dir + the .list files ------------
[ "$(uname -s)" = OpenBSD ] || die "must run on the OpenBSD 7.9 build VM (uname=$(uname -s)); pkg_add is OpenBSD-only."
command -v pkg_add >/dev/null 2>&1 || die "pkg_add not found."
[ -d "$DEST" ] || die "closure dir not found: $DEST"

# --- build the de-duplicated package UNION from the three profile lists -------
# Read non-blank/non-comment lines from each list; sort -u to de-dup.  No arrays
# (portable sh): accumulate into a newline string, then `sort -u`.
_raw=""
for _p in minimal desktop fortress; do
	_lf="$DEST/${_p}.list"
	[ -f "$_lf" ] || die "missing $_lf (run make-site-tgz self-check first)."
	while IFS= read -r _ln; do
		case "$_ln" in
		""|"#"*) ;;
		*) _raw="$_raw$_ln
" ;;
		esac
	done <"$_lf"
done
UNION=$(printf '%s' "$_raw" | sort -u)
[ -n "$UNION" ] || die "no packages parsed from the .list files."

echo "fetch-pkg-closure: package union to resolve:"
printf '  %s\n' $UNION
echo "fetch-pkg-closure: mirror = ${PKG_PATH:-(/etc/installurl)}"

# --- fetch the full closure via a cached install ------------------------------
# Scratch cache dir (NOT under DEST, so a failed run cannot leave partials in the
# shipped tree).  PKG_CACHE makes pkg_add keep a copy of every fetched .tgz.
CACHE=$(mktemp -d "${VELO_PKGCACHE_DIR:-/tmp}/velo-pkgcache.XXXXXX") || die "mktemp failed."
trap 'rm -rf "$CACHE"' EXIT INT TERM
export PKG_CACHE="$CACHE"

echo "fetch-pkg-closure: pkg_add -I (installing on this DISPOSABLE VM to harvest the closure into $CACHE) ..."
# shellcheck disable=SC2086  -- deliberate word-split of the package union.
pkg_add -I $UNION || die "pkg_add failed -- check the mirror / package names."

_n=$(ls "$CACHE"/*.tgz 2>/dev/null | wc -l | tr -d ' ')
[ "${_n:-0}" -gt 0 ] || die "no .tgz cached -- nothing fetched (mirror reachable?)."
echo "fetch-pkg-closure: harvested $_n package blobs."

# --- copy the closure into the shipped tree -----------------------------------
cp "$CACHE"/*.tgz "$DEST"/ || die "copy into $DEST failed."
echo "fetch-pkg-closure: copied $_n blobs into $DEST"

# --- verify EVERY listed package now has a version-anchored blob --------------
# Same rule as make-site-tgz's step-1b guard (stem-<digit>); a final fail-closed
# check so a partial fetch can't masquerade as complete.
_miss=0
for _tok in $UNION; do
	_found=0
	for _f in "$DEST/$_tok"-[0-9]*.tgz; do
		[ -e "$_f" ] && { _found=1; break; }
	done
	[ "$_found" = 1 ] || { echo "fetch-pkg-closure: STILL MISSING blob for '$_tok'" >&2; _miss=1; }
done
[ "$_miss" = 0 ] || die "closure incomplete after fetch -- see missing packages above."

echo "fetch-pkg-closure: OK -- closure complete for all profiles."
echo "fetch-pkg-closure: next -> re-run build/make-site-tgz.sh to repack dist/site79.tgz."
