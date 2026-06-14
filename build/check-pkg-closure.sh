#!/bin/sh
# build/check-pkg-closure.sh DIR [--exact]
#
# Verify that an offline OpenBSD package directory contains every transitive
# dependency declared in every archive's +CONTENTS file.
#
# @depend format: pkgpath:constraint:default-pkgname
#   - field 1 (pkgpath)          e.g. devel/gettext,-runtime
#   - field 2 (constraint)       e.g. gettext-runtime-*  OR  python->=3.13,<3.14
#   - field 3 (default-pkgname)  e.g. gettext-runtime-1.0   (exact installed name)
#
# This script performs a STEM check: for every @depend line, it extracts
# the stem of the DEFAULT-PKGNAME (third field) and verifies that at least
# one archive in DIR matches that stem.  Version constraints in the second
# field are NOT evaluated on the Linux host; a clean-VM pkg_add -n run is
# needed for full constraint satisfaction proof.
#
# With --exact: also check that the exact default-pkgname appears in DIR
# (still does not verify the constraint range against the actual archive).
#
# Exit codes: 0 = all required stems present; 1 = at least one missing; 2 = usage/setup error.

set -eu

DIR=${1:-}
EXACT=0
case "${2:-}" in --exact) EXACT=1 ;; esac

[ -n "$DIR" ] && [ -d "$DIR" ] || {
	echo "usage: $0 DIR [--exact]" >&2
	exit 2
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/velo-pkgcheck.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
NAMES="$TMP/names"           # one stem per line, from @name of every archive
EXACT_NAMES="$TMP/exact"     # one exact versioned name per line
DEPS="$TMP/deps"             # source_pkgname|depstem|dep_default_pkgname
META="$TMP/contents"
: >"$NAMES"
: >"$EXACT_NAMES"
: >"$DEPS"

fail=0
count=0

for pkg in "$DIR"/*.tgz; do
	[ -e "$pkg" ] || {
		echo "pkg-closure FAIL: no .tgz package archives in $DIR" >&2
		exit 1
	}
	count=$((count + 1))

	if ! tar -xOf "$pkg" +CONTENTS >"$META" 2>/dev/null; then
		echo "pkg-closure FAIL: cannot read +CONTENTS from $(basename "$pkg")" >&2
		fail=1; continue
	fi

	# Extract @name (exactly one record required)
	name=$(sed -n 's/^@name //p' "$META")
	case "$name" in
	""|*'
'*)
		echo "pkg-closure FAIL: $(basename "$pkg") has zero or multiple @name records" >&2
		fail=1; continue
		;;
	esac

	# Derive stem: strip trailing -DIGIT and everything after it.
	# Handles: glib2-2.78.4 -> glib2; py3-gobject3-3.46.0p0 -> py3-gobject3
	stem=$(printf '%s\n' "$name" | sed 's/-[0-9].*$//')
	[ "$stem" != "$name" ] || {
		echo "pkg-closure FAIL: cannot derive stem from @name '$name' in $(basename "$pkg")" >&2
		fail=1; continue
	}
	printf '%s\n' "$stem" >>"$NAMES"
	printf '%s\n' "$name" >>"$EXACT_NAMES"

	# Parse @depend lines.  Format: pkgpath:constraint:default-pkgname
	# We use the third field (default-pkgname) as the dependency name.
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		# Remove leading "@depend "
		spec=${line#@depend }

		# Third colon-delimited field is the default-pkgname.
		# Split manually to handle pkgpaths that may contain colons.
		field3=${spec##*:}
		[ -n "$field3" ] || {
			echo "pkg-closure FAIL: malformed @depend (no third field) in $name: $line" >&2
			fail=1; continue
		}

		# Constraint operators (<, >, =, *) in the SECOND field are intentionally
		# ignored here; we resolve against the third (default-pkgname) field only.
		depstem=$(printf '%s\n' "$field3" | sed 's/-[0-9].*$//')
		[ "$depstem" != "$field3" ] || {
			echo "pkg-closure FAIL: cannot derive stem from dep '$field3' in $name: $line" >&2
			fail=1; continue
		}

		printf '%s|%s|%s\n' "$name" "$depstem" "$field3" >>"$DEPS"
	done <<EOF
$(sed -n '/^@depend /p' "$META")
EOF
done

sort -u "$NAMES"       >"$NAMES.sorted"
sort -u "$EXACT_NAMES" >"$EXACT_NAMES.sorted"

# ---- stem check ----
stem_fail=0
while IFS='|' read -r source depstem dep; do
	[ -n "$source" ] || continue
	if ! grep -qxF -- "$depstem" "$NAMES.sorted"; then
		echo "pkg-closure FAIL: $source needs $dep (stem $depstem) -- no matching archive in $DIR" >&2
		stem_fail=1; fail=1
	fi
done <"$DEPS"

# ---- exact default-pkgname check (--exact only) ----
exact_fail=0
if [ "$EXACT" = 1 ]; then
	while IFS='|' read -r source depstem dep; do
		[ -n "$source" ] || continue
		if ! grep -qxF -- "$dep" "$EXACT_NAMES.sorted"; then
			echo "pkg-closure WARN: $source needs default '$dep' -- exact archive absent (wrong version?)" >&2
			exact_fail=1
		fi
	done <"$DEPS"
fi

[ "$fail" -eq 0 ] || exit 1

if [ "$EXACT" = 1 ] && [ "$exact_fail" -ne 0 ]; then
	echo "pkg-closure WARN: $count archives; stems OK but some exact default-pkgnames absent (--exact)" >&2
	echo "pkg-closure NOTE: run pkg_add -n on a clean OpenBSD 7.9 VM for full constraint verification." >&2
	exit 1
fi

echo "pkg-closure OK: $count archives; every @depend stem present (stem-only check)."
echo "pkg-closure NOTE: version/flavor constraints require a clean OpenBSD 7.9 pkg_add -n run to verify."
