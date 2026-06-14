# velo-rd-hook.sh -- velo ramdisk launcher.
#
# WHERE THIS RUNS
# ---------------------------------------------------------------------------
# This file is INJECTED into the patched bsd.rd as /velo-rd-hook.sh by
# build/build-velo.sh.  At install time it is SOURCED from the ramdisk
# /.profile: build-velo SPLICES the two-line snippet in build/dot.profile.hook
# into /.profile on the line ABOVE the stock interactive menu loop (anchored on
# its `while :; do` header), so this hook runs BEFORE the menu's first
# `read REPLY` -- velo owns the console first.  It executes under the ramdisk
# /bin/ksh.  Authored to ALSO parse clean under the host oksh/bash:
#     /usr/sbin/ksh -n build/velo-rd-hook.sh
#     bash          -n build/velo-rd-hook.sh
# (docs/m3-design.md s2; docs/constraints.md s6.)
#
# CONTRACT WITH THE STOCK dot.profile
# ---------------------------------------------------------------------------
#   - We do NOT replace the stock menu.  We run the velo wizard FIRST (an
#     *around* wrap, not a replacement).  Because this file is SOURCED (not
#     exec'd) from a point ABOVE the menu loop, when it RETURNS control flows
#     straight into the still-pending stock menu loop -- the (I)nstall /
#     (U)pgrade / (A)utoinstall / (S)hell prompt then runs its first
#     `read REPLY`, exactly as on a stock image.
#   - ESC / cancel inside the wizard FALLS THROUGH to that stock menu, so a
#     human can always reach the plain OpenBSD installer or a shell.
#   - NO auto_install.conf is involved -- the menu's 5s autoinstall timeout is
#     never armed.  This file is sourced interactively, on a real tty.
#
# SAFETY POSTURE
# ---------------------------------------------------------------------------
#   - The destructive install path inside velo-install is reached ONLY after
#     the summary Ворота-СТОП is confirmed (tui_confirm default-No; per
#     docs/m3-requirements.md).  Until that gate, nothing writes.
#   - A non-tty context (rare) falls straight through to the stock flow rather
#     than driving a wizard with no keyboard.
#   - We tell velo-install where its TUI library lives via VELO_TUI: in the
#     ramdisk both files are at '/', so the M1 repo-relative source path does
#     not apply.  velo-install honours this override (see velo-install s
#     "source-time"); on the host (tests) VELO_TUI is unset and the
#     repo-relative path is used unchanged.

# Only engage on a real tty (the ramdisk console / serial).  When sourced from
# /.profile, `return` is the correct way to hand control back; if for some
# reason this file is run non-sourced, fall back to `exit`.  The
# `2>/dev/null || ...` pair makes the line valid whether `return` is legal in
# the current context or not.
[ -t 0 ] || return 0 2>/dev/null || exit 0

# Point velo-install at the flat ramdisk layout (both files live in /).
VELO_TUI=/velo-tui.ksh
export VELO_TUI

# ARM the destructive execute path.  This is the ONLY place VELO_ALLOW_EXECUTE is
# set to yes, and it is shipped INSIDE the patched bsd.rd of the real install
# medium -- so velo-install can perform a real install when (and only when)
# booted from that medium.  On the host / in tests / in `plan` mode this variable
# is UNSET, so velo_execute is INERT (returns 2, writes nothing).  Arming here
# does NOT bypass the human gate: velo_execute still requires the operator to
# type the EXACT target disk name (default-No, m3-requirements) before a single
# destructive token runs.
VELO_ALLOW_EXECUTE=yes
export VELO_ALLOW_EXECUTE

# Run the wizard.  velo-install drives the 7-screen TUI and, only past the
# confirmed Ворота-СТОП, performs the real install (in the VM / on real disk).
/velo-install
_velo_rc=$?

# rc 0   -> velo handled the flow (installed, or the user fell through inside).
# rc !=0 -> ESC / cancel / no-tty: say so and let /.profile's stock (I)/(U)/(S)
#           menu take over.  A cancel ALWAYS lands the operator at the stock
#           menu or shell -- velo never traps the console.
if [ "$_velo_rc" -ne 0 ]; then
	echo "velo: not completed (rc=$_velo_rc) -- dropping to the stock OpenBSD installer menu."
fi
unset _velo_rc

# Hand control back to the rest of /.profile (the stock menu).  Same
# return/exit fallback as above.
return 0 2>/dev/null || true
