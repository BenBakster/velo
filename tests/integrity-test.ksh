#!/bin/ksh
# integrity-test.ksh -- HOST-runnable tests for build/lib-integrity.sh.
#
# Runs under OpenBSD /bin/ksh (oksh) AND bash >= 3 on the Void host.  It SOURCES
# build/lib-integrity.sh and exercises the sha256 sidecar helpers end-to-end
# (the Void host has sha256sum; an OpenBSD VM has sha256 -- the helper auto-picks).
# The signify helper is VM-only by nature, so here we test only its FAIL-CLOSED
# behaviour when its preconditions are absent (no spawning of signify).
#
# Usage:   /usr/sbin/ksh tests/integrity-test.ksh
#          bash          tests/integrity-test.ksh
# Exit:    0 = all pass, 1 = a failure.

case "$0" in
*/*) _T_HERE=${0%/*} ;;
*)   _T_HERE=. ;;
esac

# shellcheck source=build/lib-integrity.sh
. "$_T_HERE/../build/lib-integrity.sh"

T_FAIL=0
T_N=0
t_eq() {  # t_eq LABEL EXPECTED ACTUAL
	T_N=$((T_N + 1))
	if [ "$2" = "$3" ]; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		echo "       expected: [$2]"
		echo "       actual:   [$3]"
		T_FAIL=$((T_FAIL + 1))
	fi
}
t_rc() {  # t_rc LABEL EXPECTED_RC ACTUAL_RC
	T_N=$((T_N + 1))
	if [ "$2" = "$3" ]; then
		echo "ok   $1"
	else
		echo "FAIL $1 (rc expected $2 got $3)"
		T_FAIL=$((T_FAIL + 1))
	fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/velo-integ.XXXXXX") || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

# A known input with a known SHA-256.  "velo\n" -> sha256 is stable; but rather
# than hardcode a digest (and couple to a tool's newline handling), we assert the
# helpers are SELF-CONSISTENT (emit then verify) and that tampering is caught.
printf 'velo integrity test payload\n' > "$WORK/img.bin"
printf 'velo integrity test payload\n' > "$WORK/img2.bin"   # identical content
printf 'a DIFFERENT payload\n'          > "$WORK/other.bin"

# --- vi_sha256_hex: 64 lowercase hex, deterministic, content-sensitive --------
H1=$(vi_sha256_hex "$WORK/img.bin")
t_rc  "sha256_hex returns 0 on a real file" 0 $?
t_eq  "sha256_hex is 64 chars"              64 "${#H1}"
case "$H1" in
*[!0-9a-f]*) t_eq "sha256_hex is lowercase hex" "clean" "DIRTY:[$H1]" ;;
*)           t_eq "sha256_hex is lowercase hex" "clean" "clean" ;;
esac
H1b=$(vi_sha256_hex "$WORK/img.bin")
t_eq  "sha256_hex is deterministic"             "$H1" "$H1b"
H2=$(vi_sha256_hex "$WORK/img2.bin")
t_eq  "sha256_hex equal for equal content"      "$H1" "$H2"
HO=$(vi_sha256_hex "$WORK/other.bin")
if [ "$H1" != "$HO" ]; then t_eq "sha256_hex differs for differing content" "diff" "diff"
else                        t_eq "sha256_hex differs for differing content" "diff" "SAME"; fi
vi_sha256_hex "$WORK/does-not-exist" >/dev/null 2>&1
t_rc  "sha256_hex fails closed on missing file" 1 $?

# --- vi_is_hex64 --------------------------------------------------------------
vi_is_hex64 "$H1";                                            t_rc "is_hex64 accepts a real digest"     0 $?
vi_is_hex64 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; t_rc "is_hex64 accepts 64 hex" 0 $?
vi_is_hex64 "tooshort";                                       t_rc "is_hex64 rejects short"             1 $?
vi_is_hex64 "ZZZ456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; t_rc "is_hex64 rejects non-hex" 1 $?
vi_is_hex64 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0"; t_rc "is_hex64 rejects 65 chars" 1 $?

# --- _vi_lc -------------------------------------------------------------------
t_eq "lc lowercases ABCDEF" "abcdef" "$(_vi_lc ABCDEF)"
t_eq "lc leaves digits/lc"  "a1b2f0" "$(_vi_lc a1B2F0)"

# --- sidecar emit -> verify roundtrip ----------------------------------------
SIDE=$(vi_sidecar_emit "$WORK/img.bin")
t_rc  "sidecar_emit returns 0"            0 $?
t_eq  "sidecar_emit echoes the path"      "$WORK/img.bin.sha256" "$SIDE"
t_eq  "sidecar file exists"               "yes" "$([ -f "$WORK/img.bin.sha256" ] && echo yes || echo no)"
# sidecar content = "<hex>  <basename>"
read -r _shex _sbase < "$WORK/img.bin.sha256"
t_eq  "sidecar stores the right digest"   "$H1" "$_shex"
t_eq  "sidecar stores the basename only"  "img.bin" "$_sbase"
vi_sidecar_verify "$WORK/img.bin"
t_rc  "sidecar_verify accepts untampered" 0 $?

# --- tamper detection ---------------------------------------------------------
printf 'tampered!\n' >> "$WORK/img.bin"          # mutate the image, keep old sidecar
vi_sidecar_verify "$WORK/img.bin" 2>/dev/null
t_rc  "sidecar_verify catches a tampered image" 1 $?

# --- uppercase sidecar still verifies (case-insensitive) ----------------------
printf 'case payload\n' > "$WORK/up.bin"
UPHEX=$(vi_sha256_hex "$WORK/up.bin")
# write an UPPERCASE digest sidecar by hand
_UP=$(printf '%s' "$UPHEX" | tr 'a-f' 'A-F' 2>/dev/null || printf '%s' "$UPHEX")
# Guard against a vacuous test: if tr were absent (or the digest had no a-f
# letters) _UP would equal the lowercase hex and the check below would degrade to
# a plain lowercase roundtrip -- assert the stored value is GENUINELY uppercased.
if [ "$_UP" != "$UPHEX" ]; then t_eq "uppercase sidecar is actually uppercased" "upper" "upper"
else                            t_eq "uppercase sidecar is actually uppercased" "upper" "NOT-UPPER (tr absent / no a-f in digest)"; fi
printf '%s  up.bin\n' "$_UP" > "$WORK/up.bin.sha256"
vi_sidecar_verify "$WORK/up.bin"
t_rc  "sidecar_verify is case-insensitive on stored hex" 0 $?

# --- fail-closed: missing sidecar --------------------------------------------
printf 'no sidecar here\n' > "$WORK/bare.bin"
vi_sidecar_verify "$WORK/bare.bin" 2>/dev/null
t_rc  "sidecar_verify fails closed when sidecar absent" 1 $?

# --- fail-closed: malformed sidecar (no hex) ----------------------------------
printf 'this is not a digest line\n' > "$WORK/mal.bin.sha256"
printf 'x\n' > "$WORK/mal.bin"
vi_sidecar_verify "$WORK/mal.bin" 2>/dev/null
t_rc  "sidecar_verify fails closed on malformed sidecar" 1 $?

# --- signify helper FAIL-CLOSED preconditions (no signify spawn) --------------
# missing pubkey -> 1 (and if signify itself is absent on this host, also 1).
vi_signify_release "$WORK/nope.pub" "$WORK/nope.sig" "$WORK/img2.bin" 2>/dev/null
t_rc  "signify_release fails closed on missing pubkey/sig" 1 $?
# no files named -> 1 (only reachable when signify+keys exist; on hosts without
# signify the earlier command-v gate already returns 1 -- either way: fail closed).
vi_signify_release "$WORK/nope.pub" "$WORK/nope.sig" 2>/dev/null
t_rc  "signify_release fails closed with no files"        1 $?

# --- summary ------------------------------------------------------------------
echo ""
if [ "$T_FAIL" -eq 0 ]; then
	echo "PASS: all $T_N assertions passed."
	exit 0
else
	echo "FAIL: $T_FAIL of $T_N assertions failed."
	exit 1
fi
