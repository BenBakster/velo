#!/bin/sh
# build/make-site-tgz.sh -- pack site/ into dist/site79.tgz (velo M2 packer).
#
# Produces a gzip tarball whose members are ROOTED AT '/' (so etc/doas.conf ->
# /etc/doas.conf), owned root:wheel, with velo-correct modes:
#     install.site.velo                  0755  (the only executable hook; velo
#                                              runs it chrooted, NOT auto-run)
#     etc/X11/xenodm/Xsetup_0            0755  (runs as a script)
#     etc/velo/answers (if present)      0600
#     etc/velo/pf/*.conf, /etc/pf.conf   0600  (pf rules)
#     etc/doas.conf                      0600  (doas refuses g/o-writable)
#     all other configs / dotfiles       0644
#     directories                        0755
#
# DETERMINISTIC / reproducible: sorted member order, fixed mtime, uid/gid 0,
# .keep-empty / .gitkeep excluded.  Same site/ input -> same site79.tgz bytes.
#
# IDEMPOTENT: re-running overwrites dist/site79.tgz cleanly via a fresh staging
# copy; it never mutates site/.
#
# SELF-CHECK: refuses to pack if any usr/obj/_pkgs/<profile>.list disagrees with
# profile_pkgs() in src/velo-install -- keeps M1/M2 byte-consistent.
#
# HOST: runs on the Void build host (needs only sh, tar, gzip, sort, cmp, grep,
# install/cp/chmod -- all present).  It does NOT populate usr/obj/_pkgs/*.tgz; those
# package blobs are an M3-VM step.
#
# Parse-clean under sh -n, bash -n, and oksh -n.

set -eu

# --- locate the repo root from THIS script's path (build/ is one level down) ---
case "$0" in
*/*) _HERE=${0%/*} ;;
*)   _HERE=. ;;
esac
REPO=$(cd "$_HERE/.." && pwd)

SITE="$REPO/site"
SRC="$REPO/src/velo-install"
DIST="$REPO/dist"
OUT="$DIST/site79.tgz"
MANIFEST="$DIST/site79.manifest.txt"

# Fixed epoch for reproducible mtimes (2020-01-01 UTC). Override via SOURCE_DATE_EPOCH.
FIXED_DATE='2020-01-01 00:00:00 UTC'

die() { echo "make-site-tgz: $*" >&2; exit 1; }

[ -d "$SITE" ] || die "site tree not found: $SITE"
[ -f "$SITE/install.site.velo" ] || die "missing $SITE/install.site.velo"
[ -f "$SRC" ] || die "missing $SRC (needed for the profile-list self-check)"

# list_join FILE -- echo the non-blank, non-comment lines of FILE joined by
# single spaces (one trailing space).  Defined at TOP LEVEL (not inside a $()),
# because some ksh builds (Void's PD-ksh) mis-parse a `case` lexically nested
# inside $()/command substitution.  Callers use $(list_join ...) -- the `case`
# lives here, not in the caller's command substitution.  Portable sh/ksh/bash.
list_join() {
	while IFS= read -r _lj_ln; do
		case "$_lj_ln" in
		""|"#"*) ;;
		*) printf '%s ' "$_lj_ln" ;;
		esac
	done <"$1"
}

# ---------------------------------------------------------------------------
# 1. SELF-CHECK: usr/obj/_pkgs/<profile>.list == profile_pkgs() from src/velo-install.
#    Source velo-install with VELO_SOURCED=1 so its main() does not run, then
#    compare each profile's space-joined list against the .list file's lines.
# ---------------------------------------------------------------------------
check_lists() {
	# shellcheck disable=SC1090
	VELO_SOURCED=1 . "$SRC"
	_cl_fail=0
	for _p in minimal desktop fortress; do
		_expected=$(profile_pkgs "$_p") || { echo "self-check: profile_pkgs $_p failed" >&2; _cl_fail=1; continue; }
		_listf="$SITE/usr/obj/_pkgs/${_p}.list"
		[ -f "$_listf" ] || { echo "self-check: missing $_listf" >&2; _cl_fail=1; continue; }
		# join the .list lines with single spaces (skip blank/comment lines)
		_got=$(list_join "$_listf")
		# trim the single trailing space
		_got=${_got% }
		if [ "$_got" = "$_expected" ]; then
			echo "self-check OK: ${_p}.list == profile_pkgs($_p)" >&2
		else
			echo "self-check FAIL: ${_p}.list != profile_pkgs($_p)" >&2
			echo "  expected: [$_expected]" >&2
			echo "  got:      [$_got]" >&2
			_cl_fail=1
		fi
	done
	return $_cl_fail
}

# Run the self-check in a SUBSHELL so sourcing velo-install cannot pollute this
# script's environment / functions.
if ! ( check_lists ); then
	die "profile-list self-check failed -- site/usr/obj/_pkgs/*.list out of sync with src/velo-install"
fi

# ---------------------------------------------------------------------------
# 2. Stage a clean copy of site/ so we can set ownership/modes without touching
#    the repo working tree, and exclude .keep-empty/.gitkeep.
# ---------------------------------------------------------------------------
mkdir -p "$DIST"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/velo-site.XXXXXX") || die "mktemp failed"
# Clean staging on exit (any path).
trap 'rm -rf "$STAGE"' EXIT INT TERM

# Copy the tree (preserve symlinks if any; there are none expected).
cp -R "$SITE/." "$STAGE/"

# Drop placeholder/keep files that must NOT ship in the tarball.
find "$STAGE" \( -name '.keep-empty' -o -name '.gitkeep' \) -type f -exec rm -f {} +

# ---------------------------------------------------------------------------
# 3. Normalise ownership + modes in the staging copy.
#    chown to 0:0 here; tar then records --owner/--group=0 as root:wheel.
# ---------------------------------------------------------------------------
# Directories 0755.
find "$STAGE" -type d -exec chmod 0755 {} +

# Default every regular file to 0644 first, then tighten the specific ones.
find "$STAGE" -type f -exec chmod 0644 {} +

# Executables / scripts -> 0755.
chmod 0755 "$STAGE/install.site.velo"
[ -f "$STAGE/etc/X11/xenodm/Xsetup_0" ] && chmod 0755 "$STAGE/etc/X11/xenodm/Xsetup_0"

# Secrets / pf rules / doas -> 0600.
[ -f "$STAGE/etc/doas.conf" ] && chmod 0600 "$STAGE/etc/doas.conf"
[ -f "$STAGE/etc/velo/answers" ] && chmod 0600 "$STAGE/etc/velo/answers"
for _pf in "$STAGE"/etc/velo/pf/*.conf; do
	[ -f "$_pf" ] && chmod 0600 "$_pf"
done
# hostname.iwm0 carries the plaintext WPA key -> root-only readable (0640 root:wheel).
[ -f "$STAGE/etc/hostname.iwm0" ] && chmod 0640 "$STAGE/etc/hostname.iwm0"

# ---------------------------------------------------------------------------
# 4. Build a SORTED member list (deterministic order), paths relative to STAGE
#    so the tarball is rooted at '/' once we tell tar the names are absolute-ish.
#    We feed tar the relative member names from inside STAGE; member paths then
#    look like `install.site`, `etc/doas.conf`, ... which extract under the
#    target root exactly like the stock OpenBSD sets (tar -xzphf rooted at /).
# ---------------------------------------------------------------------------
# Build the SORTED member list (files + dirs), EXCLUDING the .members file
# itself and any stray placeholder.  Write it OUTSIDE the staged tree so it can
# never end up packed.
MEMBERS="$DIST/.site-members.$$"
( cd "$STAGE" && find . -mindepth 1 \( -type f -o -type d \) \
	| sed 's|^\./||' \
	| grep -v -x '.members' \
	| LC_ALL=C sort ) >"$MEMBERS"

# ---------------------------------------------------------------------------
# 5. Pack.  Prefer GNU tar's reproducibility flags; fall back to a portable
#    invocation if they are unavailable (e.g. bsdtar).  Detect GNU tar by its
#    --version banner.
#
#    --no-recursion is REQUIRED: the member list already names every dir AND
#    file explicitly; without it, tar would ALSO recurse into each listed
#    directory, duplicating every entry.  All options go BEFORE -T (positional).
# ---------------------------------------------------------------------------
# Resolve a fixed mtime (reproducible). SOURCE_DATE_EPOCH wins if set.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
	_mtime="@$SOURCE_DATE_EPOCH"
else
	_mtime="$FIXED_DATE"
fi

if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
	# GNU tar: deterministic owner/mtime/sort, no recursion (explicit members).
	( cd "$STAGE" && tar \
		--owner=0 --group=0 --numeric-owner \
		--mtime="$_mtime" \
		--sort=name \
		--no-recursion \
		--format=ustar \
		-c -f - -T "$MEMBERS" ) | gzip -9 -n >"$OUT"
else
	# Portable fallback (bsdtar/libarchive): explicit members, no recursion.
	( cd "$STAGE" && tar -c -n -f - \
		--uid 0 --gid 0 \
		-T "$MEMBERS" ) 2>/dev/null | gzip -9 -n >"$OUT" \
	|| ( cd "$STAGE" && tar -c -f - -I "$MEMBERS" ) | gzip -9 -n >"$OUT"
fi

rm -f "$MEMBERS"
[ -s "$OUT" ] || die "tar produced an empty $OUT"

# ---------------------------------------------------------------------------
# 6. Emit a review manifest (path, mode, size) from the staged tree.
# ---------------------------------------------------------------------------
{
	echo "# velo site79.tgz manifest -- generated $(date 2>/dev/null || echo '?')"
	echo "# mode  size  path"
	( cd "$STAGE" && find . -mindepth 1 \( -type f -o -type d \) \
		| sed 's|^\./||' | LC_ALL=C sort \
		| while IFS= read -r _m; do
			[ "$_m" = ".members" ] && continue
			_mode=$(stat -c '%a' "$_m" 2>/dev/null || echo '???')
			_size=$(stat -c '%s' "$_m" 2>/dev/null || echo '?')
			printf '%-5s %8s  /%s\n' "$_mode" "$_size" "$_m"
		done )
} >"$MANIFEST"

# ---------------------------------------------------------------------------
# 7. Report: sha256 (if available) + the authoritative `tar tzf` listing.
# ---------------------------------------------------------------------------
echo "make-site-tgz: wrote $OUT"
if command -v sha256sum >/dev/null 2>&1; then
	sha256sum "$OUT"
elif command -v sha256 >/dev/null 2>&1; then
	sha256 "$OUT"
fi
echo "make-site-tgz: manifest -> $MANIFEST"
echo "--- tar tzf $OUT ---"
tar tzf "$OUT"

exit 0
