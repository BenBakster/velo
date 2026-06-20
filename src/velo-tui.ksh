# velo-tui.ksh -- sourceable TUI primitives for the velo OpenBSD installer.
#
# Target shell:  OpenBSD /bin/ksh (pdksh / oksh) inside the bsd.rd install
#                ramdisk.  Also runs UNMODIFIED under bash >= 3 on a
#                Void/Linux host for dry-run demos.
#
# This file is meant to be SOURCED, not executed:
#     . ./src/velo-tui.ksh        # POSIX dot, works in ksh and bash
#
# ---------------------------------------------------------------------------
# BOX STRATEGY:  ASCII  ( + - | )  with reverse-video SGR fills.
# ---------------------------------------------------------------------------
# Why not Unicode or DEC special-graphics line-drawing?  On the OpenBSD amd64
# bsd.rd VGA/glass console the in-kernel wscons VT100 emulator runs with the
# Spleen 8x16 ISO-8859-1 font (codepoints 32..255 only).  BOTH literal Unicode
# box-drawing (U+2500..) AND DEC special-graphics line-drawing (ESC(0) q x l k
# ...) decode to UCS codepoints >= U+2500, which are outside the font range, so
# rasops_mapchar() substitutes a literal '?'.  Result: a Unicode/DEC box would
# render as a wall of '?' on the default install console.  ASCII '+ - |' plus
# ANSI SGR colour (the "DOS blue box": blue background, white text, reverse-
# video highlight bar) is the ONLY approach that renders identically on the
# default VGA console AND over a serial console with an unknown emulator.
# See docs/constraints.md for sources.
#
# No tput / terminfo: neither exists in the ramdisk; all escape sequences are
# hardcoded for a vt100/vt220-class terminal (the installer's default TERM).
#
# No printf in the ramdisk EITHER (not a binary, not a pdksh builtin), and no
# `print` builtin in bash.  We therefore dispatch output through _put/_putln,
# which pick `print -rn --` when available (ramdisk) and fall back to
# `printf '%s'` (bash / full OpenBSD).  Do not call printf/print directly in
# widget code -- always go through _put/_putln/_goto.
# ---------------------------------------------------------------------------

# --- one-time capability detection -----------------------------------------

# ESC byte, built portably (printf is fine HERE because this assignment runs
# at source time; under bash printf exists, and we only need the byte value).
# In the ramdisk this expansion runs under ksh where $(printf ...) is unused
# because _put never calls printf -- but the ESC literal must still exist, so
# we build it with the most portable method available.
if ( print -rn -- "" ) >/dev/null 2>&1; then
	VELO_HAS_PRINT=1
else
	VELO_HAS_PRINT=0
fi

# Build the control-byte literals once, without relying on printf at runtime.
# The ramdisk has NEITHER printf NOR od NOR tr (verified against the crunchgen
# list, distrib/amd64/ramdisk_cd/list), so single-keypress decoding compares
# raw bytes against these precomputed literals rather than computing ordinals.
# pdksh `print` interprets backslash escapes; bash uses printf. Both are only
# used HERE, at source time, to materialise the literals.
_velo_lit() {  # _velo_lit '\033'  -> emit the decoded byte(s)
	if [ "$VELO_HAS_PRINT" = 1 ]; then
		print -rn -- "$(print -n "$1")"
	else
		printf '%b' "$1"
	fi
}
VELO_ESC=$(_velo_lit '\033')   # ESC  0x1b
VELO_CR=$(_velo_lit '\015')    # CR   0x0d
VELO_TAB=$(_velo_lit '\011')   # TAB  0x09
VELO_BS=$(_velo_lit '\010')    # BS   0x08
VELO_DEL=$(_velo_lit '\0177')  # DEL  0x7f  (leading 0: OpenBSD `print` only decodes \0nnn)
VELO_NL='
'                             # LF   0x0a (literal newline, no escape needed)

# Colour policy: honour NO_COLOR (https://no-color.org/) and non-tty output.
if [ -n "${NO_COLOR+x}" ] || [ "${VELO_COLOR:-auto}" = "off" ]; then
	VELO_USE_COLOR=0
elif [ "${VELO_COLOR:-auto}" = "on" ]; then
	VELO_USE_COLOR=1
elif [ -t 1 ]; then
	VELO_USE_COLOR=1
else
	VELO_USE_COLOR=0
fi

# --- low-level output primitives -------------------------------------------

# _put: write all args raw, NO trailing newline, NO escape interpretation.
_put() {
	if [ "$VELO_HAS_PRINT" = 1 ]; then
		print -rn -- "$*"
	else
		printf '%s' "$*"
	fi
}

# _putln: like _put but with a trailing newline.
_putln() {
	_put "$*"
	_put '
'
}

# _goto ROW COL: absolute cursor position (1-based). CSI row;colH.
_goto() {
	_put "${VELO_ESC}[${1};${2}H"
}

# --- SGR colour helpers (no-ops when colour is disabled) -------------------
#
# Palette ("DOS blue box"):
#   panel   : white text on blue background      (the box field)
#   title   : bold white on blue
#   bar      : reverse video (highlight/selection bar)
#   dim     : faint
#   reset   : back to default
#
# wsvt25/vt220 support 8 ANSI colours + reverse; we stick to those.

_sgr() {  # _sgr CODE...  -> emit ESC[CODEm if colour enabled
	[ "$VELO_USE_COLOR" = 1 ] || return 0
	_put "${VELO_ESC}[${1}m"
}

velo_reset()      { _sgr 0; }
velo_panel_on()   { _sgr '37;44'; }        # white on blue
velo_title_on()   { _sgr '1;37;44'; }      # bold white on blue
velo_bar_on()     { _sgr 7; }              # reverse video (selection)
velo_bar_off()    { _sgr 27; }             # reverse off
velo_dim_on()     { _sgr 2; }
velo_label_on()   { _sgr '1;33;44'; }      # bold yellow on blue (labels)
velo_danger_on()  { _sgr '1;37;41'; }      # bold white on RED (destroy gate)
velo_danger_off() { _sgr 0; }              # reset (back to default)

# --- screen control --------------------------------------------------------

velo_clear() {     # clear screen, home cursor (only meaningful on a tty)
	_put "${VELO_ESC}[2J${VELO_ESC}[H"
}

velo_hide_cursor() { _put "${VELO_ESC}[?25l"; }
velo_show_cursor() { _put "${VELO_ESC}[?25h"; }

# --- terminal state save / restore -----------------------------------------
#
# VELO_STTY_SAVED holds the opaque `stty -g` string.  tui_init MUST be balanced
# by tui_cleanup; an EXIT/INT/TERM trap guarantees the terminal is always put
# back even if the caller dies.  We never leave the tty in raw/-echo state.

VELO_STTY_SAVED=""
VELO_RAW_ACTIVE=0

tui_init() {
	# Drive raw mode against the CONTROLLING TERMINAL (/dev/tty) -- the same fd
	# _read1 reads from -- not stdin, which may be redirected (then [ -t 0 ] is
	# false yet a tty still exists). No controlling tty -> no-op, safe anywhere.
	#   -echo   : do not echo typed chars
	#   -icanon : non-canonical mode (deliver bytes without waiting for NL)
	#   min 1 time 0 : block until at least 1 byte, no inter-byte timeout
	if VELO_STTY_SAVED=$(stty -g </dev/tty 2>/dev/null); then
		stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
		VELO_RAW_ACTIVE=1
	else
		VELO_STTY_SAVED=""
	fi
	velo_hide_cursor
	# Restore on ANY exit path. INT/TERM re-raise after cleanup so the caller
	# still sees a non-zero status.
	trap 'tui_cleanup' EXIT
	trap 'tui_cleanup; trap - INT;  kill -INT  $$' INT
	trap 'tui_cleanup; trap - TERM; kill -TERM $$' TERM
}

tui_cleanup() {
	velo_show_cursor
	velo_reset
	if [ "$VELO_RAW_ACTIVE" = 1 ] && [ -n "$VELO_STTY_SAVED" ]; then
		stty "$VELO_STTY_SAVED" </dev/tty 2>/dev/null
		VELO_RAW_ACTIVE=0
	fi
	# Drop the EXIT trap so a normal return doesn't double-fire it.
	trap - EXIT
}

# --- single-keypress reader -------------------------------------------------
#
# pdksh has no `read -n1`/`read -k1`; bash has `read -n1` but NOT under pdksh.
# The portable primitive (verified against man.openbsd.org/stty, /dd) is:
#     stty -icanon min 1 time 0   (set once in tui_init)
#     dd if=/dev/tty bs=1 count=1
# Arrow keys are 3-byte sequences  ESC '[' A/B/C/D ; to disambiguate a lone
# ESC from the start of an arrow sequence we briefly switch to `min 0 time 1`
# (0.1s) for the continuation bytes, then restore `min 1 time 0`.
#
# The ramdisk has NO od and NO tr, so we cannot compute byte ordinals. Instead
# we read each byte with a trailing sentinel that SURVIVES command-substitution
# newline-stripping (so a CR or LF byte is not silently lost), then compare the
# byte against the precomputed control-byte literals (VELO_CR/VELO_NL/...).
#
#   _read1 emits: <byte>X    (the 'X' is the last char, so $() keeps it even
#                             when <byte> is a trailing newline)
#   the caller does  b=${_raw%X}  to recover the real byte (empty == true EOF).
#
# velo_readkey sets the global VELO_KEY to one of:
#   UP DOWN LEFT RIGHT  ENTER  SPACE  ESC  BACKSPACE  TAB  EOF
#   or the literal character typed (e.g. "a", "Y").

VELO_KEY=""

# _read1 -> "<byte>X" on stdout (sentinel-protected one-byte read).
_read1() {
	dd if=/dev/tty bs=1 count=1 2>/dev/null
	_put X
}

# _classify RAW (= "<byte>X") -> set VELO_KEY for a NON-escape byte.
_classify() {
	_cl=${1%X}
	case "$_cl" in
	"")           VELO_KEY="EOF" ;;
	"$VELO_NL")   VELO_KEY="ENTER" ;;
	"$VELO_CR")   VELO_KEY="ENTER" ;;
	"$VELO_TAB")  VELO_KEY="TAB" ;;
	"$VELO_BS")   VELO_KEY="BACKSPACE" ;;
	"$VELO_DEL")  VELO_KEY="BACKSPACE" ;;
	" ")          VELO_KEY="SPACE" ;;
	*)            VELO_KEY="$_cl" ;;
	esac
}

velo_readkey() {
	VELO_KEY=""
	_raw=$(_read1)
	_c=${_raw%X}
	if [ "$_c" = "$VELO_ESC" ]; then
		# Possible arrow / function key. Look for continuation bytes with a
		# short timeout so a bare ESC doesn't hang.
		[ "$VELO_RAW_ACTIVE" = 1 ] && stty min 0 time 1 </dev/tty 2>/dev/null
		_raw2=$(_read1); _c2=${_raw2%X}
		if [ "$_c2" = "[" ] || [ "$_c2" = "O" ]; then
			_raw3=$(_read1); _c3=${_raw3%X}
			[ "$VELO_RAW_ACTIVE" = 1 ] && stty min 1 time 0 </dev/tty 2>/dev/null
			case "$_c3" in
			A) VELO_KEY="UP" ;;
			B) VELO_KEY="DOWN" ;;
			C) VELO_KEY="RIGHT" ;;
			D) VELO_KEY="LEFT" ;;
			*) VELO_KEY="ESC" ;;
			esac
		else
			[ "$VELO_RAW_ACTIVE" = 1 ] && stty min 1 time 0 </dev/tty 2>/dev/null
			VELO_KEY="ESC"
		fi
		return 0
	fi
	_classify "$_raw"
	# A true EOF (no tty / closed stdin) is reported as EOF so callers can break
	# out instead of spinning. Widgets treat EOF like ESC/cancel.
	return 0
}

# --- geometry / drawing helpers --------------------------------------------

# _repeat CHAR N -> string of CHAR repeated N times.
_repeat() {
	_rc_ch=$1; _rc_n=$2; _rc_out=""
	while [ "$_rc_n" -gt 0 ]; do
		_rc_out="${_rc_out}${_rc_ch}"
		_rc_n=$((_rc_n - 1))
	done
	_put "$_rc_out"
}

# _pad STR WIDTH -> STR right-padded with spaces to WIDTH (truncates if longer).
_pad() {
	_pd_s=$1; _pd_w=$2
	_pd_len=${#_pd_s}
	if [ "$_pd_len" -ge "$_pd_w" ]; then
		# truncate
		_put "$(_substr "$_pd_s" 0 "$_pd_w")"
	else
		_put "$_pd_s"
		_repeat ' ' $((_pd_w - _pd_len))
	fi
}

# _substr STR START LEN -> substring.  NOTE: ${var:off:len} is a BASHISM that
# does NOT exist in OpenBSD pdksh/oksh (the ramdisk shell) -- there it raises a
# runtime "bad substitution" (and silently diverges from the bash demo, where it
# works).  We implement substring with portable ${var#?}/${var%...} char peeling,
# which behaves identically in pdksh/oksh and bash.  All current call sites pass
# START=0, but START is honoured for completeness; negative args clamp to 0.
_substr() {
	_ss=$1; _st=$2; _sl=$3
	[ "$_st" -lt 0 ] && _st=0
	[ "$_sl" -lt 0 ] && _sl=0
	while [ "$_st" -gt 0 ] && [ -n "$_ss" ]; do
		_ss=${_ss#?}; _st=$((_st - 1))
	done
	_sub_out=""
	while [ "${#_sub_out}" -lt "$_sl" ] && [ -n "$_ss" ]; do
		_sub_out="$_sub_out${_ss%"${_ss#?}"}"
		_ss=${_ss#?}
	done
	_put "$_sub_out"
}

# --- tui_box X Y W H [TITLE] -----------------------------------------------
#
# Draw an ASCII box at absolute position (1-based X=col, Y=row) of width W and
# height H, with an optional TITLE on the top border. The interior is painted
# with the blue panel colour. On a non-tty (screenshot) context, _goto strings
# are harmless and the box still reads correctly line-by-line.

tui_box() {
	_bx=$1; _by=$2; _bw=$3; _bh=$4; _btitle=${5:-}
	[ "$_bw" -lt 2 ] && _bw=2
	[ "$_bh" -lt 2 ] && _bh=2
	_inner=$((_bw - 2))

	velo_panel_on
	# top border with optional title
	_goto "$_by" "$_bx"
	if [ -n "$_btitle" ]; then
		_t=" $_btitle "
		_tlen=${#_t}
		[ "$_tlen" -gt "$_inner" ] && { _t=$(_substr "$_t" 0 "$_inner"); _tlen=$_inner; }
		_put "+"
		velo_title_on; _put "$_t"; velo_panel_on
		_repeat '-' $((_inner - _tlen))
		_put "+"
	else
		_put "+"; _repeat '-' "$_inner"; _put "+"
	fi
	# body rows
	_r=1
	while [ "$_r" -lt $((_bh - 1)) ]; do
		_goto $((_by + _r)) "$_bx"
		_put "|"; _repeat ' ' "$_inner"; _put "|"
		_r=$((_r + 1))
	done
	# bottom border
	_goto $((_by + _bh - 1)) "$_bx"
	_put "+"; _repeat '-' "$_inner"; _put "+"
	velo_reset
}

# --- tui_label X Y TEXT -----------------------------------------------------
tui_label() {
	_goto "$2" "$1"
	velo_label_on
	_put "$3"
	velo_reset
}

# _text_at X Y TEXT : plain panel-coloured text at a position.
_text_at() {
	_goto "$2" "$1"
	velo_panel_on
	_put "$3"
	velo_reset
}

# --- tui_menu : single-select, arrow navigable -----------------------------
#
# Usage:  tui_menu X Y WIDTH TITLE ITEM1 ITEM2 ...
# Sets VELO_MENU_INDEX (0-based) to the chosen item, returns 0; returns 1 and
# sets VELO_MENU_INDEX=-1 if the user pressed ESC (cancel).

VELO_MENU_INDEX=-1

tui_menu() {
	_mx=$1; _my=$2; _mw=$3; _mtitle=$4
	shift 4
	# Capture items into positional-stable variables.
	_mcount=$#
	_i=0
	for _it in "$@"; do
		eval "_MENU_$_i=\$_it"
		_i=$((_i + 1))
	done
	_msel=0
	_mh=$((_mcount + 2))

	tui_box "$_mx" "$_my" "$_mw" "$_mh" "$_mtitle"
	while :; do
		_i=0
		while [ "$_i" -lt "$_mcount" ]; do
			eval "_label=\$_MENU_$_i"
			_goto $((_my + 1 + _i)) $((_mx + 1))
			if [ "$_i" = "$_msel" ]; then
				velo_panel_on; velo_bar_on
				_put " > "; _pad "$_label" $((_mw - 5));
				velo_bar_off; velo_reset
			else
				velo_panel_on
				_put "   "; _pad "$_label" $((_mw - 5))
				velo_reset
			fi
			_i=$((_i + 1))
		done
		velo_readkey
		case "$VELO_KEY" in
		UP)    _msel=$(( _msel > 0 ? _msel - 1 : _mcount - 1 )) ;;
		DOWN)  _msel=$(( _msel < _mcount - 1 ? _msel + 1 : 0 )) ;;
		ENTER) VELO_MENU_INDEX=$_msel; return 0 ;;
		ESC|EOF)   VELO_MENU_INDEX=-1; return 1 ;;
		esac
	done
}

# --- tui_checklist : multi-select, space toggles ---------------------------
#
# Usage:  tui_checklist X Y WIDTH TITLE ITEM1 ITEM2 ...
# Sets VELO_CHECKED to a space-separated list of selected 0-based indices.
# ENTER confirms (returns 0), ESC cancels (returns 1, VELO_CHECKED="").

VELO_CHECKED=""

tui_checklist() {
	_cx=$1; _cy=$2; _cw=$3; _ctitle=$4
	shift 4
	_ccount=$#
	_i=0
	for _it in "$@"; do
		eval "_CHK_$_i=\$_it"
		eval "_CHKON_$_i=0"
		_i=$((_i + 1))
	done
	_csel=0
	_ch=$((_ccount + 2))

	tui_box "$_cx" "$_cy" "$_cw" "$_ch" "$_ctitle"
	while :; do
		_i=0
		while [ "$_i" -lt "$_ccount" ]; do
			eval "_label=\$_CHK_$_i"
			eval "_on=\$_CHKON_$_i"
			if [ "$_on" = 1 ]; then _mark="[x]"; else _mark="[ ]"; fi
			_goto $((_cy + 1 + _i)) $((_cx + 1))
			if [ "$_i" = "$_csel" ]; then
				velo_panel_on; velo_bar_on
				_put " $_mark "; _pad "$_label" $((_cw - 7))
				velo_bar_off; velo_reset
			else
				velo_panel_on
				_put " $_mark "; _pad "$_label" $((_cw - 7))
				velo_reset
			fi
			_i=$((_i + 1))
		done
		velo_readkey
		case "$VELO_KEY" in
		UP)    _csel=$(( _csel > 0 ? _csel - 1 : _ccount - 1 )) ;;
		DOWN)  _csel=$(( _csel < _ccount - 1 ? _csel + 1 : 0 )) ;;
		SPACE)
			eval "_on=\$_CHKON_$_csel"
			if [ "$_on" = 1 ]; then eval "_CHKON_$_csel=0"; else eval "_CHKON_$_csel=1"; fi
			;;
		ENTER)
			VELO_CHECKED=""
			_i=0
			while [ "$_i" -lt "$_ccount" ]; do
				eval "_on=\$_CHKON_$_i"
				[ "$_on" = 1 ] && VELO_CHECKED="$VELO_CHECKED $_i"
				_i=$((_i + 1))
			done
			VELO_CHECKED=${VELO_CHECKED# }
			return 0
			;;
		ESC|EOF)   VELO_CHECKED=""; return 1 ;;
		esac
	done
}

# --- tui_radio : single-select with radio markers --------------------------
#
# Usage:  tui_radio X Y WIDTH TITLE ITEM1 ITEM2 ...
# Like tui_menu but shows (*)/( ) markers. Sets VELO_RADIO_INDEX.

VELO_RADIO_INDEX=-1

tui_radio() {
	_rx=$1; _ry=$2; _rw=$3; _rtitle=$4
	shift 4
	_rcount=$#
	_i=0
	for _it in "$@"; do
		eval "_RAD_$_i=\$_it"
		_i=$((_i + 1))
	done
	_rsel=0
	_rh=$((_rcount + 2))

	tui_box "$_rx" "$_ry" "$_rw" "$_rh" "$_rtitle"
	while :; do
		_i=0
		while [ "$_i" -lt "$_rcount" ]; do
			eval "_label=\$_RAD_$_i"
			if [ "$_i" = "$_rsel" ]; then _mark="(*)"; else _mark="( )"; fi
			_goto $((_ry + 1 + _i)) $((_rx + 1))
			if [ "$_i" = "$_rsel" ]; then
				velo_panel_on; velo_bar_on
				_put " $_mark "; _pad "$_label" $((_rw - 7))
				velo_bar_off; velo_reset
			else
				velo_panel_on
				_put " $_mark "; _pad "$_label" $((_rw - 7))
				velo_reset
			fi
			_i=$((_i + 1))
		done
		velo_readkey
		case "$VELO_KEY" in
		UP)    _rsel=$(( _rsel > 0 ? _rsel - 1 : _rcount - 1 )) ;;
		DOWN)  _rsel=$(( _rsel < _rcount - 1 ? _rsel + 1 : 0 )) ;;
		ENTER) VELO_RADIO_INDEX=$_rsel; return 0 ;;
		ESC|EOF)   VELO_RADIO_INDEX=-1; return 1 ;;
		esac
	done
}

# --- tui_input : single-line text field ------------------------------------
#
# Usage:  tui_input X Y WIDTH PROMPT [DEFAULT]
# Reads a line of text with basic editing (BACKSPACE). ENTER confirms, ESC
# cancels. Sets VELO_INPUT to the entered text; returns 1 on ESC.

VELO_INPUT=""

tui_input() {
	_ix=$1; _iy=$2; _iw=$3; _iprompt=$4; _ival=${5:-}
	_ifield=$((_iw - ${#_iprompt} - 1))
	[ "$_ifield" -lt 4 ] && _ifield=4
	# Clamp an over-long DEFAULT to the visible field, so the cursor math stays in
	# the box and ENTER never returns more than what was shown/editable.
	_ival=$(_substr "$_ival" 0 "$_ifield")

	while :; do
		_goto "$_iy" "$_ix"
		velo_panel_on
		_put "$_iprompt "
		velo_bar_on
		_pad "$_ival" "$_ifield"
		velo_bar_off
		velo_reset
		# place cursor after current text (visual nicety on a tty)
		_curcol=$((_ix + ${#_iprompt} + 1 + ${#_ival}))
		_goto "$_iy" "$_curcol"
		velo_readkey
		case "$VELO_KEY" in
		ENTER) VELO_INPUT="$_ival"; return 0 ;;
		ESC|EOF)   VELO_INPUT=""; return 1 ;;
		BACKSPACE)
			[ -n "$_ival" ] && _ival=${_ival%?}
			;;
		SPACE) [ ${#_ival} -lt "$_ifield" ] && _ival="$_ival " ;;
		UP|DOWN|LEFT|RIGHT|TAB) : ;;
		*)
			# Append printable single chars only (length 1).
			if [ ${#VELO_KEY} -eq 1 ] && [ ${#_ival} -lt "$_ifield" ]; then
				_ival="$_ival$VELO_KEY"
			fi
			;;
		esac
	done
}

# --- tui_password : masked input -------------------------------------------
#
# Usage:  tui_password X Y WIDTH PROMPT
# Reads a secret WITHOUT echoing it. The secret is returned via the global
# VELO_PASSWORD ONLY (never written to a temp file, never passed as argv, never
# echoed). Displays '*' per character. ENTER confirms; ESC cancels (returns 1
# and clears VELO_PASSWORD). The caller is responsible for clearing
# VELO_PASSWORD after consuming it (e.g. piping into bioctl -s).

VELO_PASSWORD=""

tui_password() {
	_px=$1; _py=$2; _pw=$3; _pprompt=$4
	_pfield=$((_pw - ${#_pprompt} - 1))
	[ "$_pfield" -lt 4 ] && _pfield=4
	_secret=""
	_mask=""

	while :; do
		_goto "$_py" "$_px"
		velo_panel_on
		_put "$_pprompt "
		velo_bar_on
		_pad "$_mask" "$_pfield"
		velo_bar_off
		velo_reset
		velo_readkey
		case "$VELO_KEY" in
		ENTER) VELO_PASSWORD="$_secret"; _secret=""; return 0 ;;
		ESC|EOF)   VELO_PASSWORD=""; _secret=""; return 1 ;;
		BACKSPACE)
			if [ -n "$_secret" ]; then
				# Pure parameter expansion -- NO subshell fork, so the plaintext
				# secret never crosses a $() boundary (xtrace / ps-leak safe).
				_secret=${_secret%?}
				_mask=${_mask%?}
			fi
			;;
		SPACE)
			if [ ${#_secret} -lt "$_pfield" ]; then
				_secret="$_secret "
				_mask="$_mask*"
			fi
			;;
		UP|DOWN|LEFT|RIGHT|TAB) : ;;
		*)
			if [ ${#VELO_KEY} -eq 1 ] && [ ${#_secret} -lt "$_pfield" ]; then
				_secret="$_secret$VELO_KEY"
				_mask="$_mask*"
			fi
			;;
		esac
	done
}

# --- tui_spinner : show a spinner while a process runs ----------------------
#
# Usage:  tui_spinner PID MESSAGE [ROW COL]
# Runs a spinner in a loop while the PID process is running.
tui_spinner() {
	_sp_pid=$1
	_sp_msg=$2
	_sp_row=${3:-}
	_sp_col=${4:-}
	_sp_idx=0

	velo_hide_cursor
	while kill -0 "$_sp_pid" 2>/dev/null; do
		case "$_sp_idx" in
		0) _sp_char='|' ;;
		1) _sp_char='/' ;;
		2) _sp_char='-' ;;
		3) _sp_char='\' ;;
		esac

		if [ -n "$_sp_row" ] && [ -n "$_sp_col" ]; then
			_goto "$_sp_row" "$_sp_col"
		fi

		velo_panel_on
		_put "${_sp_msg} [ ${_sp_char} ]"
		velo_reset

		_sp_idx=$(( (_sp_idx + 1) % 4 ))
		sleep 0.2
	done

	# Clean up spinner text
	if [ -n "$_sp_row" ] && [ -n "$_sp_col" ]; then
		_goto "$_sp_row" "$_sp_col"
	fi
	velo_panel_on
	_repeat ' ' $(( ${#_sp_msg} + 6 ))
	velo_reset
	velo_show_cursor
}

# --- tui_msgbox : message box, dismissed with any key ----------------------
#
# Usage:  tui_msgbox X Y WIDTH TITLE LINE1 [LINE2 ...]
# Each remaining arg is one body line.

tui_msgbox() {
	_gx=$1; _gy=$2; _gw=$3; _gtitle=$4
	shift 4
	_glines=$#
	_gh=$((_glines + 4))   # title border + lines + blank + prompt + bottom

	tui_box "$_gx" "$_gy" "$_gw" "$_gh" "$_gtitle"
	_row=1
	for _ln in "$@"; do
		_text_at $((_gx + 2)) $((_gy + _row)) "$(_substr "$_ln" 0 $((_gw - 4)))"
		_row=$((_row + 1))
	done
	_goto $((_gy + _gh - 2)) $((_gx + 2))
	velo_dim_on; velo_panel_on
	_put "[ press any key ]"
	velo_reset
	# Wait for any key (only when interactive).
	if [ -t 0 ]; then
		velo_readkey
	fi
	return 0
}

# --- tui_confirm : Yes/No dialog -------------------------------------------
#
# Usage:  tui_confirm X Y WIDTH TITLE QUESTION
# LEFT/RIGHT or arrow keys move between [ Yes ]/[ No ]; ENTER confirms.
# Returns 0 for Yes, 1 for No/ESC.

tui_confirm() {
	_qx=$1; _qy=$2; _qw=$3; _qtitle=$4; _qtext=$5
	_qh=5
	_qyes=1   # default highlight = Yes

	tui_box "$_qx" "$_qy" "$_qw" "$_qh" "$_qtitle"
	_text_at $((_qx + 2)) $((_qy + 1)) "$(_substr "$_qtext" 0 $((_qw - 4)))"
	while :; do
		_goto $((_qy + 3)) $((_qx + 2))
		velo_panel_on
		if [ "$_qyes" = 1 ]; then
			velo_bar_on; _put "[ Yes ]"; velo_bar_off
			_put "   "
			_put "[ No ]"
		else
			_put "[ Yes ]"
			_put "   "
			velo_bar_on; _put "[ No ]"; velo_bar_off
		fi
		velo_reset
		velo_readkey
		case "$VELO_KEY" in
		LEFT|UP)    _qyes=1 ;;
		RIGHT|DOWN) _qyes=0 ;;
		TAB)        _qyes=$(( _qyes == 1 ? 0 : 1 )) ;;
		y|Y)        return 0 ;;
		n|N)        return 1 ;;
		ENTER)      [ "$_qyes" = 1 ] && return 0 || return 1 ;;
		ESC|EOF)    return 1 ;;
		esac
	done
}
