# build/lib-integrity.sh -- shared build-chain INTEGRITY helpers.
#
# SOURCED, never executed:  . "$_HERE/lib-integrity.sh"
#
# ============================================================================
#  WHY
#  --------------------------------------------------------------------------
#  velo's build chain pulls in OpenBSD-signed inputs (firmware over plain HTTP)
#  and emits a raw disk image (velo79.img) that a guarded writer later dd's onto
#  a real device.  Two integrity boundaries were missing and are filled here:
#
#    1. INPUT provenance (signify).  An OpenBSD download must be verified against
#       its release signify pubkey BEFORE it is trusted -- TLS is NOT the
#       boundary (firmware.openbsd.org is fetched over http, on purpose, due to a
#       TLS altname mismatch; signify is what makes the blob trustworthy).
#       signify(1) is OpenBSD-only, so these checks run in the build VM and FAIL
#       CLOSED anywhere signify is absent.
#
#    2. OUTPUT provenance (sha256 sidecar).  The image producers
#       (assemble-media / grow-media) drop a `<image>.sha256` sidecar; the
#       writers (write-usb / flash-sda-guarded) verify the image against it
#       BEFORE dd, so a corrupted or wrong-image flash is caught pre-write.  The
#       sidecar format is the coreutils `sha256sum` line ("<64hex>  <basename>")
#       so it is tool-agnostic: producible/checkable on OpenBSD (sha256) AND on
#       the Linux host (sha256sum), and even consumable by `sha256sum -c`.
#
#  Parse-clean under sh -n, ksh -n, bash -n.  The sha256 helpers are HOST-runnable
#  (Void has sha256sum) and are exercised by tests/integrity-test.ksh; the signify
#  helper is VM-only by nature.
# ============================================================================

# vi_warn MSG -- diagnostics to stderr.  No `exit`: a sourcing script keeps control
# and decides whether a non-zero return is fatal.
vi_warn() { echo "lib-integrity: $*" >&2; }

# vi_sha256_hex FILE -- print FILE's lowercase 64-hex SHA-256 digest on stdout
# (no trailing newline).  rc 1 + no output if FILE is unreadable or no tool
# exists.  Tool-agnostic: OpenBSD `sha256 -q`, else coreutils `sha256sum`.
vi_sha256_hex() {
	_vi_f=$1
	[ -f "$_vi_f" ] || { vi_warn "sha256: not a regular file: $_vi_f"; return 1; }
	if command -v sha256 >/dev/null 2>&1; then
		# OpenBSD sha256 -q: prints just the lowercase hex digest.
		sha256 -q "$_vi_f" 2>/dev/null | { read -r _vi_h _vi_rest; printf '%s' "$_vi_h"; }
	elif command -v sha256sum >/dev/null 2>&1; then
		# coreutils: "<hex>  <name>"; keep the first field only.
		sha256sum "$_vi_f" 2>/dev/null | { read -r _vi_h _vi_rest; printf '%s' "$_vi_h"; }
	else
		vi_warn "sha256: neither sha256(OpenBSD) nor sha256sum(Linux) is available"
		return 1
	fi
}

# vi_is_hex64 STR -- rc 0 iff STR is exactly 64 hex chars (a SHA-256 digest).
vi_is_hex64() {
	case "$1" in
	*[!0-9A-Fa-f]*) return 1 ;;
	esac
	[ ${#1} -eq 64 ]
}

# vi_sidecar_emit FILE -- write FILE.sha256 = "<hex>  <basename>\n" (mode 0644).
# Echoes the sidecar path on success; rc 1 on any failure (callers fail closed).
vi_sidecar_emit() {
	_vi_f=$1
	_vi_hex=$(vi_sha256_hex "$_vi_f") || return 1
	vi_is_hex64 "$_vi_hex" || { vi_warn "sidecar: refusing to emit -- bad digest for $_vi_f"; return 1; }
	_vi_base=${_vi_f##*/}
	_vi_side="$_vi_f.sha256"
	if ( umask 022; printf '%s  %s\n' "$_vi_hex" "$_vi_base" > "$_vi_side" ); then
		printf '%s' "$_vi_side"
		return 0
	fi
	vi_warn "sidecar: could not write $_vi_side"
	return 1
}

# vi_sidecar_verify FILE -- recompute FILE's digest and compare it to the hex
# stored in FILE.sha256.  rc 0 match; rc 1 on mismatch / missing sidecar /
# missing tool / malformed sidecar (FAIL CLOSED -- the writers treat rc!=0 as
# "do not flash").
vi_sidecar_verify() {
	_vi_f=$1
	_vi_side="$_vi_f.sha256"
	[ -f "$_vi_side" ] || { vi_warn "verify: no sidecar $_vi_side"; return 1; }
	# First whitespace field = expected hex (sha256sum line format).
	read -r _vi_exp _vi_rest < "$_vi_side" || { vi_warn "verify: unreadable sidecar $_vi_side"; return 1; }
	vi_is_hex64 "$_vi_exp" || { vi_warn "verify: sidecar $_vi_side has no 64-hex digest"; return 1; }
	_vi_got=$(vi_sha256_hex "$_vi_f") || return 1
	# Case-insensitive compare: sha256/sha256sum emit lowercase, but a sidecar may
	# have been hand-edited to uppercase -- lowercase the stored value first
	# (_vi_lc avoids spawning tr, which is absent from the install ramdisk).
	if [ "$_vi_got" = "$(_vi_lc "$_vi_exp")" ]; then
		return 0
	fi
	vi_warn "verify: DIGEST MISMATCH for $_vi_f"
	vi_warn "verify:   expected $_vi_exp"
	vi_warn "verify:   got      $_vi_got"
	return 1
}

# _vi_lc STR -- lowercase a short ASCII string without tr (POSIX parameter ops
# are not enough; use a small case loop).  Used only for the hex compare.
_vi_lc() {
	_vi_in=$1
	_vi_out=""
	while [ -n "$_vi_in" ]; do
		_vi_c=${_vi_in%"${_vi_in#?}"}     # first char
		_vi_in=${_vi_in#?}
		case "$_vi_c" in
		A) _vi_c=a ;; B) _vi_c=b ;; C) _vi_c=c ;; D) _vi_c=d ;; E) _vi_c=e ;; F) _vi_c=f ;;
		esac
		_vi_out="$_vi_out$_vi_c"
	done
	printf '%s' "$_vi_out"
}

# vi_signify_release PUBKEY SIGFILE FILE... -- verify an OpenBSD-signed SHA256.sig
# (PUBKEY signs SIGFILE, which lists each file's SHA-256) AND that the named
# FILEs match.  Run from the directory holding SIGFILE + the FILEs.  OpenBSD-only;
# FAIL CLOSED if signify is absent (callers invoke this only in the build VM).
#   vi_signify_release /etc/signify/openbsd-79-fw.pub SHA256.sig iwm-firmware-NN.tgz
vi_signify_release() {
	_vi_pub=$1; _vi_sig=$2
	shift 2
	command -v signify >/dev/null 2>&1 || {
		vi_warn "signify not found -- this verification must run on OpenBSD (the build VM). FAIL CLOSED."
		return 1
	}
	[ -f "$_vi_pub" ] || { vi_warn "signify: pubkey not found: $_vi_pub"; return 1; }
	[ -f "$_vi_sig" ] || { vi_warn "signify: signature not found: $_vi_sig"; return 1; }
	[ "$#" -ge 1 ]    || { vi_warn "signify: no files to verify"; return 1; }
	# signify -C: verify SIGFILE's own signature with PUBKEY, then check the listed
	# files' digests.  Naming FILEs restricts the check to exactly what we ship.
	signify -C -p "$_vi_pub" -x "$_vi_sig" "$@"
}
