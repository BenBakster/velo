#!/bin/sh
# tests/check-pkg-closure-test.sh -- unit tests for build/check-pkg-closure.sh
#
# Builds synthetic package archives (valid .tgz with +CONTENTS) in a tmpdir
# and asserts expected exit codes.  Runs on Linux (tar + gzip available).
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$REPO/build/check-pkg-closure.sh"

pass=0; fail=0
t_eq() {
    _label=$1; _exp=$2; _got=$3
    if [ "$_exp" = "$_got" ]; then
        printf 'ok   %s\n' "$_label"
        pass=$((pass + 1))
    else
        printf 'FAIL %s (expected=%s got=%s)\n' "$_label" "$_exp" "$_got"
        fail=$((fail + 1))
    fi
}

# ---- helpers ---------------------------------------------------------------

make_pkg() {
    # make_pkg DIR NAME VERSION [dep_default_pkgname...]
    # Creates DIR/NAME-VERSION.tgz with a +CONTENTS declaring the given deps.
    _dir=$1 _name=$2 _ver=$3; shift 3
    _tmp=$(mktemp -d)
    _full="${_name}-${_ver}"
    {   printf '@name %s\n' "$_full"
        for _dep; do
            printf '@depend fakepath:constraint:' ; printf '%s\n' "$_dep"
        done
    } >"$_tmp/+CONTENTS"
    tar -czf "$_dir/${_full}.tgz" -C "$_tmp" +CONTENTS
    rm -rf "$_tmp"
}

# ---- setup -----------------------------------------------------------------

PKGS=$(mktemp -d)
trap 'rm -rf "$PKGS"' EXIT INT TERM

# ---- T1: single package, no deps -> PASS -----------------------------------
SINGLE=$(mktemp -d); trap 'rm -rf "$SINGLE"' EXIT INT TERM
make_pkg "$SINGLE" foo 1.0
"$CHECK" "$SINGLE" >/dev/null 2>&1; t_eq "T1: no deps -> exit 0" 0 $?

# ---- T2: package declares dep present in dir -> PASS -----------------------
make_pkg "$PKGS" pkgA 1.0 pkgB-2.0   # A depends on B
make_pkg "$PKGS" pkgB 2.0
"$CHECK" "$PKGS" >/dev/null 2>&1; t_eq "T2: dep present -> exit 0" 0 $?

# ---- T3: package declares dep MISSING from dir -> FAIL ---------------------
MISS=$(mktemp -d); trap 'rm -rf "$MISS"' EXIT INT TERM
make_pkg "$MISS" pkgA 1.0 pkgB-2.0   # A depends on B, but B is not in MISS
out=$("$CHECK" "$MISS" 2>&1 || true)
"$CHECK" "$MISS" >/dev/null 2>&1 && _rc=0 || _rc=$?
t_eq "T3: dep missing -> exit 1" 1 $_rc
printf '%s\n' "$out" | grep -q "stem pkgB" 2>/dev/null && \
    t_eq "T3: missing dep reported in output" ok ok || \
    t_eq "T3: missing dep reported in output" ok MISS

# ---- T4: wildcard-constraint @depend (second field *) -> PASS --------------
# Real example: bash depends on gettext-runtime-*:gettext-runtime-1.0
WILD=$(mktemp -d); trap 'rm -rf "$WILD"' EXIT INT TERM
# make a package whose +CONTENTS has a raw @depend with wildcard in field 2
_tmp=$(mktemp -d)
printf '@name alpha-1.0\n@depend shells/beta:beta-*:beta-3.2\n' >"$_tmp/+CONTENTS"
tar -czf "$WILD/alpha-1.0.tgz" -C "$_tmp" +CONTENTS
make_pkg "$WILD" beta 3.2
rm -rf "$_tmp"
"$CHECK" "$WILD" >/dev/null 2>&1; t_eq "T4: wildcard constraint -> exit 0" 0 $?

# ---- T5: correct STEM but wrong exact version present (stem-only PASS) -----
# This is the documented limitation: stem-based check cannot detect version mismatches.
# Package A needs python-3.13.3 (default) but we only have python-3.10.12.
# stem for both is "python" -> stem check PASSES, real pkg_add would FAIL.
STEM=$(mktemp -d); trap 'rm -rf "$STEM"' EXIT INT TERM
_tmp=$(mktemp -d)
printf '@name appA-1.0\n@depend lang/python3:python->=3.13,<3.14:python-3.13.3\n' \
    >"$_tmp/+CONTENTS"
tar -czf "$STEM/appA-1.0.tgz" -C "$_tmp" +CONTENTS
# Provide python-3.10.12 instead of 3.13.3
make_pkg "$STEM" python 3.10.12
rm -rf "$_tmp"
"$CHECK" "$STEM" >/dev/null 2>&1; _rc5=$?
t_eq "T5: stem-only check passes wrong version (documented limit)" 0 $_rc5
# --exact should WARN/FAIL because python-3.13.3 is not present
"$CHECK" "$STEM" --exact >/dev/null 2>&1 && _rc5e=0 || _rc5e=$?
t_eq "T5: --exact detects missing default-pkgname -> exit 1" 1 $_rc5e

# ---- T6: no .tgz files -> FAIL ---------------------------------------------
EMPTY=$(mktemp -d); trap 'rm -rf "$EMPTY"' EXIT INT TERM
"$CHECK" "$EMPTY" >/dev/null 2>&1 && _rc6=0 || _rc6=$?
t_eq "T6: empty dir -> exit 1" 1 $_rc6

# ---- T7: usage: no args -> exit 2 -----------------------------------------
"$CHECK" >/dev/null 2>&1 && _rc7=0 || _rc7=$?
t_eq "T7: no-arg usage -> exit 2" 2 $_rc7

# ---- T8: transitive chain (A->B->C all present) -> PASS --------------------
CHAIN=$(mktemp -d); trap 'rm -rf "$CHAIN"' EXIT INT TERM
make_pkg "$CHAIN" pkgA 1.0 pkgB-2.0
make_pkg "$CHAIN" pkgB 2.0 pkgC-3.0
make_pkg "$CHAIN" pkgC 3.0
"$CHECK" "$CHAIN" >/dev/null 2>&1; t_eq "T8: transitive chain -> exit 0" 0 $?

# ---- T9: transitive chain with broken link (C missing) -> FAIL -------------
BROKEN=$(mktemp -d); trap 'rm -rf "$BROKEN"' EXIT INT TERM
make_pkg "$BROKEN" pkgA 1.0 pkgB-2.0
make_pkg "$BROKEN" pkgB 2.0 pkgC-3.0   # C is declared but absent
"$CHECK" "$BROKEN" >/dev/null 2>&1 && _rc9=0 || _rc9=$?
t_eq "T9: broken transitive chain -> exit 1" 1 $_rc9

# ---- T10: compound/flavored stem derivation (py3-gobject3-3.46.0p0) ---------
# The trickiest path: the stem regex must strip the trailing -VERSION INCLUDING
# the pNN flavor (-3.46.0p0) while KEEPING the multi-hyphen base, i.e.
# py3-gobject3-3.46.0p0 -> py3-gobject3 (not py3, not py3-gobject3-3).  Provider
# present at the exact flavored version, so BOTH stem and --exact must pass.
FLAV=$(mktemp -d); trap 'rm -rf "$FLAV"' EXIT INT TERM
_tmp=$(mktemp -d)
printf '@name appB-1.0\n@depend x11/py3-gobject3:py3-gobject3-*:py3-gobject3-3.46.0p0\n' >"$_tmp/+CONTENTS"
tar -czf "$FLAV/appB-1.0.tgz" -C "$_tmp" +CONTENTS
rm -rf "$_tmp"
make_pkg "$FLAV" py3-gobject3 3.46.0p0
"$CHECK" "$FLAV" >/dev/null 2>&1; t_eq "T10: compound/flavored stem resolves -> exit 0" 0 $?
"$CHECK" "$FLAV" --exact >/dev/null 2>&1; t_eq "T10: --exact matches flavored default -> exit 0" 0 $?

# ---- T11: +CONTENTS with no @name -> fail-closed exit 1 --------------------
NONAME=$(mktemp -d); trap 'rm -rf "$NONAME"' EXIT INT TERM
_tmp=$(mktemp -d)
printf '@comment no name record here\n@depend p:c:dep-1.0\n' >"$_tmp/+CONTENTS"
tar -czf "$NONAME/bogus-1.0.tgz" -C "$_tmp" +CONTENTS
rm -rf "$_tmp"
"$CHECK" "$NONAME" >/dev/null 2>&1 && _rc11=0 || _rc11=$?
t_eq "T11: +CONTENTS without @name -> exit 1" 1 $_rc11

# ---- T12: @name with no derivable stem (no -VERSION) -> exit 1 -------------
NOSTEM=$(mktemp -d); trap 'rm -rf "$NOSTEM"' EXIT INT TERM
_tmp=$(mktemp -d)
printf '@name nameless\n' >"$_tmp/+CONTENTS"
tar -czf "$NOSTEM/nameless.tgz" -C "$_tmp" +CONTENTS
rm -rf "$_tmp"
"$CHECK" "$NOSTEM" >/dev/null 2>&1 && _rc12=0 || _rc12=$?
t_eq "T12: @name without version (no stem) -> exit 1" 1 $_rc12

# ---- T13: malformed @depend (empty third field) -> exit 1 -----------------
BADDEP=$(mktemp -d); trap 'rm -rf "$BADDEP"' EXIT INT TERM
_tmp=$(mktemp -d)
printf '@name appC-1.0\n@depend pkgpath:constraint:\n' >"$_tmp/+CONTENTS"
tar -czf "$BADDEP/appC-1.0.tgz" -C "$_tmp" +CONTENTS
rm -rf "$_tmp"
"$CHECK" "$BADDEP" >/dev/null 2>&1 && _rc13=0 || _rc13=$?
t_eq "T13: malformed @depend (empty 3rd field) -> exit 1" 1 $_rc13

# ---- summary ---------------------------------------------------------------
echo ""
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'PASS: all %d assertions passed.\n' "$total"
else
    printf 'FAIL: %d/%d assertions failed.\n' "$fail" "$total"
    exit 1
fi
