#!/bin/ksh
# tests/velo-level-test.ksh -- unit tests for velo-level profile switcher.

set -e

# Locate the repo root from THIS test file (tests/ is one level down).
case "$0" in
*/*) _T_HERE=${0%/*} ;;
*)   _T_HERE=. ;;
esac
REPO=$(cd "$_T_HERE/.." && pwd)
VELO_LEVEL="$REPO/site/usr/local/bin/velo-level"

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

t_has() {  # t_has LABEL HAYSTACK NEEDLE
	T_N=$((T_N + 1))
	case "$2" in
	*"$3"*) echo "ok   $1" ;;
	*) echo "FAIL $1 (missing: [$3])"; T_FAIL=$((T_FAIL + 1)) ;;
	esac
}

echo "=== velo-level CLI switcher tests ==="

# 1. Setup mock prefix environment
TMP=$(mktemp -d "${TMPDIR:-/tmp}/velo-level-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/etc/velo/pf" "$TMP/etc/velo/sysctl" "$TMP/etc/tor" "$TMP/var/log"
echo "# L1 rules" > "$TMP/etc/velo/pf/pf.l1.conf"
echo "# L2 rules" > "$TMP/etc/velo/pf/pf.l2.conf"
echo "# L3 rules" > "$TMP/etc/velo/pf/pf.l3.conf"

echo "net.inet.ip.forwarding=0" > "$TMP/etc/velo/sysctl/sysctl.l1.conf"
echo "net.inet.ip.forwarding=0\nnet.inet6.ip6.forwarding=0" > "$TMP/etc/velo/sysctl/sysctl.l2.conf"
echo "net.inet.ip.forwarding=0" > "$TMP/etc/velo/sysctl/sysctl.l3.conf"

echo "# /etc/tor/torrc -- velo L3 template" > "$TMP/etc/velo/torrc"

cat > "$TMP/etc/velo/answers" <<ANS
schema=1
profile=terminal
startmode=L1
pkgs=
hostname=velo-terminal
encrypt=yes
ANS

echo "# base sysctl" > "$TMP/etc/sysctl.conf"
echo "# base pf" > "$TMP/etc/pf.conf"

# Export VELO_ROOT so velo-level switches within the mock sandbox
export VELO_ROOT="$TMP"
export VELO_LEVEL_TEST=1  # bypass root check for testing

# 2. Status check
_status=$(sh "$VELO_LEVEL" status)
t_has "status displays active profile" "$_status" "protection profile = L1"

# 3. Switch L1 -> L2
sh "$VELO_LEVEL" L2 >/dev/null; t_rc "switch to L2 exit code" 0 $?
_pf_content=$(cat "$TMP/etc/pf.conf" 2>/dev/null)
t_eq "pf.conf content updated to L2" "# L2 rules" "$_pf_content"

_sysctl_content=$(cat "$TMP/etc/sysctl.conf" 2>/dev/null)
t_has "sysctl.conf updated with L2 deltas" "$_sysctl_content" "net.inet6.ip6.forwarding=0"
t_has "sysctl.conf contains switcher sentinel" "$_sysctl_content" "velo: L2 sysctl deltas"

# Check answers updated
_answers_startmode=$(sed -n 's/^startmode=\(.*\)/\1/p' "$TMP/etc/velo/answers")
t_eq "answers file updated to L2" "L2" "$_answers_startmode"

# 4. Double switch (L2 -> L2) - Idempotency
sh "$VELO_LEVEL" L2 >/dev/null; t_rc "idempotent switch to L2" 0 $?
_sysctl_double=$(cat "$TMP/etc/sysctl.conf" 2>/dev/null)
# Count occurrences of the sentinel
_sentinel_count=$(grep -c "velo: L2 sysctl deltas" "$TMP/etc/sysctl.conf" || echo 0)
t_eq "sentinel is present exactly once" 1 $_sentinel_count

# 5. Switch L2 -> L3 (Tor)
sh "$VELO_LEVEL" L3 >/dev/null; t_rc "switch to L3" 0 $?
t_eq "pf.conf updated to L3" "# L3 rules" "$(cat "$TMP/etc/pf.conf" 2>/dev/null)"
t_has "torrc template deployed" "$(cat "$TMP/etc/tor/torrc" 2>/dev/null)" "velo L3 template"

# 6. Switch L3 -> L1 (Tor cleaned up)
sh "$VELO_LEVEL" L1 >/dev/null; t_rc "switch to L1" 0 $?
t_eq "torrc template cleaned up" 0 "$(if [ -f "$TMP/etc/tor/torrc" ]; then echo 1; else echo 0; fi)"

# 7. Invalid mode check
set +e
sh "$VELO_LEVEL" L4 >/dev/null 2>&1; _rc=$?
set -e
t_rc "invalid mode L4 returns nonzero" 1 $_rc

# 8. Missing root check (when VELO_LEVEL_TEST and VELO_ROOT are unset)
unset VELO_LEVEL_TEST
unset VELO_ROOT
set +e
sh "$VELO_LEVEL" L2 >/dev/null 2>&1; _rc=$?
set -e
t_rc "running switch without root returns nonzero" 1 $_rc

# Summary
echo ""
if [ "$T_FAIL" -eq 0 ]; then
	echo "PASS: all $T_N assertions passed."
	exit 0
else
	echo "FAIL: $T_FAIL of $T_N assertions failed."
	exit 1
fi
