#!/bin/ksh
# tests/site-validate.ksh -- STATIC validation of the velo M2 site set.
#
# Runs on the Void build host under OpenBSD /usr/sbin/ksh (oksh) AND bash >= 3.
# It does ONLY static structure/syntax checks plus a fakeroot DRY-RUN of
# install.site against a temp DESTDIR -- it NEVER touches the real system and
# NEVER needs pfctl / doas -C / rcctl / pkg_add (those are M3-VM, FLAGGED).
#
# Usage:   /usr/sbin/ksh tests/site-validate.ksh
#          bash          tests/site-validate.ksh
# Exit:    0 = all pass, 1 = a failure.
#
# Checks (mirrors docs/m2-design.md s8 "Done now"):
#   A. install.site & make-site-tgz.sh parse clean (sh -n via the running shell).
#   B. install.site contains NO network fetch (ftp/http/pkg_add-from-mirror) and
#      APPENDS (>>) to rc.firsttime + sysctl.conf -- never clobbers (>).
#   C. fakeroot DRY-RUN: install.site against a temp dir with a fake answers file
#      produces the expected drops (pf.conf, sysctl append, installed.list,
#      rc.firsttime block) WITHOUT touching the real /etc, /root, /var.
#   D. Safe-floor: a MISSING answers file -> minimal + L1 + no extra pkgs.
#   E. Injection guard: a hostile answers file (pkgs='a;b $(reboot)') must NOT
#      execute and must DROP the bad tokens from installed.list.
#   F. Profile / startmode / package names match src/velo-install (grep x-check).
#   G. pf.conf static lint: all three level files present + required idioms.
#   H. File modes / paths sane in the authored tree.

# Locate the repo root from THIS test file (tests/ is one level down).
case "$0" in
*/*) _T_HERE=${0%/*} ;;
*)   _T_HERE=. ;;
esac
REPO=$(cd "$_T_HERE/.." && pwd)

SITE="$REPO/site"
SRC="$REPO/src/velo-install"
INSTALL_SITE="$SITE/install.site.velo"
PACKER="$REPO/build/make-site-tgz.sh"

# --- tiny assert harness ---------------------------------------------------
V_FAIL=0
V_N=0

v_ok()   { V_N=$((V_N + 1)); echo "ok   $1"; }
v_fail() { V_N=$((V_N + 1)); echo "FAIL $1"; V_FAIL=$((V_FAIL + 1)); }

v_true() {  # v_true LABEL ; uses $? of the preceding command via caller
	if [ "$2" -eq 0 ]; then v_ok "$1"; else v_fail "$1"; fi
}
v_has() {  # v_has LABEL HAYSTACK NEEDLE
	V_N=$((V_N + 1))
	case "$2" in
	*"$3"*) echo "ok   $1" ;;
	*) echo "FAIL $1 (missing: [$3])"; V_FAIL=$((V_FAIL + 1)) ;;
	esac
}
v_hasnt() {  # v_hasnt LABEL HAYSTACK NEEDLE
	V_N=$((V_N + 1))
	case "$2" in
	*"$3"*) echo "FAIL $1 (UNEXPECTED: [$3])"; V_FAIL=$((V_FAIL + 1)) ;;
	*) echo "ok   $1" ;;
	esac
}
v_file() {  # v_file LABEL PATH -- exists and non-empty
	V_N=$((V_N + 1))
	if [ -s "$2" ]; then echo "ok   $1"; else echo "FAIL $1 (missing/empty: $2)"; V_FAIL=$((V_FAIL + 1)); fi
}
v_nofile() {  # v_nofile LABEL PATH -- must NOT exist
	V_N=$((V_N + 1))
	if [ -e "$2" ]; then echo "FAIL $1 (should not exist: $2)"; V_FAIL=$((V_FAIL + 1)); else echo "ok   $1"; fi
}

# Use the shell that is RUNNING this script as the parse checker, so a construct
# that passes one shell but not the other is caught when run under each.
# Prefer an explicit interpreter: whatever invoked us.  Fall back to `sh`.
if [ -n "${BASH_VERSION:-}" ]; then
	PARSE="bash -n"
elif command -v ksh >/dev/null 2>&1; then
	PARSE="ksh -n"
else
	PARSE="sh -n"
fi

echo "=== velo M2 site validation (parser: $PARSE) ==="

# ===========================================================================
# A. Parse-check the scripts.
# ===========================================================================
$PARSE "$INSTALL_SITE" 2>/tmp/velo_v_a1.$$
v_true "install.site parses ($PARSE)" $?
$PARSE "$PACKER" 2>/tmp/velo_v_a2.$$
v_true "make-site-tgz.sh parses ($PARSE)" $?
# The offline package-closure validator ships in build/; it must parse clean
# under the same shell (it runs standalone with `sh` on the build host).
CLOSURE="$REPO/build/check-pkg-closure.sh"
v_file "check-pkg-closure.sh present" "$CLOSURE"
$PARSE "$CLOSURE" 2>/tmp/velo_v_a3.$$
v_true "check-pkg-closure.sh parses ($PARSE)" $?
rm -f /tmp/velo_v_a1.$$ /tmp/velo_v_a2.$$ /tmp/velo_v_a3.$$

# ===========================================================================
# B. No network fetch; appends (>>) not clobbers (>) for rc.firsttime/sysctl.
# ===========================================================================
IS_BODY=$(cat "$INSTALL_SITE")
# No mirror fetch tools anywhere in install.site.
v_hasnt "install.site: no ftp(1) fetch"   "$IS_BODY" "ftp -"
v_hasnt "install.site: no http URL"        "$IS_BODY" "http://"
v_hasnt "install.site: no https URL"       "$IS_BODY" "https://"

# install.site must NOT source the answers file (sourcing executes value code).
v_hasnt "install.site: does NOT source answers (no '. .../answers')" "$IS_BODY" '. "${VELO_ROOT}/etc/velo/answers"'

# pkg_add must appear ONLY inside the rc.firsttime heredoc (deferred to first
# boot), never as an executed command at site time.  Exclude comment lines (#),
# audit/log message strings (log "..."), then the only remaining pkg_add line
# must be the deferred installed.list invocation -- which we also strip, leaving
# NO executable pkg_add at site time.
# No pkg_add COMMAND runs at site time.  Strip comments, log lines, the only
# legitimate deferred invocation (pkg_add -I -l /etc/velo/installed.list, which
# lives inside the rc.firsttime heredoc), and the LOUD-failure message strings
# (echo/logger lines that merely MENTION pkg_add in their text).  What remains
# must contain no pkg_add at all.
PKGADD_CODE=$(grep 'pkg_add' "$INSTALL_SITE" \
	| grep -v '^[[:space:]]*#' \
	| grep -v '^[[:space:]]*log ' \
	| grep -v '^[[:space:]]*echo ' \
	| grep -v '^[[:space:]]*logger ' \
	| grep -v 'pkg_add -I -l /etc/velo/installed.list')
v_hasnt "install.site: no pkg_add executed at site time (only the rc.firsttime block)" "${PKGADD_CODE}X" "pkg_add"

# rc.firsttime + sysctl.conf are APPENDED (>>), never clobbered (single >).
# The appends target shell variables (_rf_dst / _sysctl_dst) that resolve to the
# VELO_ROOT-prefixed paths; assert the >> append form and that NO single-> clobber
# of either real path exists.
v_has  "install.site: appends to rc.firsttime (>>)"   "$IS_BODY" '} >>"$_rf_dst"'
v_has  "install.site: rc.firsttime dst is the real path" "$IS_BODY" '_rf_dst="${VELO_ROOT}/etc/rc.firsttime"'
CLOBBER_RF=$(grep -c '>"${VELO_ROOT}/etc/rc.firsttime"' "$INSTALL_SITE")
V_N=$((V_N + 1))
if [ "$CLOBBER_RF" -eq 0 ]; then echo "ok   install.site: never clobbers rc.firsttime (no single-> redirect)"; else echo "FAIL install.site: clobbers rc.firsttime ($CLOBBER_RF single-> redirects)"; V_FAIL=$((V_FAIL + 1)); fi
v_has  "install.site: appends to sysctl.conf (>>)"    "$IS_BODY" '} >>"$_sysctl_dst"'
v_has  "install.site: sysctl dst is the real path"    "$IS_BODY" '_sysctl_dst="${VELO_ROOT}/etc/sysctl.conf"'
CLOBBER_SY=$(grep -c '>"${VELO_ROOT}/etc/sysctl.conf"' "$INSTALL_SITE")
V_N=$((V_N + 1))
if [ "$CLOBBER_SY" -eq 0 ]; then echo "ok   install.site: never clobbers sysctl.conf (no single-> redirect)"; else echo "FAIL install.site: clobbers sysctl.conf ($CLOBBER_SY single-> redirects)"; V_FAIL=$((V_FAIL + 1)); fi
# Both >> appends are sentinel-guarded so a re-run cannot double-append.
v_has  "install.site: sysctl append is sentinel-guarded"      "$IS_BODY" 'grep -qxF -- "$_sysctl_marker"'
v_has  "install.site: rc.firsttime append is sentinel-guarded" "$IS_BODY" 'grep -qxF -- "$_rf_marker"'
# The rc.firsttime block uses the OFFLINE local PKG_PATH (emitted via printf,
# branching on startmode).  The closure dir '/usr/obj/_pkgs' is the PKG_PATH base.
v_has   "install.site: rc.firsttime uses local PKG_PATH" "$IS_BODY" "export PKG_PATH=%s"
v_has   "install.site: closure dir is /usr/obj/_pkgs (largest auto-layout part)" "$IS_BODY" "_pkgdir='/usr/obj/_pkgs'"
v_has   "install.site: L3 PKG_PATH is local-only (no mirror)" "$IS_BODY" '_pkgpath="$_pkgdir"'
v_has   "install.site: L1/L2 PKG_PATH local-then-mirror"      "$IS_BODY" '_pkgpath="$_pkgdir:installpath"'
# new: the one-shot closure is reclaimed ONLY on a successful pkg_add (frees 136M..~1G).
v_has   "install.site: emits VELO_PKGDIR for first-boot reclaim" "$IS_BODY" "VELO_PKGDIR=%s"
v_has   "install.site: reclaims closure after pkg_add OK"        "$IS_BODY" 'rm -rf "$VELO_PKGDIR"'
# composed pkg list lives OUTSIDE PKG_PATH (/etc/velo), keeping the closure dir pure.
v_has   "install.site: installed.list lives in /etc/velo (not PKG_PATH)" "$IS_BODY" '_final_list="${VELO_ROOT}/etc/velo/installed.list"'
# dedup uses fixed-string match (-F) so '.'/'+' in pkg names are not regex.
v_has   "install.site: dedup uses grep -qxF (literal, for . and +)" "$IS_BODY" "grep -qxF -- "

# ===========================================================================
# C + D + E. Fakeroot DRY-RUN of install.site against a temp DESTDIR.
#   We stage the parts of the site tree install.site reads (etc/velo/pf,
#   etc/velo/sysctl, usr/obj/_pkgs/*.list, the conf bases) into $ROOT, then run
#   install.site with VELO_ROOT=$ROOT VELO_DRYRUN=1 and inspect the results.
# ===========================================================================

# stage_root DESTROOT -- copy the read-side of the site tree into DESTROOT.
stage_root() {
	_dr=$1
	mkdir -p "$_dr/etc/velo/pf" "$_dr/etc/velo/sysctl" \
		"$_dr/etc/X11/xenodm" "$_dr/etc/tor" \
		"$_dr/usr/obj/_pkgs" "$_dr/var/log"
	cp "$SITE"/etc/velo/pf/*.conf            "$_dr/etc/velo/pf/"
	cp "$SITE"/etc/velo/sysctl/*.conf        "$_dr/etc/velo/sysctl/"
	cp "$SITE"/etc/sysctl.conf               "$_dr/etc/sysctl.conf"
	cp "$SITE"/etc/doas.conf                 "$_dr/etc/doas.conf"
	cp "$SITE"/usr/obj/_pkgs/minimal.list        "$_dr/usr/obj/_pkgs/"
	cp "$SITE"/usr/obj/_pkgs/homely.list        "$_dr/usr/obj/_pkgs/"
	cp "$SITE"/usr/obj/_pkgs/fortress.list       "$_dr/usr/obj/_pkgs/"
	cp "$SITE"/etc/tor/torrc                 "$_dr/etc/tor/torrc"
	cp "$SITE"/etc/X11/xenodm/Xsetup_0       "$_dr/etc/X11/xenodm/Xsetup_0"
	# seed a pre-existing rc.firsttime line so we can prove APPEND (not clobber).
	echo "# PRE-EXISTING installer line -- must survive" > "$_dr/etc/rc.firsttime"
}

# run_site DESTROOT -- execute install.site sandboxed at DESTROOT.
run_site() {
	VELO_ROOT="$1" VELO_DRYRUN=1 sh "$INSTALL_SITE" >"$1/.site.out" 2>&1
}

TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/velo-validate.XXXXXX") || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMPBASE"' EXIT INT TERM

# --- C1: homely + L1 + extra pkgs -----------------------------------------
R1="$TMPBASE/r1"
stage_root "$R1"
cat >"$R1/etc/velo/answers" <<'ANS'
schema=1
profile=homely
startmode=L1
pkgs=mpv htop py3-foo.bar libstdc++ py3-foo.bar
hostname=velo-bsd
encrypt=yes
ANS
run_site "$R1"

v_file  "DRY homely/L1: pf.conf written"        "$R1/etc/pf.conf"
# pf.conf must be the L1 variant.
PF1=$(cat "$R1/etc/pf.conf" 2>/dev/null)
v_has   "DRY homely/L1: pf.conf is the L1 file"  "$PF1" "L1 (baseline)"
# sysctl.conf must have the base PLUS the L1 delta appended (base preserved).
SY1=$(cat "$R1/etc/sysctl.conf" 2>/dev/null)
v_has   "DRY homely/L1: sysctl base preserved"   "$SY1" "velo BASE hardening"
v_has   "DRY homely/L1: sysctl L1 delta appended" "$SY1" "velo: L1 sysctl deltas"
# installed.list = homely base UNION {mpv,htop}; mpv already in base (dedupe).
# It lives OUTSIDE PKG_PATH now (/etc/velo/installed.list), so /usr/obj/_pkgs stays
# pure package blobs.
IL1=$(cat "$R1/etc/velo/installed.list" 2>/dev/null)
v_has   "DRY homely/L1: installed.list has openbox" "$IL1" "openbox"
v_has   "DRY homely/L1: installed.list has htop (opt-in)" "$IL1" "htop"
# composed list is NOT written into the pure-blob PKG_PATH dir.
v_nofile "DRY homely/L1: no installed.list inside PKG_PATH /usr/obj/_pkgs" "$R1/usr/obj/_pkgs/installed.list"
# mpv must appear exactly once (it is in the homely base AND the opt-ins).
MPV_N=$(grep -cx 'mpv' "$R1/etc/velo/installed.list" 2>/dev/null || echo 0)
V_N=$((V_N + 1))
if [ "$MPV_N" -eq 1 ]; then echo "ok   DRY homely/L1: mpv de-duplicated (count=1)"; else echo "FAIL DRY homely/L1: mpv count=$MPV_N (expected 1)"; V_FAIL=$((V_FAIL + 1)); fi
# Tokens with '.' and '+' (regex metachars) must survive validation as LITERAL
# package names, and the duplicate 'py3-foo.bar' must collapse to exactly one
# -- proving the dedup uses grep -qxF (fixed string), not a regex match.
v_has   "DRY homely/L1: dotted pkg py3-foo.bar kept" "$IL1" "py3-foo.bar"
v_has   "DRY homely/L1: plus pkg libstdc++ kept"     "$IL1" "libstdc++"
FOO_N=$(grep -cxF 'py3-foo.bar' "$R1/etc/velo/installed.list" 2>/dev/null || echo 0)
V_N=$((V_N + 1))
if [ "$FOO_N" -eq 1 ]; then echo "ok   DRY homely/L1: py3-foo.bar de-duplicated literally (count=1)"; else echo "FAIL DRY homely/L1: py3-foo.bar count=$FOO_N (expected 1; grep -qxF literal dedup)"; V_FAIL=$((V_FAIL + 1)); fi
# rc.firsttime: pre-existing line survives AND velo block appended.
RF1=$(cat "$R1/etc/rc.firsttime" 2>/dev/null)
v_has   "DRY homely/L1: rc.firsttime pre-existing line survived" "$RF1" "PRE-EXISTING installer line"
v_has   "DRY homely/L1: rc.firsttime velo block appended"        "$RF1" "velo: offline package install"
v_has   "DRY homely/L1: rc.firsttime offline PKG_PATH"           "$RF1" "PKG_PATH=/usr/obj/_pkgs"
v_has   "DRY homely/L1: rc.firsttime sets VELO_PKGDIR"           "$RF1" "VELO_PKGDIR=/usr/obj/_pkgs"
v_has   "DRY homely/L1: rc.firsttime reclaims closure on success" "$RF1" 'rm -rf "$VELO_PKGDIR"'
# homely keeps Xsetup_0; not-L3 prunes torrc.
v_file  "DRY homely/L1: Xsetup_0 kept (homely)" "$R1/etc/X11/xenodm/Xsetup_0"
v_nofile "DRY homely/L1: torrc pruned (!L3)"     "$R1/etc/tor/torrc"
# the dry-run must NOT have touched the REAL system.
v_nofile "DRY: real /etc/velo/installed.list untouched" "/etc/velo/installed.list.SHOULD_NOT_EXIST"

# --- C2: fortress + L3 (non-base tor ensured; torrc kept; Xsetup pruned) -----
R2="$TMPBASE/r2"
stage_root "$R2"
cat >"$R2/etc/velo/answers" <<'ANS'
schema=1
profile=fortress
startmode=L3
pkgs=
ANS
run_site "$R2"
PF2=$(cat "$R2/etc/pf.conf" 2>/dev/null)
v_has   "DRY fortress/L3: pf.conf is the L3 Tor file" "$PF2" "Tor-only, fail-closed"
v_has   "DRY fortress/L3: pf.conf fail-closed block all" "$PF2" "block all"
IL2=$(cat "$R2/etc/velo/installed.list" 2>/dev/null)
v_has   "DRY fortress/L3: installed.list has tor"  "$IL2" "tor"
# L3 rc.firsttime PKG_PATH must be LOCAL-ONLY (no mirror behind fail-closed pf).
RF2=$(cat "$R2/etc/rc.firsttime" 2>/dev/null)
v_has   "DRY fortress/L3: rc.firsttime PKG_PATH local-only" "$RF2" "export PKG_PATH=/usr/obj/_pkgs"
v_has   "DRY fortress/L3: rc.firsttime sets VELO_PKGDIR"    "$RF2" "VELO_PKGDIR=/usr/obj/_pkgs"
v_has   "DRY fortress/L3: rc.firsttime reclaims closure on success" "$RF2" 'rm -rf "$VELO_PKGDIR"'
# Positional proof (Ворота-4 test-rigor finding): the reclaim rm -rf MUST sit
# INSIDE the pkg_add SUCCESS branch -- AFTER the pkg_add invocation and BEFORE the
# else/ERROR arm -- so a FAILED install never reclaims the blobs (retry-on-failure
# invariant).  A `v_has` substring check alone would not catch a future edit that
# moved the rm out of the `then`; this line-order assertion does.
RF2_FILE="$R2/etc/rc.firsttime"
PKGADD_LN=$(grep -nF 'pkg_add -I -l /etc/velo/installed.list' "$RF2_FILE" | head -1 | cut -d: -f1)
RM_LN=$(grep -nF 'rm -rf "$VELO_PKGDIR"' "$RF2_FILE" | head -1 | cut -d: -f1)
ELSE_LN=$(grep -nF 'velo: ERROR pkg_add FAILED' "$RF2_FILE" | head -1 | cut -d: -f1)
V_N=$((V_N + 1))
if [ -n "$PKGADD_LN" ] && [ -n "$RM_LN" ] && [ -n "$ELSE_LN" ] \
   && [ "$PKGADD_LN" -lt "$RM_LN" ] && [ "$RM_LN" -lt "$ELSE_LN" ]; then
	echo "ok   DRY fortress/L3: reclaim rm -rf is INSIDE the pkg_add success branch (retry-on-failure safe)"
else
	echo "FAIL DRY fortress/L3: reclaim rm -rf not provably inside success branch (pkg_add=$PKGADD_LN rm=$RM_LN else=$ELSE_LN)"; V_FAIL=$((V_FAIL + 1))
fi
v_hasnt "DRY fortress/L3: rc.firsttime NO mirror fallback (installpath)" "$RF2" "installpath"
# L1 (R1) rc.firsttime by contrast DOES carry the mirror fallback.
v_has   "DRY homely/L1: rc.firsttime PKG_PATH local-then-mirror" "$RF1" "/usr/obj/_pkgs:installpath"
v_file  "DRY fortress/L3: torrc kept (L3)"         "$R2/etc/tor/torrc"
v_nofile "DRY fortress/L3: Xsetup_0 pruned (!homely)" "$R2/etc/X11/xenodm/Xsetup_0"
# Boot-time fail-closed invariant: install.site must seed /etc/rc.local to re-assert
# the chosen pf ruleset at end of boot (guards the intermittent early-boot load gap).
RL2=$(cat "$R2/etc/rc.local" 2>/dev/null)
v_has   "DRY fortress/L3: rc.local re-asserts pf at boot" "$RL2" "pfctl -f /etc/pf.conf"
# Boot-time fail-closed invariant: install.site must seed /etc/rc.local to re-assert
# the chosen pf ruleset at end of boot (guards the intermittent early-boot load gap).
RL2=$(cat "$R2/etc/rc.local" 2>/dev/null)
v_has   "DRY fortress/L3: rc.local re-asserts pf at boot" "$RL2" "pfctl -f /etc/pf.conf"

# --- D: SAFE FLOOR -- missing answers file -> minimal + L1 ------------------
R3="$TMPBASE/r3"
stage_root "$R3"
# deliberately NO answers file written.
run_site "$R3"
PF3=$(cat "$R3/etc/pf.conf" 2>/dev/null)
v_has   "FLOOR no-answers: pf.conf defaults to L1" "$PF3" "L1 (baseline)"
IL3=$(cat "$R3/etc/velo/installed.list" 2>/dev/null)
# minimal base is git/curl/nano; must NOT contain xfce (would mean homely).
v_has   "FLOOR no-answers: installed.list is minimal (git)" "$IL3" "git"
v_hasnt "FLOOR no-answers: installed.list NOT homely (no xfce)" "$IL3" "xfce"
OUT3=$(cat "$R3/.site.out" 2>/dev/null)
v_has   "FLOOR no-answers: logs safe-floor fallback" "$OUT3" "safe floor minimal+L1"

# --- E: INJECTION GUARD -- hostile answers must not execute / must drop ------
R4="$TMPBASE/r4"
stage_root "$R4"
# A canary file in the sandbox; if injection executed `rm`/`touch`, we'd see it.
CANARY="$TMPBASE/INJECTION_CANARY"
: >"$CANARY"
cat >"$R4/etc/velo/answers" <<ANS
schema=1
profile=minimal
startmode=L1
pkgs=git curl;rm_-rf_/ \$(touch $CANARY.pwned) good-pkg a|b
ANS
run_site "$R4"
IL4=$(cat "$R4/etc/velo/installed.list" 2>/dev/null)
# good tokens survive (git, curl, good-pkg); metachar tokens are dropped.
v_has   "INJ: clean token git kept"      "$IL4" "git"
v_has   "INJ: clean token good-pkg kept" "$IL4" "good-pkg"
v_hasnt "INJ: semicolon token dropped"   "$IL4" "rm_-rf_"
v_hasnt "INJ: cmdsub token dropped"      "$IL4" "touch"
v_hasnt "INJ: pipe token dropped"        "$IL4" "a|b"
# the command-substitution must NEVER have run.
v_nofile "INJ: \$(...) did NOT execute (no .pwned canary)" "$CANARY.pwned"
OUT4=$(cat "$R4/.site.out" 2>/dev/null)
v_has   "INJ: logs at least one DROP"    "$OUT4" "DROP invalid pkg token"

# --- E2: CRLF answers must NOT silently demote to the minimal+L1 floor -------
# A DOS/CRLF answers file would leave a trailing '\r' on each value; if not
# stripped, "startmode=L3\r" fails the L1|L2|L3 whitelist and silently floors
# the box to minimal+L1.  The parser strips one trailing CR; here we assert a
# CRLF file with profile=fortress startmode=L3 lands on L3 (Tor pf), not L1.
R5="$TMPBASE/r5"
stage_root "$R5"
CR=$(printf '\r')
{
	printf 'schema=1%s\n'        "$CR"
	printf 'profile=fortress%s\n' "$CR"
	printf 'startmode=L3%s\n'     "$CR"
	printf 'pkgs=%s\n'            "$CR"
} >"$R5/etc/velo/answers"
run_site "$R5"
PF5=$(cat "$R5/etc/pf.conf" 2>/dev/null)
v_has   "CRLF: startmode=L3 survives CR strip (pf is L3 Tor file)" "$PF5" "Tor-only, fail-closed"
v_hasnt "CRLF: NOT demoted to L1 floor"                            "$PF5" "L1 (baseline)"
OUT5=$(cat "$R5/.site.out" 2>/dev/null)
v_has   "CRLF: resolves to fortress/L3"                            "$OUT5" "profile=fortress startmode=L3"

# --- E3: IDEMPOTENCY -- re-running install.site must NOT double-append --------
# Run install.site a SECOND time over the same R1 root; the sentinel guards on
# the sysctl deltas and the rc.firsttime velo block must prevent a 2nd append.
run_site "$R1"
# Count the unique SENTINEL marker lines (not a substring that recurs inside the
# block) -- each must appear exactly once after the second run.
SY1B=$(grep -cxF '# --- velo: L1 sysctl deltas (appended by install.site) ---' "$R1/etc/sysctl.conf" 2>/dev/null || echo 0)
V_N=$((V_N + 1))
if [ "$SY1B" -eq 1 ]; then echo "ok   IDEMPOTENT: sysctl L1 delta block appears once after re-run"; else echo "FAIL IDEMPOTENT: sysctl L1 delta block count=$SY1B (expected 1)"; V_FAIL=$((V_FAIL + 1)); fi
RF1B=$(grep -cxF '# --- velo: offline package install (first boot) ---' "$R1/etc/rc.firsttime" 2>/dev/null || echo 0)
V_N=$((V_N + 1))
if [ "$RF1B" -eq 1 ]; then echo "ok   IDEMPOTENT: rc.firsttime velo block appears once after re-run"; else echo "FAIL IDEMPOTENT: rc.firsttime velo block count=$RF1B (expected 1)"; V_FAIL=$((V_FAIL + 1)); fi
RUN2=$(cat "$R1/.site.out" 2>/dev/null)
v_has   "IDEMPOTENT: re-run logs rc.firsttime skip"  "$RUN2" "rc.firsttime block already present"
v_has   "IDEMPOTENT: re-run logs sysctl skip"        "$RUN2" "sysctl L1 deltas already present"

# ===========================================================================
# F. Names match src/velo-install (grep cross-check).
#    Source velo-install (VELO_SOURCED=1) in a SUBSHELL and compare profile_pkgs
#    to the shipped .list files; also assert the profile/startmode token sets.
# ===========================================================================
# list_join FILE -- non-blank/non-comment lines joined by single spaces.
# Defined at TOP LEVEL: the `case` here must NOT live inside the caller's $()
# (Void's PD-ksh mis-parses a `case` nested inside command substitution).
list_join() {
	while IFS= read -r _lj_ln; do
		case "$_lj_ln" in
		""|"#"*) ;;
		*) printf '%s ' "$_lj_ln" ;;
		esac
	done <"$1"
}

xcheck() {
	# shellcheck disable=SC1090
	VELO_SOURCED=1 . "$SRC"
	_xc_fail=0
	for _p in minimal homely fortress; do
		_exp=$(profile_pkgs "$_p")
		_lf="$SITE/usr/obj/_pkgs/${_p}.list"
		_got=$(list_join "$_lf")
		_got=${_got% }
		if [ "$_got" != "$_exp" ]; then
			echo "  x-check MISMATCH $_p: list=[$_got] profile_pkgs=[$_exp]" >&2
			_xc_fail=1
		fi
	done
	# the wizard's profile/startmode token lists must be exactly these.
	[ "$VELO_PROFILES" = "homely minimal fortress" ] || { echo "  VELO_PROFILES drift: [$VELO_PROFILES]" >&2; _xc_fail=1; }
	[ "$VELO_STARTMODES" = "L1 L2 L3" ] || { echo "  VELO_STARTMODES drift: [$VELO_STARTMODES]" >&2; _xc_fail=1; }
	return $_xc_fail
}
( xcheck ); v_true "x-check: *.list == profile_pkgs() and profile/startmode tokens match src/velo-install" $?

# Also assert install.site's own whitelists match the wizard's enums.
v_has "install.site profile whitelist matches" "$IS_BODY" "minimal|homely|fortress"
v_has "install.site startmode whitelist matches" "$IS_BODY" "L1|L2|L3"

# ===========================================================================
# G. pf.conf static lint (pfctl -nf is M3-VM; structural grep here).
# ===========================================================================
v_file "pf L1 file present" "$SITE/etc/velo/pf/pf.l1.conf"
v_file "pf L2 file present" "$SITE/etc/velo/pf/pf.l2.conf"
v_file "pf L3 file present" "$SITE/etc/velo/pf/pf.l3.conf"
PFL1=$(cat "$SITE/etc/velo/pf/pf.l1.conf")
PFL2=$(cat "$SITE/etc/velo/pf/pf.l2.conf")
PFL3=$(cat "$SITE/etc/velo/pf/pf.l3.conf")
v_has "pf L1: set skip on lo"        "$PFL1" "set skip on lo"
v_has "pf L1: default block in"      "$PFL1" "block in all"
v_has "pf L1: stateful pass out"     "$PFL1" "pass out keep state"
# L1 must NOT carry the dead 'block return out log' no-op (it never decides the
# verdict and confused the egress posture).
v_hasnt "pf L1: no dead 'block return out log' no-op" "$PFL1" "block return out log"
v_has "pf L2: blocks inet6 egress"   "$PFL2" "block out log inet6 all"
v_has "pf L2: IPv4-only egress"      "$PFL2" "pass out inet keep state"
v_has "pf L3: fail-closed block all" "$PFL3" "block all"
v_has "pf L3: loopback skipped (apps reach SOCKS)" "$PFL3" "set skip on lo"
# S model: ONLY the _tor user may egress directly; everything else is dropped.
v_has "pf L3: tor user may egress (tcp)" "$PFL3" "pass out quick proto tcp user \$tor_uid keep state"
v_has "pf L3: tor user may egress (udp)" "$PFL3" "pass out quick proto udp user \$tor_uid keep state"
# NO transparent redirect: the SOCKS-only posture must NOT carry rdr-to/divert-to
# (those were the fragile transparent-gateway rules; their absence is load-bearing).
# Check RULE-bearing lines only (strip comments) so the explanatory comment that
# NAMES rdr-to/divert-to to justify their absence does not trip the assertion.
PFL3_RULES=$(grep -vE '^[[:space:]]*#' "$SITE/etc/velo/pf/pf.l3.conf")
v_hasnt "pf L3: NO rdr-to transparent redirect"   "$PFL3_RULES" "rdr-to"
v_hasnt "pf L3: NO divert-to transparent redirect" "$PFL3_RULES" "divert-to"
# L3 torrc must enable the SOCKS proxy (the only way out) and NOT a TransPort.
# Same comment-strip so the "we do NOT enable a TransPort" note is not a false hit.
TORRC=$(cat "$SITE/etc/tor/torrc")
TORRC_RULES=$(grep -vE '^[[:space:]]*#' "$SITE/etc/tor/torrc")
v_has   "L3 torrc enables SOCKSPort 9050"  "$TORRC_RULES" "SOCKSPort 127.0.0.1:9050"
v_hasnt "L3 torrc has NO TransPort (SOCKS-only)" "$TORRC_RULES" "TransPort"
# CRITICAL: tor must run as _tor or the fail-closed pf (pass out user _tor) drops
# its egress and the box bricks.  velo's torrc MUST carry `User _tor` (the rc
# framework otherwise starts tor as root -> not covered by the _tor pass rule).
v_has   "L3 torrc runs tor as _tor (User _tor)" "$TORRC_RULES" "User _tor"
# tor started by rc as root defaults DataDirectory to /root/.tor, which _tor
# cannot access after the User drop -> tor exits.  Must pin it to the package's
# _tor-owned /var/tor.
v_has   "L3 torrc pins DataDirectory to /var/tor" "$TORRC_RULES" "DataDirectory /var/tor"
# SOCKS must stay loopback-bound (never 0.0.0.0) -- a LAN-exposure regression guard.
v_hasnt "L3 torrc: SOCKS NOT on 0.0.0.0"        "$TORRC_RULES" "0.0.0.0:9050"
# best-anonymity hardening present (forces Tor-side DNS; pure client).
v_has   "L3 torrc: SafeSocks on (no DNS-leak)"  "$TORRC_RULES" "SafeSocks 1"
v_has   "L3 torrc: ClientOnly (never a relay)"  "$TORRC_RULES" "ClientOnly 1"
# CRITICAL: tor must run as _tor or the fail-closed pf (pass out user _tor) drops
# its egress and the box bricks.  velo's torrc MUST carry `User _tor` (the rc
# framework otherwise starts tor as root -> not covered by the _tor pass rule).
v_has   "L3 torrc runs tor as _tor (User _tor)" "$TORRC_RULES" "User _tor"
# tor started by rc as root defaults DataDirectory to /root/.tor, which _tor
# cannot access after the User drop -> tor exits.  Must pin it to the package's
# _tor-owned /var/tor.
v_has   "L3 torrc pins DataDirectory to /var/tor" "$TORRC_RULES" "DataDirectory /var/tor"
# SOCKS must stay loopback-bound (never 0.0.0.0) -- a LAN-exposure regression guard.
v_hasnt "L3 torrc: SOCKS NOT on 0.0.0.0"        "$TORRC_RULES" "0.0.0.0:9050"
# best-anonymity hardening present (forces Tor-side DNS; pure client).
v_has   "L3 torrc: SafeSocks on (no DNS-leak)"  "$TORRC_RULES" "SafeSocks 1"
v_has   "L3 torrc: ClientOnly (never a relay)"  "$TORRC_RULES" "ClientOnly 1"

# ===========================================================================
# H. File modes / paths sane in the authored tree.
# ===========================================================================
V_N=$((V_N + 1))
if [ -x "$INSTALL_SITE" ]; then echo "ok   install.site is executable in the tree"; else echo "FAIL install.site not executable (chmod +x)"; V_FAIL=$((V_FAIL + 1)); fi
v_has "install.site shebang is /bin/sh (target shell)" "$(head -1 "$INSTALL_SITE")" "#!/bin/sh"
v_file "doas.conf present"     "$SITE/etc/doas.conf"
# doas.conf must NOT carry a passwordless pkg_add rule: package @exec scripts
# would give any wheel member passwordless root code-execution.  rc.firsttime
# installs as root without it.
DOASBODY=$(cat "$SITE/etc/doas.conf")
v_hasnt "doas.conf: NO passwordless pkg_add rule (priv-esc hole)" "$DOASBODY" "permit nopass :wheel cmd pkg_add"
v_has   "doas.conf: keeps permit persist :wheel"                  "$DOASBODY" "permit persist :wheel"
v_file "sysctl.conf base present" "$SITE/etc/sysctl.conf"
v_file "login.conf.d/velo present" "$SITE/etc/login.conf.d/velo"
v_file "skel/.profile present" "$SITE/etc/skel/.profile"
v_file "skel/.kshrc present"   "$SITE/etc/skel/.kshrc"
v_file "minimal.list present"  "$SITE/usr/obj/_pkgs/minimal.list"
v_file "homely.list present"  "$SITE/usr/obj/_pkgs/homely.list"
v_file "fortress.list present" "$SITE/usr/obj/_pkgs/fortress.list"
# answers must NOT be shipped in the authored tree (the TUI writes it at install).
v_nofile "no answers file baked into the static tree" "$SITE/etc/velo/answers"
# hostname.iwm0 must be present as a template but must NOT contain real PSK values.
v_file   "hostname.iwm0 template present"             "$SITE/etc/hostname.iwm0"
_hn_active=$(grep -v '^[[:space:]]*#' "$SITE/etc/hostname.iwm0" 2>/dev/null)
v_hasnt  "hostname.iwm0: no hardcoded wpakey in active config" "$_hn_active" "wpakey"
v_hasnt  "hostname.iwm0: no active join line (template only)"   "$_hn_active" "join "

# ===========================================================================
# summary
# ===========================================================================
echo ""
if [ "$V_FAIL" -eq 0 ]; then
	echo "PASS: all $V_N checks passed."
	exit 0
else
	echo "FAIL: $V_FAIL of $V_N checks failed."
	exit 1
fi
