#!/bin/ksh
# velo-install-test.ksh -- pure-logic tests for src/velo-install (M1, DRY-RUN).
#
# Runs under OpenBSD /bin/ksh (oksh) AND bash >= 3 on the Void host.
# It SOURCES src/velo-install with VELO_SOURCED=1 (so velo_main does NOT run),
# exposing the pure functions, then asserts their behaviour.  It exercises the
# SAME logic as the script's built-in `selftest` but also adds DRY-RUN
# invariants (grep-proof that no destructive call is ever EXECUTED, and that
# no secret leaks into any generated artefact).
#
# Usage:   /usr/sbin/ksh tests/velo-install-test.ksh
#          bash          tests/velo-install-test.ksh
# Exit:    0 = all pass, 1 = a failure.

# Locate src/velo-install relative to THIS test file (no dirname in ramdisk).
case "$0" in
*/*) _T_HERE=${0%/*} ;;
*)   _T_HERE=. ;;
esac

# Source the wizard WITHOUT running main.
VELO_SOURCED=1
. "$_T_HERE/../src/velo-install"

# --- tiny assert harness ---------------------------------------------------
T_FAIL=0
T_N=0

t_eq() {  # t_eq LABEL EXPECTED ACTUAL
	T_N=$((T_N + 1))
	if [ "$2" = "$3" ]; then
		_putln "ok   $1"
	else
		_putln "FAIL $1"
		_putln "       expected: [$2]"
		_putln "       actual:   [$3]"
		T_FAIL=$((T_FAIL + 1))
	fi
}
t_rc() {  # t_rc LABEL EXPECTED_RC ACTUAL_RC
	T_N=$((T_N + 1))
	if [ "$2" = "$3" ]; then
		_putln "ok   $1"
	else
		_putln "FAIL $1 (rc expected $2 got $3)"
		T_FAIL=$((T_FAIL + 1))
	fi
}
t_has() {  # t_has LABEL HAYSTACK NEEDLE
	T_N=$((T_N + 1))
	case "$2" in
	*"$3"*) _putln "ok   $1" ;;
	*) _putln "FAIL $1 (missing: [$3])"; T_FAIL=$((T_FAIL + 1)) ;;
	esac
}
t_hasnt() {  # t_hasnt LABEL HAYSTACK NEEDLE
	T_N=$((T_N + 1))
	case "$2" in
	*"$3"*) _putln "FAIL $1 (UNEXPECTED: [$3])"; T_FAIL=$((T_FAIL + 1)) ;;
	*) _putln "ok   $1" ;;
	esac
}

# ===========================================================================
#  1. is_valid_disk accept / reject
# ===========================================================================
is_valid_disk sd0;   t_rc "is_valid_disk sd0 accept"  0 $?
is_valid_disk sd9;   t_rc "is_valid_disk sd9 accept"  0 $?
is_valid_disk wd0;   t_rc "is_valid_disk wd0 accept"  0 $?
is_valid_disk wd123; t_rc "is_valid_disk wd123 accept" 0 $?
is_valid_disk cd0;   t_rc "is_valid_disk cd0 reject"  1 $?
is_valid_disk sr0;   t_rc "is_valid_disk sr0 reject"  1 $?
is_valid_disk sd;    t_rc "is_valid_disk sd reject"   1 $?
is_valid_disk sd0a;  t_rc "is_valid_disk sd0a reject" 1 $?
is_valid_disk sd0x;  t_rc "is_valid_disk sd0x reject" 1 $?
is_valid_disk xsd0;  t_rc "is_valid_disk xsd0 reject" 1 $?
is_valid_disk "";    t_rc "is_valid_disk empty reject" 1 $?
is_valid_disk "sd0 "; t_rc "is_valid_disk trailing-space reject" 1 $?
is_valid_disk "sd0; rm -rf /"; t_rc "is_valid_disk injection reject" 1 $?
is_valid_disk '$(reboot)';     t_rc "is_valid_disk cmdsub reject"    1 $?
is_valid_disk 'sd0|sh';        t_rc "is_valid_disk pipe reject"      1 $?

# ===========================================================================
#  2. velo_list_disks (injected via VELO_FAKE_DISKS)
# ===========================================================================
# Normalise the newline-separated output to a single trailing-spaced line.
_listsp() {  # args: VELO_FAKE_DISKS value
	VELO_FAKE_DISKS="$1" velo_list_disks | while IFS= read -r _l; do _put "$_l "; done
}
t_eq "list drops cd/rd, strips DUIDs, keeps order" \
	"sd0 wd1 sd2 " "$(_listsp 'sd0:a,cd0:,wd1:b,rd0:,sd2')"
t_eq "list with empty DUIDs and trailing name" \
	"sd0 wd0 " "$(_listsp 'sd0:,fd0:,wd0')"
t_eq "list all-rejected -> empty" \
	"" "$(_listsp 'cd0:,cd1:,sr0:')"
t_eq "list single disk" \
	"sd0 " "$(_listsp 'sd0:4b84beef')"

# ===========================================================================
#  3. index -> label mapping (disk, profile, startmode, package set)
# ===========================================================================
export VELO_FAKE_DISKS='sd0:a,cd0:,wd1:b,rd0:,sd2'
t_eq "idx_to_disk 0" "sd0" "$(idx_to_disk 0)"
t_eq "idx_to_disk 1" "wd1" "$(idx_to_disk 1)"
t_eq "idx_to_disk 2" "sd2" "$(idx_to_disk 2)"
idx_to_disk 3 >/dev/null; t_rc "idx_to_disk 3 out-of-range nonzero" 1 $?
t_eq "idx_to_disk 3 prints empty" "" "$(idx_to_disk 3)"
idx_to_disk -1 >/dev/null; t_rc "idx_to_disk -1 nonzero" 1 $?
idx_to_disk x  >/dev/null; t_rc "idx_to_disk non-numeric nonzero" 1 $?
unset VELO_FAKE_DISKS

t_eq "idx_to_profile 0 homely"  "homely"  "$(idx_to_profile 0)"
t_eq "idx_to_profile 1 minimal"  "minimal"  "$(idx_to_profile 1)"
t_eq "idx_to_profile 2 fortress" "fortress" "$(idx_to_profile 2)"
idx_to_profile 3 >/dev/null; t_rc "idx_to_profile 3 nonzero" 1 $?

t_eq "idx_to_startmode 0 L1" "L1" "$(idx_to_startmode 0)"
t_eq "idx_to_startmode 1 L2" "L2" "$(idx_to_startmode 1)"
t_eq "idx_to_startmode 2 L3" "L3" "$(idx_to_startmode 2)"
idx_to_startmode 9 >/dev/null; t_rc "idx_to_startmode 9 nonzero" 1 $?

# checklist re-index: VELO_CHECKED ("IDX IDX ...") -> package names
t_eq "idxset_to_pkgs '0 2 3'" "git tmux vim" \
	"$(idxset_to_pkgs '0 2 3' git curl tmux vim)"
t_eq "idxset_to_pkgs all" "git curl tmux vim" \
	"$(idxset_to_pkgs '0 1 2 3' git curl tmux vim)"
t_eq "idxset_to_pkgs empty selection" "" \
	"$(idxset_to_pkgs '' git curl tmux vim)"
t_eq "idxset_to_pkgs ignores out-of-range index" "curl" \
	"$(idxset_to_pkgs '1 9' git curl tmux vim)"

# ===========================================================================
#  4. valid_hostname accept / reject
# ===========================================================================
valid_hostname "velo-bsd"; t_rc "hostname velo-bsd accept" 0 $?
valid_hostname "a";        t_rc "hostname single char accept" 0 $?
valid_hostname "A0-z9";    t_rc "hostname mixed accept" 0 $?
valid_hostname "-bad";     t_rc "hostname leading hyphen reject" 1 $?
valid_hostname "bad-";     t_rc "hostname trailing hyphen reject" 1 $?
valid_hostname "a.b";      t_rc "hostname dotted reject" 1 $?
valid_hostname "a b";      t_rc "hostname space reject" 1 $?
valid_hostname "a;b";      t_rc "hostname semicolon reject" 1 $?
valid_hostname '$x';       t_rc "hostname dollar reject" 1 $?
valid_hostname "";         t_rc "hostname empty reject" 1 $?
_H63="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
valid_hostname "$_H63";    t_rc "hostname 63 chars accept" 0 $?
valid_hostname "${_H63}a"; t_rc "hostname 64 chars reject" 1 $?

# ===========================================================================
#  5. profile_pkgs data table
# ===========================================================================
t_eq  "profile_pkgs minimal" "git curl nano" "$(profile_pkgs minimal)"
t_has "profile_pkgs homely has openbox" "$(profile_pkgs homely)" "openbox"
t_has "profile_pkgs homely has firefox" "$(profile_pkgs homely)" "firefox"
t_has "profile_pkgs homely has tint2" "$(profile_pkgs homely)" "tint2"
t_has "profile_pkgs homely has terminator" "$(profile_pkgs homely)" "terminator"
t_has "profile_pkgs homely has thunar" "$(profile_pkgs homely)" "thunar"
t_has "profile_pkgs fortress has tor"   "$(profile_pkgs fortress)" "tor"
t_has "profile_pkgs fortress has gnupg" "$(profile_pkgs fortress)" "gnupg"
profile_pkgs bogus >/dev/null; t_rc "profile_pkgs unknown nonzero" 1 $?
t_eq  "profile_pkgs unknown empty" "" "$(profile_pkgs bogus)"

# ===========================================================================
#  6. gen_install_conf output (encrypt=no) + quoting/no-injection
# ===========================================================================
VELO_S_ENCRYPT="no"; VELO_S_DISK="sd0"; VELO_S_ROOTDISK="sd0"
VELO_S_HOSTNAME="velo-bsd"; VELO_S_PROFILE="homely"; VELO_S_STARTMODE="L1"
VELO_S_PASSPHRASE="TOPSECRET-PASS-DO-NOT-LEAK"
CONF_NO=$(gen_install_conf)
t_has "conf(no) root disk = sd0" "$CONF_NO" "Which disk is the root disk = sd0"
t_has "conf(no) hostname line"   "$CONF_NO" "System hostname = velo-bsd"
t_has "conf(no) verify-off line" "$CONF_NO" "Continue without verification = yes"
t_has "conf(no) sets line"       "$CONF_NO" "Set name(s) ="
t_has "conf(no) layout line"     "$CONF_NO" "Use (A)uto layout = auto"
# wired-ethernet block (2026-06-07 fix): pin em0/dhcp so configure_ifs() never
# defaults to the firmware-less Wi-Fi iwm0 and hangs the unattended install.
t_has "conf(no) em0 iface line"  "$CONF_NO" "Network interface to configure = em0"
t_has "conf(no) em0 dhcp line"   "$CONF_NO" "IPv4 address for em0 = autoconf"
t_has "conf(no) em0 no-ipv6"     "$CONF_NO" "IPv6 address for em0 = none"
t_has "conf(no) iface loop done" "$CONF_NO" "Network interface to configure = done"
t_hasnt "conf(no) never iwm0"    "$CONF_NO" "iwm0"
t_hasnt "conf(no) NO passphrase" "$CONF_NO" "TOPSECRET-PASS-DO-NOT-LEAK"
t_hasnt "conf(no) NO bioctl"     "$CONF_NO" "bioctl"
t_hasnt "conf(no) NO fdisk"      "$CONF_NO" "fdisk"

# set-location block (2026-06-08 Fujitsu fix): the FOUR install.sub prompts after
# "Location of sets = disk" must be answered, or autoinstall takes the wrong
# defaults (sd0/i/7.9-amd64) and aborts "7.9/amd64 does not exist".  Exact 7.9
# prompt wording is transcribed from the failing console photo.
VELO_S_MEDIADISK="sd1"; VELO_S_MEDIAPART="a"; VELO_S_MEDIAPATH="7.9/amd64"
CONF_SETS=$(gen_install_conf)
t_has "conf sets location = disk"        "$CONF_SETS" "Location of sets = disk"
t_has "conf sets not-already-mounted"    "$CONF_SETS" "Is the disk partition already mounted = no"
t_has "conf sets media disk = sd1"       "$CONF_SETS" "Which disk contains the install media = sd1"
t_has "conf sets media partition = a"    "$CONF_SETS" "Which sd1 partition has the install sets = a"
t_has "conf sets pathname"               "$CONF_SETS" "Pathname to the sets = 7.9/amd64"
# DRY-RUN/plan path: detection has NOT run -> MEDIADISK empty -> "sdN" placeholder,
# never a blank disk (which would re-arm the wrong-default trap).
VELO_S_MEDIADISK=""
CONF_SETS0=$(gen_install_conf)
t_has "conf empty media disk -> sdN placeholder" "$CONF_SETS0" "Which disk contains the install media = sdN"
# injection guard: hostile media values cannot split a line or inject a second
_NL_INJ='
'
VELO_S_MEDIADISK="sd1; rm -rf /"; VELO_S_MEDIAPART="a = evil"
VELO_S_MEDIAPATH="x/y${_NL_INJ}Allow root ssh login = yes"
CONF_SETSINJ=$(gen_install_conf)
t_has  "conf sanitises bad media disk to sdN" "$CONF_SETSINJ" "Which disk contains the install media = sdN"
t_hasnt "conf bad media disk not interpolated" "$CONF_SETSINJ" "rm -rf"
t_has  "conf sanitises bad media part to a"    "$CONF_SETSINJ" "partition has the install sets = a"
t_hasnt "conf media path injection blocked"    "$CONF_SETSINJ" "Allow root ssh login = yes"
VELO_S_MEDIADISK=""; VELO_S_MEDIAPART="a"; VELO_S_MEDIAPATH="7.9/amd64"

# injection guard: a malformed hostname in state must be sanitised, never split
VELO_S_HOSTNAME="evil = pwned"
CONF_INJ=$(gen_install_conf)
t_has "conf sanitises bad hostname to default" "$CONF_INJ" "System hostname = velo-bsd"
t_hasnt "conf bad hostname not interpolated"   "$CONF_INJ" "evil = pwned"
VELO_S_HOSTNAME="velo-bsd"

# malformed root disk in state -> safe placeholder, never injected
VELO_S_ROOTDISK="sd0; rm -rf /"
CONF_INJ2=$(gen_install_conf)
t_has "conf sanitises bad rootdisk to sdN" "$CONF_INJ2" "Which disk is the root disk = sdN"
t_hasnt "conf bad rootdisk not interpolated" "$CONF_INJ2" "rm -rf"
VELO_S_ROOTDISK="sd0"

# ===========================================================================
#  6b. root/user password handling in gen_install_conf
#      Empty hash globals -> <bcrypt-hash> placeholder (DRY-RUN/plan/preview
#      carry NO credential).  Set globals (the velo_execute path) -> real hash.
#      Plaintext passwords MUST NEVER appear in the generated install.conf.
# ===========================================================================
VELO_S_ROOTPW_HASH=""; VELO_S_USERPW_HASH=""
CONF_PWPH=$(gen_install_conf)
t_has "conf placeholder root pw (no hash)" "$CONF_PWPH" "Password for root = <bcrypt-hash>"
t_has "conf placeholder user pw (no hash)" "$CONF_PWPH" "Password for user = <bcrypt-hash>"
VELO_S_ROOTPW_HASH='$2b$10$ROOThashROOThashROOThashROOThashROOThashRO'
VELO_S_USERPW_HASH='$2b$10$USERhashUSERhashUSERhashUSERhashUSERhashUS'
CONF_PWHASH=$(gen_install_conf)
t_has  "conf emits real root hash" "$CONF_PWHASH" 'Password for root = $2b$10$ROOThash'
t_has  "conf emits real user hash" "$CONF_PWHASH" 'Password for user = $2b$10$USERhash'
t_hasnt "conf no placeholder once hashed" "$CONF_PWHASH" "<bcrypt-hash>"
VELO_S_ROOTPW_HASH=""; VELO_S_USERPW_HASH=""
# Plaintext passwords in state must never leak into the response file.
VELO_S_ROOTPW="PLAINTEXT-ROOT-PW-DO-NOT-LEAK"; VELO_S_USERPW="PLAINTEXT-USER-PW-DO-NOT-LEAK"
CONF_PWLEAK=$(gen_install_conf)
t_hasnt "conf NO plaintext root pw" "$CONF_PWLEAK" "PLAINTEXT-ROOT-PW-DO-NOT-LEAK"
t_hasnt "conf NO plaintext user pw" "$CONF_PWLEAK" "PLAINTEXT-USER-PW-DO-NOT-LEAK"
VELO_S_ROOTPW=""; VELO_S_USERPW=""

# ===========================================================================
#  6c. Set-mask per profile -- minimal must not install X sets.
#      xbase79.tgz/xfont79.tgz/xserv79.tgz/xshare79.tgz are excluded via
#      "-xbase* -xfont* -xserv* -xshare*".  The old "-x11*" pattern silently
#      matched nothing (none of the X set names start with "x11").
# ===========================================================================
VELO_S_ENCRYPT="no"; VELO_S_DISK="sd0"; VELO_S_ROOTDISK="sd0"
VELO_S_HOSTNAME="velo-bsd"; VELO_S_STARTMODE="L1"

VELO_S_PROFILE="minimal"
CONF_MINIMAL_SETS=$(gen_install_conf)
# The old "-x11*" bug: none of the X sets (xbase79.tgz etc.) start with "x11",
# so the exclusion was silently a no-op.  Verify the CORRECT explicit patterns.
t_has   "minimal set-mask: excludes -xbase*"   "$CONF_MINIMAL_SETS" "-xbase*"
t_has   "minimal set-mask: excludes -xfont*"   "$CONF_MINIMAL_SETS" "-xfont*"
t_has   "minimal set-mask: excludes -xserv*"   "$CONF_MINIMAL_SETS" "-xserv*"
t_has   "minimal set-mask: excludes -xshare*"  "$CONF_MINIMAL_SETS" "-xshare*"
t_hasnt "minimal set-mask: old -x11* NOT used" "$CONF_MINIMAL_SETS" "-x11"
t_hasnt "minimal set-mask: no +xbase add"      "$CONF_MINIMAL_SETS" "+xbase"
t_has   "minimal set-mask: games out"          "$CONF_MINIMAL_SETS" "-game*"

VELO_S_PROFILE="homely"
CONF_HOMELY_SETS=$(gen_install_conf)
t_has   "homely set-mask: Set name(s) present" "$CONF_HOMELY_SETS" "Set name(s) ="
t_hasnt "homely set-mask: X not excluded"      "$CONF_HOMELY_SETS" "-xbase"
t_hasnt "homely set-mask: X not excluded 2"    "$CONF_HOMELY_SETS" "-xfont"
t_has   "homely set-mask: games still out"     "$CONF_HOMELY_SETS" "-game*"

VELO_S_PROFILE="fortress"
CONF_FORT_SETS=$(gen_install_conf)
t_hasnt "fortress set-mask: no -xbase"  "$CONF_FORT_SETS" "-xbase"
t_has   "fortress set-mask: games out"  "$CONF_FORT_SETS" "-game*"

VELO_S_PROFILE="homely"

# ===========================================================================
#  7. gen_install_conf output (encrypt=yes -> crypto placeholder)
# ===========================================================================
VELO_S_ENCRYPT="yes"; VELO_S_ROOTDISK="sdN"
CONF_YES=$(gen_install_conf)
t_has "conf(yes) root disk = sdN"   "$CONF_YES" "Which disk is the root disk = sdN"
t_hasnt "conf(yes) NO passphrase"   "$CONF_YES" "TOPSECRET-PASS-DO-NOT-LEAK"
t_hasnt "conf(yes) NO sd0 rootline" "$CONF_YES" "root disk = sd0"

# ===========================================================================
#  8. plan_crypto quoting + stdin pipe + no-secret + reject-bad-input
# ===========================================================================
VELO_S_PASSPHRASE="TOPSECRET-PASS-DO-NOT-LEAK"
PC=$(plan_crypto sd0); PC_RC=$?
t_rc  "plan_crypto sd0 rc 0" 0 "$PC_RC"
t_has "plan_crypto bioctl quoted -l"      "$PC" 'bioctl -Cforce -cC -l"sd0a" -s softraid0'
t_has "plan_crypto stdin pipe var-name"   "$PC" 'print -r -- "$VELO_PASSPHRASE" |'
t_has "plan_crypto fdisk quoted device"   "$PC" 'fdisk -iy -g -b 960 "sd0"'
t_has "plan_crypto disklabel quoted dev"  "$PC" 'disklabel -E "sd0"'
t_has "plan_crypto dd wipe quoted dev"    "$PC" 'dd if=/dev/zero of="/dev/rsdNc" bs=1m count=1'
t_has "plan_crypto reads unit from bioctl" "$PC" "bioctl softraid0"
t_hasnt "plan_crypto NO real secret"      "$PC" "TOPSECRET-PASS-DO-NOT-LEAK"

# wd device variant: every interpolation quoted
PCW=$(plan_crypto wd3)
t_has "plan_crypto wd3 bioctl quoted" "$PCW" 'bioctl -Cforce -cC -l"wd3a" -s softraid0'
t_has "plan_crypto wd3 fdisk quoted"  "$PCW" 'fdisk -iy -g -b 960 "wd3"'

# bad / injected input -> nonzero and PRINTS NOTHING
PCBAD=$(plan_crypto cd0); PCBAD_RC=$?
t_rc "plan_crypto cd0 nonzero" 1 "$PCBAD_RC"
t_eq "plan_crypto cd0 prints nothing" "" "$PCBAD"
PCINJ=$(plan_crypto "sd0; rm -rf /"); PCINJ_RC=$?
t_rc "plan_crypto injection nonzero" 1 "$PCINJ_RC"
t_eq "plan_crypto injection prints nothing" "" "$PCINJ"
PCEMPTY=$(plan_crypto ""); PCEMPTY_RC=$?
t_rc "plan_crypto empty nonzero" 1 "$PCEMPTY_RC"
t_eq "plan_crypto empty prints nothing" "" "$PCEMPTY"

# ===========================================================================
#  8b. boot-mode (Backlog-C): uefi/GPT vs legacy/MBR target.
#      velo_fdisk_args is the SINGLE source of truth shared by plan_crypto
#      (preview) AND velo_run_crypto (real), so the printed plan and the real
#      partitioning cannot drift (lesson C6/Ворота-4).  Detection keys on
#      efi0/efifb0; `same` defers to it; an unresolved `same` is a fail-safe
#      STOP on the real path.  VELO_BOOTMODE_DETECT overrides the probe.
# ===========================================================================
# fdisk args -- the one place the GPT/MBR flags live
t_eq "fdisk_args uefi -> GPT+ESP" "-iy -g -b 960" "$(velo_fdisk_args uefi)"
t_eq "fdisk_args bios -> legacy MBR" "-iy"        "$(velo_fdisk_args bios)"
velo_fdisk_args same    >/dev/null; t_rc "fdisk_args same not an effective mode" 1 $?
velo_fdisk_args unknown >/dev/null; t_rc "fdisk_args unknown nonzero"            1 $?
velo_fdisk_args ""      >/dev/null; t_rc "fdisk_args empty nonzero"              1 $?

# detection override (host has no /var/run/dmesg.boot; the override makes this
# deterministic on any platform)
t_eq "detect override uefi" "uefi" "$(VELO_BOOTMODE_DETECT=uefi velo_detect_bootmode)"
t_eq "detect override bios" "bios" "$(VELO_BOOTMODE_DETECT=bios velo_detect_bootmode)"

# resolution: explicit mode wins over detection; `same` defers; unknown STOPs
VELO_S_BOOTMODE=uefi
t_eq "resolve explicit uefi wins over detect" "uefi" "$(VELO_BOOTMODE_DETECT=bios velo_resolve_bootmode)"
VELO_S_BOOTMODE=bios
t_eq "resolve explicit bios"                  "bios" "$(velo_resolve_bootmode)"
VELO_S_BOOTMODE=same
t_eq "resolve same -> detect uefi" "uefi" "$(VELO_BOOTMODE_DETECT=uefi velo_resolve_bootmode)"
t_eq "resolve same -> detect bios" "bios" "$(VELO_BOOTMODE_DETECT=bios velo_resolve_bootmode)"
VELO_BOOTMODE_DETECT=unknown velo_resolve_bootmode >/dev/null
t_rc "resolve same + unknown -> STOP (rc1)" 1 $?
t_eq "resolve same + unknown echoes unknown" "unknown" "$(VELO_BOOTMODE_DETECT=unknown velo_resolve_bootmode)"

# plan_crypto preview reflects the resolved mode
VELO_S_BOOTMODE=uefi; PCU=$(plan_crypto sd0)
t_has  "plan_crypto uefi -> GPT fdisk"  "$PCU" 'fdisk -iy -g -b 960 "sd0"'
VELO_S_BOOTMODE=bios; PCB=$(plan_crypto sd0)
t_has  "plan_crypto bios -> MBR fdisk"  "$PCB" 'fdisk -iy "sd0"'
t_hasnt "plan_crypto bios is NOT GPT"   "$PCB" 'fdisk -iy -g'
t_has  "plan_crypto bios keeps blank-offset RAID slice" "$PCB" 'disklabel -E "sd0"'
# same + undetectable -> uefi preview WITH a run-time note (real run STOPs)
VELO_S_BOOTMODE=same; PCS=$(VELO_BOOTMODE_DETECT=unknown plan_crypto sd0)
t_has  "plan_crypto same/unknown -> uefi preview"  "$PCS" 'fdisk -iy -g -b 960 "sd0"'
t_has  "plan_crypto same/unknown notes run-time detect" "$PCS" 'auto-detected at run time'
VELO_S_BOOTMODE=same   # restore default

# ANTI-DRIFT (structural, source-level): both crypto paths must route fdisk
# through velo_fdisk_args, and NO executable line may hardcode the GPT flags.
# (mirrors S7's source-position assert.)
_AD_SRC="$_T_HERE/../src/velo-install"
t_eq "anti-drift: no hardcoded GPT fdisk command line" "0" \
	"$(grep -c '^[[:space:]]*fdisk -iy -g' "$_AD_SRC")"
t_eq "anti-drift: velo_run_crypto routes via fdisk \$_vrc_fargs" "1" \
	"$(grep -c 'fdisk \$_vrc_fargs "\$_vrc_disk"' "$_AD_SRC")"
t_eq "anti-drift: plan_crypto routes via fdisk \${_pc_fargs}" "1" \
	"$(grep -c 'fdisk \${_pc_fargs} "\${_pc_disk}"' "$_AD_SRC")"

# ---------------------------------------------------------------------------
# 8c. BEHAVIOURAL fail-safe on the REAL destructive path (velo_run_crypto).
#     The structural greps above prove the fdisk call is ROUTED through
#     velo_fdisk_args, but not that the unresolved-mode guard actually STOPs
#     before fdisk -- a mutation that drops the guard survives every grep.  So
#     drive velo_run_crypto directly with fdisk/disklabel/bioctl/dd shadowed by
#     recording stubs (no real disk touched), in a subshell that also holds the
#     arming env so it cannot leak.  Two cases:
#       A  same + detect=unknown -> MUST return 1 and MUST NOT reach fdisk.
#       B  bios (resolvable)     -> MUST reach fdisk with exactly "-iy sd0"
#          (positive control: proves A's "fdisk not called" isn't vacuous, and
#           that the real path emits the legacy MBR args end-to-end).
# ---------------------------------------------------------------------------
_BEHAV=$(
	VELO_ALLOW_EXECUTE=yes          # arm (contained in this subshell only)
	VELO_S_PASSPHRASE="x"           # non-empty so the passphrase guard passes
	# Recording / benign stubs -- shadow the destructive externals.
	fdisk()           { _FDISK="$*"; return 0; }
	disklabel()       { cat >/dev/null 2>&1; return 0; }   # swallow the heredoc
	bioctl()          { cat >/dev/null 2>&1; return 0; }   # swallow the pw pipe
	dd()              { return 0; }
	velo_crypto_unit() { echo sd9; return 0; }             # a valid crypto unit
	# Case A: unresolved boot mode -> fail-safe STOP before fdisk.
	VELO_S_BOOTMODE="same"; _FDISK=""
	VELO_BOOTMODE_DETECT=unknown velo_run_crypto sd0 >/dev/null 2>&1; _rcA=$?
	_fdiskA=$_FDISK
	# Case B: resolvable bios -> reaches fdisk with the legacy MBR args.
	VELO_S_BOOTMODE="bios"; _FDISK="__not-called__"
	velo_run_crypto sd0 >/dev/null 2>&1
	_fdiskB=$_FDISK
	# Case C: hybrid -> reaches fdisk -iy (step 1) AND calls velo_fdisk_hybrid_esp (step 2).
	# Shadow velo_fdisk_hybrid_esp to record the call without real disk I/O.
	_HESP_CALLED=""
	velo_fdisk_hybrid_esp() { _HESP_CALLED="$1"; return 0; }
	VELO_S_BOOTMODE="hybrid"; _FDISK="__not-called__"
	velo_run_crypto sd0 >/dev/null 2>&1
	_fdiskC=$_FDISK
	_hespC=$_HESP_CALLED
	echo "$_rcA|$_fdiskA|$_fdiskB|$_fdiskC|$_hespC"
)
_OIFS=$IFS; IFS='|'; set -- $_BEHAV; IFS=$_OIFS
t_eq "run_crypto STOPs (rc1) on unresolved boot mode" "1"           "$1"
t_eq "run_crypto did NOT reach fdisk on STOP"         ""            "$2"
t_eq "run_crypto reaches fdisk with legacy MBR args"  "-iy sd0"     "$3"
t_eq "run_crypto hybrid: reaches fdisk -iy (step 1)"  "-iy sd0"     "$4"
t_eq "run_crypto hybrid: calls fdisk_hybrid_esp"       "sd0"        "$5"

# ---------------------------------------------------------------------------
# 8d. BEHAVIOURAL fail-safe: a MOUNTED target is refused by velo_execute BEFORE
#     any confirm or crypto.  TUI-SAFE marks a mounted disk [MOUNTED] but leaves
#     it pickable (spec fork "б": ENRICH+WARN, not auto-hide) -- the actual
#     safety rests on this one guard (velo-install velo_execute).  The greps in
#     8a/8b don't prove it STOPs, and a mutation dropping it survives them, so
#     drive velo_execute directly with mount/confirm/crypto shadowed by
#     recording stubs (no real disk touched), arming env contained in a subshell.
#       A  mounted    -> MUST return 1, MUST NOT call confirm, MUST NOT call crypto.
#       B  not mounted -> MUST reach confirm (positive control: proves A's
#          "confirm not called" isn't vacuous; confirm then cancels so B writes
#          nothing).
# ---------------------------------------------------------------------------
_BUSY=$(
	VELO_ALLOW_EXECUTE=yes          # arm (contained in this subshell only)
	VELO_S_PROFILE=minimal          # recovery: skip homely size-gate in stub run
	VELO_S_DISK=sd0
	# Satisfy the read-only PRE-FLIGHT (print builtin / non-empty pw / target!=media
	# / unique medium / bcrypt hash) so case B actually REACHES the confirm gate;
	# the MOUNTED guard (case A) still refuses earlier, at velo_disk_busy.
	VELO_HAS_PRINT=1; VELO_S_ROOTPW=x; VELO_S_USERPW=x
	velo_disk_probe()      { return 0; }
	velo_disk_is_media()   { return 1; }            # target is NOT the medium
	velo_find_media_disk() { echo sd1; return 0; }  # a unique medium exists
	is_valid_disk()        { return 0; }
	encrypt()              { echo '$2b$10$stub'; }   # bcrypt-shaped hash
	velo_clear()               { return 0; }
	velo_confirm_destructive() { _CONF=called; return 1; }   # record + cancel
	velo_run_crypto()          { _CRYP=called; return 0; }   # must never run
	# Case A: mount reports sd0 busy -> refuse before confirm/crypto.
	mount() { echo "/dev/sd0a on /mnt type ffs (local)"; }
	_CONF=no; _CRYP=no
	velo_execute >/dev/null 2>&1; _rcA=$?
	_confA=$_CONF; _crypA=$_CRYP
	# Case B: mount reports nothing busy -> reaches confirm (which cancels).
	mount() { return 0; }
	_CONF=no; _CRYP=no
	velo_execute >/dev/null 2>&1
	_confB=$_CONF
	# Case C: media detect FAILS -> abort BEFORE confirm/crypto.  THE invariant of
	# the 2026-06-11 pre-flight reorder: "could not identify medium" must never
	# again be discovered post-wipe (it bit the 2026-06-08 metal run).  A mutation
	# moving velo_find_media_disk back below the gate fails exactly here.
	velo_find_media_disk() { return 1; }
	_CONF=no; _CRYP=no
	velo_execute >/dev/null 2>&1; _rcC=$?
	_confC=$_CONF; _crypC=$_CRYP
	# Case D: the TARGET probes as the velo install medium itself -> hard refuse
	# pre-gate (never erase the installer stick mid-run).
	velo_find_media_disk() { echo sd1; return 0; }
	velo_disk_is_media()   { return 0; }            # target IS the medium
	_CONF=no; _CRYP=no
	velo_execute >/dev/null 2>&1; _rcD=$?
	_confD=$_CONF
	echo "$_rcA|$_confA|$_crypA|$_confB|$_rcC|$_confC|$_crypC|$_rcD|$_confD"
)
_OIFS=$IFS; IFS='|'; set -- $_BUSY; IFS=$_OIFS
t_eq "execute REFUSES (rc1) a mounted target"        "1"      "$1"
t_eq "execute did NOT confirm on mounted target"     "no"     "$2"
t_eq "execute did NOT reach crypto on mounted target" "no"    "$3"
t_eq "execute DOES confirm when not mounted (ctrl)"  "called" "$4"
t_eq "execute aborts (rc1) when medium not found"     "1"     "$5"
t_eq "media-detect failure aborts BEFORE confirm"     "no"    "$6"
t_eq "media-detect failure aborts BEFORE crypto"      "no"    "$7"
t_eq "execute REFUSES (rc1) target==install medium"   "1"     "$8"
t_eq "target==medium refused BEFORE confirm"          "no"    "$9"

# ---------------------------------------------------------------------------
# 8e. POST-GATE behaviour: (i) TOCTOU belt -- the pinned medium is re-verified
#     AFTER the typed gate but still PRE-WIPE (operator can dwell at the gate;
#     a USB re-enumeration there must abort, not fail post-wipe); (ii) a failed
#     post-install mount must not masquerade as a clean install: hybrid (empty
#     ESP = no UEFI boot) is FATAL rc1 with efifill never reached, non-hybrid
#     completes DEGRADED rc0 WITHOUT the "install complete." line.
#     velo_disk_probe stub records its arg so velo_disk_is_media can answer
#     per-disk: target sd0 is never the medium, medium sd1 answers per case.
# ---------------------------------------------------------------------------
_PG=$(
	VELO_ALLOW_EXECUTE=yes          # arm (contained in this subshell only)
	VELO_S_PROFILE=minimal          # recovery: skip homely size-gate in stub run
	VELO_S_DISK=sd0
	VELO_HAS_PRINT=1; VELO_S_ROOTPW=x; VELO_S_USERPW=x
	# VELO_HAS_PRINT=1 above only satisfies the pre-flight check; under bash it
	# would also route _put through the MISSING `print` builtin and silently eat
	# every message this section asserts on -- so shadow _putln with a portable
	# echo (messages here are plain ASCII, no escapes to mangle).
	_putln() { echo "$*"; }
	velo_clear() { return 0; }
	mount() { return 1; }            # target never busy; post-install mount FAILS
	velo_confirm_destructive() { return 0; }        # operator confirms
	velo_find_media_disk() { echo sd1; return 0; }
	is_valid_disk() { return 0; }
	encrypt() { echo '$2b$10$stub'; }
	gen_install_conf() { echo "# stub"; }
	install() { return 0; }          # stock installer "succeeds"
	velo_efifill() { _EFI=called; return 0; }
	velo_run_crypto() { _CRYP=called; VELO_CRYPTO_UNIT=sd9; return 0; }
	velo_disk_probe() { _VDIM=$1; return 0; }
	# (i) medium VANISHES at the gate: is_media false for every disk -> the
	# pre-flight target check passes (sd0 not media), find_media_disk is green,
	# but the post-gate re-probe of sd1 fails -> abort BEFORE crypto.
	velo_disk_is_media() { return 1; }
	VELO_S_ENCRYPT=yes
	_CRYP=no
	velo_execute >/dev/null 2>&1; _rc1=$?; _cryp1=$_CRYP
	# (ii) medium still answers (sd1=media, sd0=not) -> belt passes; the
	# post-install mount then fails.  Non-hybrid first: DEGRADED completion.
	velo_disk_is_media() { [ "$_VDIM" = sd1 ]; }
	VELO_S_BOOTMODE=uefi
	_out2=$(velo_execute 2>&1); _rc2=$?
	case "$_out2" in (*"install complete."*) _cmpl2=yes ;; (*) _cmpl2=no ;; esac
	case "$_out2" in (*DEGRADED*)            _degr2=yes ;; (*) _degr2=no ;; esac
	# hybrid: empty ESP -> FATAL rc1; efifill lives in the success branch and
	# must never have been reached.
	VELO_S_BOOTMODE=hybrid
	_EFI=no
	velo_execute >/dev/null 2>&1; _rc3=$?
	echo "$_rc1|$_cryp1|$_rc2|$_cmpl2|$_degr2|$_rc3|$_EFI"
)
_OIFS=$IFS; IFS='|'; set -- $_PG; IFS=$_OIFS
t_eq "TOCTOU belt: vanished medium aborts (rc1)"      "1"   "$1"
t_eq "TOCTOU belt: abort happens BEFORE crypto"       "no"  "$2"
t_eq "mount-fail non-hybrid: completes DEGRADED rc0"  "0"   "$3"
t_eq "mount-fail non-hybrid: NO 'install complete.'"  "no"  "$4"
t_eq "mount-fail non-hybrid: says DEGRADED"           "yes" "$5"
t_eq "mount-fail hybrid: FATAL rc1 (empty ESP)"       "1"   "$6"
t_eq "mount-fail hybrid: efifill never reached"       "no"  "$7"

# ===========================================================================
#  9. confirm-twice mismatch logic (the pure predicate the wizard uses)
# ===========================================================================
pass_match() { [ -n "$1" ] && [ "$1" = "$2" ]; }
pass_match "abc" "abc"; t_rc "pass_match equal nonempty -> accept" 0 $?
pass_match "abc" "abd"; t_rc "pass_match different -> reject"       1 $?
pass_match "abc" "";    t_rc "pass_match second empty -> reject"    1 $?
pass_match "" "";       t_rc "pass_match both empty -> reject"      1 $?
pass_match "" "x";      t_rc "pass_match first empty -> reject"     1 $?

# _velo_scrub_secrets must clear EVERY secret global (used on every wizard/plan exit)
VELO_S_PASSPHRASE=x; VELO_PASSWORD=x; VELO_S_ROOTPW=x; VELO_S_USERPW=x
VELO_S_ROOTPW_HASH=x; VELO_S_USERPW_HASH=x
_velo_scrub_secrets
t_eq "scrub clears passphrase" "" "$VELO_S_PASSPHRASE"
t_eq "scrub clears VELO_PASSWORD" "" "$VELO_PASSWORD"
t_eq "scrub clears rootpw"     "" "$VELO_S_ROOTPW"
t_eq "scrub clears userpw"     "" "$VELO_S_USERPW"
t_eq "scrub clears roothash"   "" "$VELO_S_ROOTPW_HASH"
t_eq "scrub clears userhash"   "" "$VELO_S_USERPW_HASH"

# ===========================================================================
# 10. DRY-RUN invariant: the full `plan` output is TEXT ONLY, no secret leak,
#     and contains no EXECUTED destructive call (the destructive tokens appear
#     only inside the printed template, which is exactly what we want).
# ===========================================================================
PLAN_OUT=$(VELO_FAKE_DISKS='sd0:abc,cd0:,wd1:def' \
	VELO_S_DISK=sd0 VELO_S_ENCRYPT=yes VELO_S_HOSTNAME=velo-bsd \
	VELO_S_PROFILE=homely VELO_S_STARTMODE=L2 VELO_S_PASSPHRASE=NEVER-PRINT-ME \
	velo_plan)
t_has   "plan emits install.conf section" "$PLAN_OUT" "--- generated install.conf ---"
t_has   "plan emits crypto section"        "$PLAN_OUT" "planned full-disk-encryption shell sequence"
t_has   "plan root disk = sdN (crypto)"    "$PLAN_OUT" "Which disk is the root disk = sdN"
t_hasnt "plan NEVER prints the secret"     "$PLAN_OUT" "NEVER-PRINT-ME"
t_has   "plan shows the variable-name template" "$PLAN_OUT" 'print -r -- "$VELO_PASSPHRASE" |'
# tty/raw-mode invariant: plan must NOT emit the cursor-hide escape (no tui_init)
t_hasnt "plan does not enter raw mode (no ?25l)" "$PLAN_OUT" "?25l"

# After velo_plan, the secret globals must be scrubbed. We must run velo_plan
# IN THE CURRENT SHELL (not in $(...), which is a subshell whose variable scrub
# cannot propagate to the parent) to observe the scrub. Seed the secret in the
# parent, run plan with output discarded, then assert the globals are cleared.
VELO_FAKE_DISKS='sd0:abc'
VELO_S_DISK=sd0; VELO_S_ENCRYPT=yes; VELO_S_HOSTNAME=velo-bsd
VELO_S_PROFILE=homely; VELO_S_STARTMODE=L2
VELO_S_PASSPHRASE="LEAK-CHECK-SECRET"
VELO_PASSWORD="LEAK-CHECK-SECRET"
VELO_S_ROOTPW="LEAK-CHECK-ROOTPW"; VELO_S_USERPW="LEAK-CHECK-USERPW"
VELO_S_ROOTPW_HASH="LEAK-CHECK-ROOTHASH"; VELO_S_USERPW_HASH="LEAK-CHECK-USERHASH"
velo_plan >/dev/null 2>&1
t_eq "VELO_S_PASSPHRASE scrubbed after plan" "" "$VELO_S_PASSPHRASE"
t_eq "VELO_PASSWORD scrubbed after plan"     "" "$VELO_PASSWORD"
t_eq "VELO_S_ROOTPW scrubbed after plan"     "" "$VELO_S_ROOTPW"
t_eq "VELO_S_USERPW scrubbed after plan"     "" "$VELO_S_USERPW"
t_eq "VELO_S_ROOTPW_HASH scrubbed after plan" "" "$VELO_S_ROOTPW_HASH"
t_eq "VELO_S_USERPW_HASH scrubbed after plan" "" "$VELO_S_USERPW_HASH"
unset VELO_FAKE_DISKS

# ===========================================================================
# 11. M3 wiring: the VELO_TUI source-override seam (docs/m3-design.md s2.3).
#     The ramdisk launcher exports VELO_TUI=/velo-tui.ksh because both files
#     live at '/' in the patched bsd.rd.  Prove (a) this test sourced the
#     library via the DEFAULT path with VELO_TUI unset (the TUI functions are
#     present -> _put works, asserted implicitly throughout above), and (b) a
#     re-source honouring an explicit VELO_TUI override loads the SAME library.
#     We point the override at the real repo path and confirm a TUI primitive
#     resurfaces -- exercising the `: "${VELO_TUI:=...}"` default-keep seam.
# ===========================================================================
( # subshell so the override / re-source cannot pollute the rest of the tests
	VELO_SOURCED=1
	VELO_TUI="$_T_HERE/../src/velo-tui.ksh"
	export VELO_TUI
	# Re-source velo-install with the override set; it must source the same TUI.
	. "$_T_HERE/../src/velo-install"
	# A core TUI primitive must be defined after sourcing via the override path.
	command -v _putln >/dev/null 2>&1 || exit 3
	command -v tui_confirm >/dev/null 2>&1 || exit 3
	exit 0
)
t_rc "VELO_TUI override sources the TUI library" 0 $?

# The default-keep seam: with VELO_TUI UNSET, velo-install must fall back to the
# repo-relative path (the very path this test file already sourced successfully
# at the top).  Prove the seam keeps a pre-set value and only defaults when
# empty -- mirror the `: "${VAR:=default}"` semantics as a pure check.
_seam_default() { VTU=""; : "${VTU:=/the-default}"; echo "$VTU"; }
_seam_keep()    { VTU="/an-override"; : "${VTU:=/the-default}"; echo "$VTU"; }
t_eq "VELO_TUI seam defaults when empty" "/the-default" "$(_seam_default)"
t_eq "VELO_TUI seam keeps a preset value" "/an-override" "$(_seam_keep)"

# ===========================================================================
#  12. DISK IDENTITY (TUI-SAFE): size/type/DUID/markers enrichment.
#      Shadow disklabel/dmesg/mount with recording stubs (no real disk), then
#      drive the composer velo_disk_row + its helpers.  Stubs are defined in the
#      PARENT shell (so t_eq/t_has increment T_N here) and unset at the end.
#      Fixture: sd0 = velo install media (a:4.2BSD@1024 + i:MSDOS960@64, ~1.34G,
#      USB/removable, zero DUID); sd1 = a real 447G SSD target (a@64, internal);
#      wd0 = a 931G mounted internal disk; sd2 = valid name but disklabel FAILS.
# ===========================================================================
disklabel() {
	case "$1" in
	sd0) cat <<'L'
duid: 0000000000000000
bytes/sector: 512
total sectors: 2801024
16 partitions:
#                size           offset  fstype [fsize bsize   cpg]
  a:          2800000             1024  4.2BSD   2048 16384 12960
  c:          2801024                0  unused
  i:              960               64   MSDOS
L
		;;
	sd1) cat <<'L'
duid: 9e4f1a2b3c4d5e6f
bytes/sector: 512
total sectors: 937703088
16 partitions:
  a:        937703024               64  4.2BSD   2048 16384 12960
  c:        937703088                0  unused
L
		;;
	wd0) cat <<'L'
duid: abcd1234ef567890
bytes/sector: 512
total sectors: 1953525168
16 partitions:
  c:       1953525168                0  unused
L
		;;
	*) return 1 ;;           # sd2 et al -> disklabel failure -> all unknown
	esac
}
# NB: on a real bsd.rd /var/run/dmesg.boot exists, so velo_disk_type reads IT and
# this stub exercises the `dmesg` FALLBACK branch.  Both branches are the same
# cat|sed parse over identical text, so the type-classification logic is fully
# covered either way; the file-path branch is corroborated by velo_detect_bootmode.
dmesg() {
	cat <<'D'
sd0 at scsibus2 targ 0 lun 0: <Generic, USB Flash, 1.0> removable
scsibus2 at umass0: 1 target, initiator 0
sd1 at scsibus0 targ 0 lun 0: <ATA, Samsung SSD 870, 1B6Q>
wd0 at pciide0 channel 0 drive 0: <WDC WD10EZEX>
D
}
mount() {
	cat <<'M'
/dev/rd0a on / type ffs (rw)
/dev/wd0a on /mnt type ffs (rw)
M
}

# -- velo_human_size: the three spec-validated vectors + degradation -----------
t_eq "human_size 16 GiB"   "16.0G"  "$(velo_human_size 17179869184)"
t_eq "human_size 447 GiB"  "447.1G" "$(velo_human_size 480103981056)"
t_eq "human_size 931 GiB"  "931.5G" "$(velo_human_size 1000204886016)"
t_eq "human_size empty -> ?"       "?" "$(velo_human_size '')"
t_eq "human_size non-numeric -> ?" "?" "$(velo_human_size abc)"

# -- velo_disk_probe: parses size + DUID, gates junk to unknown ----------------
velo_disk_probe sd0
t_eq "probe sd0 total sectors"  "2801024"            "$_VDP_SECT"
t_eq "probe sd0 zero DUID kept" "0000000000000000"   "$_VDP_DUID"
velo_disk_probe sd2 >/dev/null 2>&1
t_eq "probe sd2 (disklabel fails) -> sectors unknown" "" "$_VDP_SECT"

# -- velo_disk_row: media (sd0) -- size + USB type + (none) DUID + [media?] -----
R0=$(velo_disk_row sd0)
t_has "row sd0 shows name"          "$R0" "sd0"
t_has "row sd0 shows size 1.3G"     "$R0" "1.3G"
t_has "row sd0 shows umass/removable" "$R0" "umass/removable"
t_has "row sd0 zero DUID -> (none)" "$R0" "(none)"
t_has "row sd0 flagged [media?]"    "$R0" "[media?]"
t_hasnt "row sd0 NOT mounted"       "$R0" "[MOUNTED]"

# -- velo_disk_row: real target (sd1) -- big, internal, real DUID, NO media tag -
R1=$(velo_disk_row sd1)
t_has "row sd1 size 447.1G"         "$R1" "447.1G"
t_has "row sd1 type internal"       "$R1" "internal"
t_has "row sd1 short DUID"          "$R1" "9e4f1a"
t_hasnt "row sd1 NOT mislabeled media" "$R1" "[media?]"
t_hasnt "row sd1 NOT mounted"       "$R1" "[MOUNTED]"

# -- velo_disk_row: mounted internal (wd0) -- [MOUNTED], no media tag -----------
RW=$(velo_disk_row wd0)
t_has "row wd0 size 931.5G"         "$RW" "931.5G"
t_has "row wd0 flagged [MOUNTED]"   "$RW" "[MOUNTED]"
t_hasnt "row wd0 NOT media"         "$RW" "[media?]"

# -- velo_disk_row: valid name, unreadable label -> graceful unknowns ----------
R2=$(velo_disk_row sd2)
t_has "row sd2 unknown size '?'"    "$R2" "?"
t_has "row sd2 type unknown"        "$R2" "unknown"
t_has "row sd2 DUID (none)"         "$R2" "(none)"
t_hasnt "row sd2 NOT media"         "$R2" "[media?]"

# -- anti-drift: ONE composer -> picker, summary and destroy-gate are identical
#    by construction (referential transparency: same disk -> same row string).
t_eq "row deterministic (summary==gate==picker)" "$R1" "$(velo_disk_row sd1)"

# -- the media tag is the STRICT triple: an ESP alone must NOT trigger it.
#    A large UEFI target carries a 960@64 MSDOS ESP too -> size gate rejects it.
disklabel() {
	cat <<'L'
duid: deadbeef00000000
bytes/sector: 512
total sectors: 937703088
16 partitions:
  a:        937700000             2048  4.2BSD   2048 16384 12960
  c:        937703088                0  unused
  i:              960               64   MSDOS
L
}
RU=$(velo_disk_row sd1)
t_hasnt "row big-disk-with-ESP NOT tagged media (size gate)" "$RU" "[media?]"

unset -f disklabel dmesg mount 2>/dev/null

# ===========================================================================
# 12b. HOMELY CAPACITY GATE (velo_profile_target_size_ok).  The homely desktop
#      closure exhausted /usr on a 16 GiB live run and left the target
#      inconsistent on the next boot, so a homely target below
#      VELO_HOMELY_MIN_BYTES (28 GiB) is refused BEFORE the destroy-gate;
#      minimal/fortress bypass the gate entirely.  Drive the pure predicate with
#      a disklabel stub (valid sdN names so is_valid_disk passes); cover the
#      EXACT 28-GiB boundary, one sector under, an unreadable label, and the
#      non-homely bypass.  The 28-GiB constant is also pinned so a future edit
#      of the threshold trips a visible assertion.
# ===========================================================================
t_eq "homely min-bytes constant == 28 GiB" "30064771072" "$VELO_HOMELY_MIN_BYTES"
disklabel() {
	case "$1" in
	sd3) cat <<'L'
duid: 0000000000000000
bytes/sector: 512
total sectors: 2801024
L
		;;                                              # ~1.34 GiB (well under)
	sd4) cat <<'L'
duid: 0000000000000000
bytes/sector: 512
total sectors: 937703088
L
		;;                                              # ~447 GiB
	sd5) cat <<'L'
duid: 0000000000000000
bytes/sector: 512
total sectors: 58720256
L
		;;                                              # EXACTLY 28 GiB (boundary)
	sd6) cat <<'L'
duid: 0000000000000000
bytes/sector: 512
total sectors: 58720255
L
		;;                                              # one sector UNDER 28 GiB
	*) return 1 ;;                                          # sd7 -> disklabel fails
	esac
}
velo_profile_target_size_ok sd4 homely; t_rc "size-gate homely 447G accept"            0 $?
velo_profile_target_size_ok sd3 homely; t_rc "size-gate homely 1.3G reject"            1 $?
velo_profile_target_size_ok sd5 homely; t_rc "size-gate homely EXACTLY 28 GiB accept (-ge)" 0 $?
velo_profile_target_size_ok sd6 homely; t_rc "size-gate homely one-sector-under reject" 1 $?
velo_profile_target_size_ok sd7 homely; t_rc "size-gate homely unreadable label reject" 1 $?
# minimal/fortress are exempt -- the gate returns 0 even on the tiny disk, and
# without ever needing a readable size.
velo_profile_target_size_ok sd3 minimal;  t_rc "size-gate minimal bypasses (tiny ok)"  0 $?
velo_profile_target_size_ok sd3 fortress; t_rc "size-gate fortress bypasses (tiny ok)" 0 $?
# on the homely accept path it leaves _VDP_* populated so velo_execute can report
# the detected size in its refuse/summary line without re-probing the disk.
velo_profile_target_size_ok sd4 homely
t_eq "size-gate leaves _VDP_SECT populated for caller" "937703088" "$_VDP_SECT"
unset -f disklabel 2>/dev/null

# ---------------------------------------------------------------------------
# 12c. BEHAVIOURAL: the homely capacity gate REFUSES inside velo_execute BEFORE
#      any confirm or crypto.  Sections 8d/8e deliberately set PROFILE=minimal to
#      SKIP this gate, so its enforcement on the REAL destructive path is
#      otherwise unproven -- a mutation dropping the size check at velo-install
#      line ~1458 would survive every structural grep.  So drive velo_execute
#      with a homely profile and velo_disk_probe shadowed to report the size; the
#      arming env is contained in a subshell so it cannot leak.
#        A  tiny target (< 28 GiB) -> rc1, MUST NOT confirm, MUST NOT reach crypto.
#        B  ample target (>= 28 GiB) -> reaches confirm (positive control: proves
#           A's "confirm not called" isn't vacuous; confirm then cancels so B
#           writes nothing).
# ---------------------------------------------------------------------------
_HSG=$(
	VELO_ALLOW_EXECUTE=yes          # arm (contained in this subshell only)
	VELO_S_PROFILE=homely
	VELO_S_DISK=sd0
	VELO_S_ENCRYPT=yes; VELO_S_BOOTMODE=uefi   # resolvable mode; crypto path live
	VELO_HAS_PRINT=1; VELO_S_ROOTPW=x; VELO_S_USERPW=x
	# Satisfy the read-only pre-flight so case B actually REACHES the confirm gate.
	velo_disk_busy()       { return 1; }            # target not mounted
	velo_disk_is_media()   { return 1; }            # target is NOT the medium
	velo_find_media_disk() { echo sd1; return 0; }  # a unique medium exists
	is_valid_disk()        { return 0; }
	encrypt()              { echo '$2b$10$stub'; }   # bcrypt-shaped hash
	velo_clear()               { return 0; }
	velo_confirm_destructive() { _CONF=called; return 1; }   # record + cancel
	velo_run_crypto()          { _CRYP=called; return 0; }   # must never run in A
	# Case A: tiny homely target -> capacity gate refuses pre-confirm.
	velo_disk_probe() { _VDP_SECT=2801024;  _VDP_BPS=512; return 0; }   # ~1.34 GiB
	_CONF=no; _CRYP=no
	velo_execute >/dev/null 2>&1; _rcA=$?
	_confA=$_CONF; _crypA=$_CRYP
	# Case B: ample homely target -> gate passes, reaches confirm (which cancels).
	velo_disk_probe() { _VDP_SECT=937703088; _VDP_BPS=512; return 0; }  # ~447 GiB
	_CONF=no; _CRYP=no
	velo_execute >/dev/null 2>&1
	_confB=$_CONF
	echo "$_rcA|$_confA|$_crypA|$_confB"
)
_OIFS=$IFS; IFS='|'; set -- $_HSG; IFS=$_OIFS
t_eq "homely gate REFUSES (rc1) a sub-28-GiB target"     "1"      "$1"
t_eq "homely gate refused BEFORE confirm"                "no"     "$2"
t_eq "homely gate refused BEFORE crypto"                 "no"     "$3"
t_eq "homely gate PASSES ample target -> confirm (ctrl)" "called" "$4"

# ===========================================================================
# 13. ARMED-AWARE SAFETY MESSAGES (welcome + summary tell the truth on armed
#     media).  velo_armed is 0 iff VELO_ALLOW_EXECUTE=yes; on armed media both
#     screens must WARN of a real disk erase, otherwise say DRY-RUN.  Shadow the
#     drawing widgets to no-ops so only the _text_at body text is emitted, then
#     grep the captured screen.  Shadows are top-level + unset after (cf. sec 12);
#     arming and VELO_S_* are contained per capture in a subshell so they never
#     leak.  Closes the armed-message coverage gap (selftest does not cover it).
# ===========================================================================
velo_clear()    { :; }
tui_box()       { :; }
tui_confirm()   { return 0; }
tui_input()     { return 0; }
tui_password()  { return 0; }
tui_radio()     { return 0; }
tui_menu()      { return 0; }
tui_checklist() { return 0; }
tui_msgbox()    { :; }
tui_cleanup()   { :; }
_W_DRY=$( unset VELO_ALLOW_EXECUTE; _wiz_welcome 2>/dev/null )
_W_ARM=$( VELO_ALLOW_EXECUTE=yes;   _wiz_welcome 2>/dev/null )
t_hasnt "welcome unarmed: no real-erase warning"   "$_W_DRY" "ERASE"
t_has   "welcome armed: warns disk WILL BE ERASED"  "$_W_ARM" "ERASE"
_S_DRY=$( unset VELO_ALLOW_EXECUTE
	VELO_S_DISK=sd0; VELO_S_ENCRYPT=no; VELO_S_HOSTNAME=h; VELO_S_PROFILE=minimal
	VELO_S_PKGS=""; VELO_S_STARTMODE=L1; VELO_S_BOOTMODE=same
	_wiz_summary 2>/dev/null )
_S_ARM=$( VELO_ALLOW_EXECUTE=yes
	VELO_S_DISK=sd0; VELO_S_ENCRYPT=no; VELO_S_HOSTNAME=h; VELO_S_PROFILE=minimal
	VELO_S_PKGS=""; VELO_S_STARTMODE=L1; VELO_S_BOOTMODE=same
	_wiz_summary 2>/dev/null )
t_has   "summary unarmed: DRY-RUN line"             "$_S_DRY" "DRY-RUN"
t_has   "summary armed: REAL install warning"       "$_S_ARM" "REAL install"
t_hasnt "summary armed: drops the only-PRINTS lie"  "$_S_ARM" "only PRINTS"
unset -f velo_clear tui_box tui_confirm tui_input tui_password tui_radio tui_menu tui_checklist tui_msgbox tui_cleanup 2>/dev/null

# ===========================================================================
#  unified help-line: the encrypt screen draws the footer on BOTH its radio
#  AND its passphrase sub-dialog.  The passphrase loop velo_clear-s the radio
#  footer, so it must redraw _wiz_help itself; regression-guard by counting the
#  calls (expect 2).  _wiz_help is shadowed with a newline-emitting marker --
#  the real footer emits cursor escapes with NO newline, so it cannot be
#  line-counted directly.  Everything lives in the $() subshell: the real
#  _wiz_help and the widget stubs never leak out.
# ===========================================================================
_E_HLP=$(
	VELO_RADIO_INDEX=1
	velo_clear()   { :; }
	tui_box()      { :; }
	tui_radio()    { return 0; }
	tui_password() { VELO_PASSWORD=x; return 0; }
	tui_msgbox()   { :; }
	_wiz_help()    { echo "footer:$1"; }
	_wiz_encrypt 2>/dev/null
)
t_eq "encrypt: help-line on radio AND passphrase (2x)" 2 "$(echo "$_E_HLP" | grep -c 'footer:back')"

# ===========================================================================
#  summary
# ===========================================================================
_putln ""
if [ "$T_FAIL" -eq 0 ]; then
	_putln "PASS: all $T_N assertions passed."
	exit 0
else
	_putln "FAIL: $T_FAIL of $T_N assertions failed."
	exit 1
fi
