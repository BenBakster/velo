#!/bin/sh
# velo homely: openbox + tint2 session (xenodm).
# Fallback to xterm if the offline closure is incomplete.
. "$HOME/.velo-xkb" 2>/dev/null

export LANG=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8

if [ -n "${VELO_XKB_LAYOUTS:-}" ]; then
	setxkbmap -layout "$VELO_XKB_LAYOUTS" -option "${VELO_XKB_TOGGLE:-grp:shift_alt_toggle}" &
fi

xrdb -merge "$HOME/.Xdefaults" 2>/dev/null
xsetroot -solid '#1d2021'
xset b off
xset r rate 250 40

if command -v tint2 >/dev/null 2>&1; then
	tint2 &
fi

if command -v openbox >/dev/null 2>&1; then
	exec openbox
fi
exec xterm