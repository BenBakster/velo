# M3 / M4 requirements & carried notes

## Carried from M1 review (safety for the destructive path)
- **tui_confirm must default to "No" for the destructive Ворота-СТОП.** In M1 the
  summary reuses tui_confirm which defaults the highlight to "Yes" (harmless: M1
  only PRINTS). Before M3 wires the real install, add an optional default-button
  arg to tui_confirm (or a `tui_confirm_dangerous` variant) defaulting to No, and
  ideally require typing a word (cf. the harden-gui `KEEP` pattern) to proceed.
- **Disk list >12:** _wiz_disk now WARNS to stderr (no silent cap). If a real
  target ever exceeds the viewport, add prev/next paging or a manual-entry escape.

## M3 build tasks (authored at M3-prep; EXECUTED only in the OpenBSD VM)
1. `build/build-velo.sh` — patch a 7.9 `bsd.rd`:
   gunzip -> `rdsetroot -x bsd.rd disk.fs` -> `vnconfig disk.fs` -> mount ->
   inject `src/velo-tui.ksh` + `src/velo-install` -> **hook `/.profile`** (the
   install ramdisk menu entry, built from distrib/miniroot/dot.profile) to run
   velo-install before/around the stock installer -> umount -> `vnconfig -u` ->
   `rdsetroot bsd.rd disk.fs` -> gzip. `rdsetroot -s bsd.rd` prints the size ceiling.
   DO NOT drop `auto_install.conf` (it arms a 5s timeout that bypasses the menu).
2. Place `site79.tgz` (from M2) on the install media alongside base79.tgz etc.
3. Fresh **OpenBSD 7.9 VM from install79.iso** as build host (also a control run
   of the stock installer).
4. Test-boot the patched image in qemu/VBox against a BLANK virtual disk; run the
   full encrypted install end-to-end IN THE VM.

## M4 — HARD STOP (not done autonomously)
- Writing the produced image to the real external SSD (TOSHIBA External / sda)
  would destroy the Void-portable install. Only with Anton present.
