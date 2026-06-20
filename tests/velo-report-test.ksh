#!/bin/ksh
# tests/velo-report-test.ksh -- unit tests for velo-report diagnostic bundle.

set -e

# Locate the repo root from THIS test file (tests/ is one level down).
case "$0" in
*/*) _T_HERE=${0%/*} ;;
*)   _T_HERE=. ;;
esac
REPO=$(cd "$_T_HERE/.." && pwd)
VELO_REPORT="$REPO/site/usr/local/bin/velo-report"
VELO_EGRESS="$REPO/site/usr/local/bin/velo-egress-test"

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

t_hasnt() {  # t_hasnt LABEL HAYSTACK NEEDLE
	T_N=$((T_N + 1))
	case "$2" in
	*"$3"*) echo "FAIL $1 (UNEXPECTED: [$3])"; T_FAIL=$((T_FAIL + 1)) ;;
	*) echo "ok   $1" ;;
	esac
}

echo "=== velo-report diagnostic tests ==="

# 1. Setup mock prefix environment
TMP=$(mktemp -d "${TMPDIR:-/tmp}/velo-report-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/etc/velo" "$TMP/var/log/tor" "$TMP/etc/tor"
cat > "$TMP/etc/velo/answers" <<ANS
schema=1
profile=terminal
startmode=L3
pkgs=ripgrep jq
hostname=velo-terminal
encrypt=yes
wifi_ssid=MyHomeWiFi
wifi_psk=SuperSecretPassphraseWPAKey
ANS

# Create a mock ifconfig output with real MAC address
cat > "$TMP/etc/ifconfig.mock" <<INF
em0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	lladdr 00:1c:42:bd:6d:0b
	index 1 priority 0 llprio 3
	groups: egress
	media: Ethernet autoselect (1000baseT full-duplex,master)
	status: active
	inet 10.211.55.5 netmask 0xffffff00 broadcast 10.211.55.255
INF

# Create mock Tor log
echo "Bootstrapped 100% (done)" > "$TMP/var/log/tor/log"
echo "# Mock pf" > "$TMP/etc/pf.conf"

# Export VELO_ROOT so velo-report runs in mock sandbox
export VELO_ROOT="$TMP"

# 2. Run velo-report
_report=$(sh "$VELO_REPORT")

# Check answers included
t_has "report includes answers profile" "$_report" "profile=terminal"
t_has "report includes answers startmode" "$_report" "startmode=L3"

# Verify credentials (wifi_psk/passphrase) are REDACTED
t_has "report redacts wifi_psk value" "$_report" "wifi_psk=[REDACTED]"
t_hasnt "report does not leak secret WPA key" "$_report" "SuperSecretPassphraseWPAKey"

# Verify MAC address is redacted
t_has "report redacts MAC address" "$_report" "lladdr 00:1c:42:xx:xx:xx"
t_hasnt "report does not leak raw MAC address" "$_report" "bd:6d:0b"

# Verify master.passwd path is never mentioned or accessed
t_hasnt "master.passwd is not read" "$_report" "root:*"

# 3. Egress test mock execution
_egress_l3=$(sh "$VELO_EGRESS")
t_has "egress test passes under dry-run mock L3" "$_egress_l3" "ALL PASS"

# Switch startmode to L2
sed 's/startmode=L3/startmode=L2/' "$TMP/etc/velo/answers" > "$TMP/etc/velo/answers.tmp"
mv "$TMP/etc/velo/answers.tmp" "$TMP/etc/velo/answers"

_egress_l2=$(sh "$VELO_EGRESS")
t_has "egress test skips under dry-run mock L2" "$_egress_l2" "skipped (startmode is L2, not L3)"

# Summary
echo ""
if [ "$T_FAIL" -eq 0 ]; then
	echo "PASS: all $T_N assertions passed."
	exit 0
else
	echo "FAIL: $T_FAIL of $T_N assertions failed."
	exit 1
fi
