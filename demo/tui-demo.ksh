#!/bin/ksh
# tui-demo.ksh -- harness/demo for the velo TUI primitives.
#
# Runs under OpenBSD /bin/ksh AND under bash (Void/Linux dry-run).
#
# Modes:
#   tui-demo.ksh                 interactive walk-through (needs a real tty)
#   tui-demo.ksh screenshot      render STATIC frames of every widget to
#                                stdout, NO raw mode, NO input read -- safe to
#                                pipe / capture in a non-tty context.
#
# The screenshot mode does NOT call tui_init (so the tty is never touched) and
# never calls velo_readkey. It composites each widget (box border + interior)
# in a single top-to-bottom pass so the capture is faithful on a pipe, where
# absolute cursor addressing is meaningless. The interactive mode uses the
# library's real absolute-positioned widgets.

# Locate and source the library relative to this script. `dirname` is NOT in
# the install ramdisk, so derive the directory with parameter expansion only.
case "$0" in
*/*) _here=${0%/*} ;;   # strip trailing /name
*)   _here=. ;;         # no slash -> current dir
esac
. "$_here/../src/velo-tui.ksh"

# ===========================================================================
# Screenshot helpers: pure line-oriented compositors. They reuse the library's
# colour helpers and padding but emit complete lines (border + content) so the
# output reads correctly when captured to a non-tty stream.
# ===========================================================================

# repeated string -> stdout (no globals)
_ss_repeat() {
	_r_ch=$1; _r_n=$2; _r_out=""
	while [ "$_r_n" -gt 0 ]; do _r_out="${_r_out}${_r_ch}"; _r_n=$((_r_n - 1)); done
	_put "$_r_out"
}

# top/bottom border of width W, with optional TITLE on the top one.
_ss_border() {  # W [TITLE]
	_b_w=$1; _b_title=${2:-}
	_b_inner=$((_b_w - 2))
	velo_panel_on
	if [ -n "$_b_title" ]; then
		_b_t=" $_b_title "
		_b_len=${#_b_t}
		[ "$_b_len" -gt "$_b_inner" ] && { _b_t=$(_substr "$_b_t" 0 "$_b_inner"); _b_len=$_b_inner; }
		_put "+"
		velo_title_on; _put "$_b_t"; velo_panel_on
		_ss_repeat '-' $((_b_inner - _b_len))
		_put "+"
	else
		_put "+"; _ss_repeat '-' "$_b_inner"; _put "+"
	fi
	velo_reset
	_putln ""
}

# one interior content row: "| <content padded to inner> |"
_ss_row() {  # W RAW_CONTENT_ALREADY_SIZED
	_w_w=$1; _w_c=$2
	velo_panel_on
	_put "|"; _pad "$_w_c" $((_w_w - 2)); _put "|"
	velo_reset
	_putln ""
}

# blank interior row
_ss_blank() { _ss_row "$1" ""; }

# titled empty box (tui_box demo)
_ss_box() {  # W H TITLE
	_x_w=$1; _x_h=$2; _x_t=$3
	_ss_border "$_x_w" "$_x_t"
	_r=1
	while [ "$_r" -lt $(($2 - 1)) ]; do _ss_blank "$_x_w"; _r=$((_r + 1)); done
	_ss_border "$_x_w"
}

# menu: SELIDX then items. Selected row shown with reverse bar + " > ".
_ss_menu() {  # W TITLE SELIDX ITEM...
	_m_w=$1; _m_t=$2; _m_sel=$3
	shift 3
	_ss_border "$_m_w" "$_m_t"
	_i=0
	for _label in "$@"; do
		velo_panel_on; _put "|"
		if [ "$_i" = "$_m_sel" ]; then
			velo_bar_on; _put " > "; _pad "$_label" $((_m_w - 5)); velo_bar_off
		else
			_put "   "; _pad "$_label" $((_m_w - 5))
		fi
		velo_panel_on; _put "|"; velo_reset
		_putln ""
		_i=$((_i + 1))
	done
	_ss_border "$_m_w"
}

# checklist: SELIDX, CHECKMASK (space-sep checked indices), items.
_ss_checklist() {  # W TITLE SELIDX CHECKMASK ITEM...
	_c_w=$1; _c_t=$2; _c_sel=$3; _c_mask=$4
	shift 4
	_ss_border "$_c_w" "$_c_t"
	_i=0
	for _label in "$@"; do
		case " $_c_mask " in
		*" $_i "*) _mk="[x]" ;;
		*)         _mk="[ ]" ;;
		esac
		velo_panel_on; _put "|"
		if [ "$_i" = "$_c_sel" ]; then
			velo_bar_on; _put " $_mk "; _pad "$_label" $((_c_w - 7)); velo_bar_off
		else
			_put " $_mk "; _pad "$_label" $((_c_w - 7))
		fi
		velo_panel_on; _put "|"; velo_reset
		_putln ""
		_i=$((_i + 1))
	done
	_ss_border "$_c_w"
}

# radio: SELIDX, items.
_ss_radio() {  # W TITLE SELIDX ITEM...
	_d_w=$1; _d_t=$2; _d_sel=$3
	shift 3
	_ss_border "$_d_w" "$_d_t"
	_i=0
	for _label in "$@"; do
		if [ "$_i" = "$_d_sel" ]; then _mk="(*)"; else _mk="( )"; fi
		velo_panel_on; _put "|"
		if [ "$_i" = "$_d_sel" ]; then
			velo_bar_on; _put " $_mk "; _pad "$_label" $((_d_w - 7)); velo_bar_off
		else
			_put " $_mk "; _pad "$_label" $((_d_w - 7))
		fi
		velo_panel_on; _put "|"; velo_reset
		_putln ""
		_i=$((_i + 1))
	done
	_ss_border "$_d_w"
}

# input box: PROMPT and sample TEXT inside a 1-row box.
# interior = 1(lead space) + len(prompt)+1(space) + field + 1(trail space)
_ss_input() {  # W TITLE PROMPT TEXT
	_n_w=$1; _n_t=$2; _n_p=$3; _n_x=$4
	_ss_border "$_n_w" "$_n_t"
	_field=$((_n_w - 2 - 1 - (${#_n_p} + 1) - 1))
	[ "$_field" -lt 4 ] && _field=4
	velo_panel_on; _put "| "
	_put "$_n_p "
	velo_bar_on; _pad "$_n_x" "$_field"; velo_bar_off
	velo_panel_on; _put " |"; velo_reset
	_putln ""
	_ss_border "$_n_w"
}

# password box: PROMPT and NCHARS mask inside a 1-row box.
_ss_password() {  # W TITLE PROMPT NCHARS
	_w_w=$1; _w_t=$2; _w_p=$3; _w_n=$4
	_ss_border "$_w_w" "$_w_t"
	_field=$((_w_w - 2 - 1 - (${#_w_p} + 1) - 1))
	[ "$_field" -lt 4 ] && _field=4
	_mask=""; _k=$_w_n; while [ "$_k" -gt 0 ]; do _mask="$_mask*"; _k=$((_k - 1)); done
	velo_panel_on; _put "| "
	_put "$_w_p "
	velo_bar_on; _pad "$_mask" "$_field"; velo_bar_off
	velo_panel_on; _put " |"; velo_reset
	_putln ""
	_ss_border "$_w_w"
}

# msgbox: title + body lines + hint.
_ss_msgbox() {  # W TITLE LINE...
	_g_w=$1; _g_t=$2
	shift 2
	_ss_border "$_g_w" "$_g_t"
	for _ln in "$@"; do
		_ss_row "$_g_w" " $(_substr "$_ln" 0 $((_g_w - 4)))"
	done
	_ss_blank "$_g_w"
	_ss_row "$_g_w" " [ press any key ]"
	_ss_border "$_g_w"
}

# confirm: question + [ Yes ] highlighted / [ No ].
_ss_confirm() {  # W TITLE QUESTION
	_q_w=$1; _q_t=$2; _q_q=$3
	_ss_border "$_q_w" "$_q_t"
	_ss_row "$_q_w" " $(_substr "$_q_q" 0 $((_q_w - 4)))"
	_ss_blank "$_q_w"
	velo_panel_on; _put "| "
	velo_bar_on; _put "[ Yes ]"; velo_bar_off
	_put "   [ No ]"
	# interior width = _q_w - 2 ; already emitted: 1(space)+7+3+6 = 17
	_used=$(( 1 + 7 + 3 + 6 ))
	_pad "" $(( (_q_w - 2) - _used ))
	_put "|"; velo_reset
	_putln ""
	_ss_border "$_q_w"
}

_frame() { _putln ""; _putln "=== $1 ==="; _putln ""; }

# ===========================================================================
screenshot() {
	# Plain ASCII capture by default; VELO_COLOR=on keeps SGR codes.
	if [ "${VELO_COLOR:-auto}" != "on" ]; then
		VELO_USE_COLOR=0
	fi

	_frame "tui_box (titled box)"
	_ss_box 40 5 "velo installer"

	_frame "tui_menu (item 2 highlighted)"
	_ss_menu 40 "Main Menu" 1 \
		"Quick install (recommended)" \
		"Custom install" \
		"Full-disk encryption setup" \
		"Drop to shell"

	_frame "tui_checklist (2 items checked)"
	_ss_checklist 40 "Optional sets" 0 "1 3" \
		"base (required)" \
		"X11 (xbase, xfont, xserv)" \
		"games" \
		"comp (compiler/headers)"

	_frame "tui_radio (option 1 selected)"
	_ss_radio 40 "Keyboard layout" 0 "us" "uk" "de" "ru"

	_frame "tui_input (sample text)"
	_ss_input 44 "Hostname" "hostname:" "velo-bsd"

	_frame "tui_password (masked)"
	_ss_password 44 "Disk encryption" "passphrase:" 12

	_frame "tui_msgbox"
	_ss_msgbox 44 "Notice" \
		"softraid CRYPTO volume created" \
		"attached as sd1 -- continuing"

	_frame "tui_confirm (Yes highlighted)"
	_ss_confirm 44 "Confirm" "Encrypt the root disk with a passphrase?"

	_putln ""
	_putln "[screenshot complete]"
}

# ===========================================================================
# Interactive walk-through (real terminal): uses the library's live widgets.
# ===========================================================================
interactive() {
	if [ ! -t 0 ] || [ ! -t 1 ]; then
		echo "tui-demo: interactive mode needs a real terminal." >&2
		echo "Try:  $0 screenshot" >&2
		return 1
	fi
	tui_init
	velo_clear

	tui_msgbox 4 2 50 "velo" \
		"Welcome to the velo TUI demo." \
		"This walks through every widget." \
		"Use arrows, space, enter; ESC cancels."

	velo_clear
	tui_menu 4 2 44 "Main Menu" \
		"Quick install (recommended)" \
		"Custom install" \
		"Full-disk encryption setup" \
		"Drop to shell"
	_choice=$VELO_MENU_INDEX

	velo_clear
	tui_checklist 4 2 44 "Optional sets" \
		"base (required)" \
		"X11 (xbase, xfont, xserv)" \
		"games" \
		"comp (compiler/headers)"
	_sets=$VELO_CHECKED

	velo_clear
	tui_radio 4 2 44 "Keyboard layout" "us" "uk" "de" "ru"
	_kbd=$VELO_RADIO_INDEX

	velo_clear
	tui_box 4 2 50 3 "Hostname"
	tui_input 6 3 46 "hostname:" "velo-bsd"
	_host=$VELO_INPUT

	velo_clear
	tui_box 4 2 50 3 "Disk encryption"
	tui_password 6 3 46 "passphrase:"
	# VELO_PASSWORD holds the secret here; a real installer pipes it straight
	# into `bioctl -s -c C ...` then clears it. We never display it.
	_passlen=${#VELO_PASSWORD}
	VELO_PASSWORD=""

	velo_clear
	if tui_confirm 4 2 50 "Confirm" "Proceed with these settings?"; then
		_ans="yes"
	else
		_ans="no"
	fi

	tui_cleanup
	velo_clear
	echo "Demo summary (no secrets shown):"
	echo "  menu index : $_choice"
	echo "  sets       : ${_sets:-none}"
	echo "  keyboard   : $_kbd"
	echo "  hostname   : ${_host:-<cancelled>}"
	echo "  passphrase : ${_passlen} chars entered"
	echo "  confirmed  : $_ans"
}

# ===========================================================================
case "${1:-interactive}" in
screenshot)  screenshot ;;
interactive) interactive ;;
*)
	echo "usage: $0 [screenshot|interactive]" >&2
	exit 2
	;;
esac
