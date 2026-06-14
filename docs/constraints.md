# velo — verified constraints (M0)

Digest of the verified findings the TUI implementation relies on. Each item
cites a real source (OpenBSD man pages, the OpenBSD source tree, FAQ, or a
reference bsd.rd-patch project). Findings marked **UNVERIFIED** must be
confirmed in the OpenBSD 7.9 VM at M3.

---

## 1. Shell and userland in the bsd.rd install ramdisk

- The installer runs under **`/bin/ksh`** — OpenBSD's public-domain Korn shell
  (pdksh/oksh lineage). `install.sub` begins `#!/bin/ksh`; `/bin/sh` is a hard
  link to the same crunchgen'd `instbin`.
  - <https://man.openbsd.org/ksh.1>
  - <https://github.com/openbsd/src/blob/master/distrib/miniroot/install.sub>
- **Present** in the crunch: `ksh`, `stty`, `dd`, `sed`, `cat`, `sleep` (plus
  disk/net tools, `tar`, `pax`, `signify`, etc.).
  - <https://github.com/openbsd/src/blob/master/distrib/amd64/ramdisk_cd/list>
- **ABSENT** from the crunch (must not be used at runtime):
  `printf`, `head`, `tail`, `tput`, `tic`, `infocmp`, `tset`, `od`, `tr`,
  `expr`, `dirname`, `basename`, `awk`.
  - `printf` is *also not a ksh builtin* on OpenBSD — there is no printf at all
    in the ramdisk.
  - <https://github.com/openbsd/src/blob/master/distrib/amd64/ramdisk_cd/list>
  - <https://man.openbsd.org/ksh.1>
- ksh **builtins** a script may rely on: `print` (`-r` raw, `-n` no-newline,
  `-u` fd), `echo`, `read`, `test`/`[`, `let`, `(( ))`, `typeset`, `case`,
  `[[ ]]`, parameter expansion, `trap`.
  - <https://man.openbsd.org/ksh.1>

**Implication for velo:** all formatted output goes through `_put`/`_putln`,
which use the **`print`** builtin on the ramdisk and fall back to `printf` only
on bash (where `print` does not exist). No `tput`/`terminfo`; all escape
sequences are hardcoded. No `od`/`tr` for byte inspection — control bytes are
matched against precomputed literals.

---

## 2. Console rendering — box-drawing capability

- The amd64 glass/VGA console is the in-kernel **wscons VT100/VT220 emulator**.
  ANSI SGR colours and CSI cursor positioning work.
  - <https://man.openbsd.org/wscons.4>
- Default console font is **Spleen 8x16, ISO-8859-1** (codepoints 32..255
  only) — no glyphs above U+00FF.
  - <https://raw.githubusercontent.com/openbsd/src/master/sys/dev/wsfont/spleen8x16.h>
- The VT100 emulator maps **DEC special-graphics line-drawing** (`ESC(0)`
  `q x l k m j n`) to UCS codepoints **>= U+2500**, the same range as Unicode
  box-drawing.
  - <https://raw.githubusercontent.com/openbsd/src/master/sys/dev/wscons/wsemul_vt100_chars.c>
- `rasops_mapchar()` substitutes a literal **`?`** for any codepoint outside
  the active font's range. So on the default console **both** Unicode box-
  drawing **and** DEC line-drawing render as `?`.
  - <https://raw.githubusercontent.com/openbsd/src/master/sys/dev/rasops/rasops.c>
  - Corroborated by ExoticSilicon's console-code analysis and a misc@ thread
    from an OpenBSD console contributor:
    <https://research.exoticsilicon.com/articles/unbreaking_utf8_on_the_console>,
    <https://www.mail-archive.com/misc@openbsd.org/msg190775.html>
- `wsvt25`/`vt220` termcap entries advertise `colors#8` + `cup` but have **no
  `acsc`** (line-drawing) string.
  - <https://raw.githubusercontent.com/openbsd/src/master/share/termtypes/termtypes.master>
- Over a **serial** console the remote emulator renders the bytes, so UTF-8/DEC
  *might* work — but cannot be assumed for an unknown client.

**Implication for velo -> box_strategy = ASCII.** Boxes use `+ - |`; the "DOS
blue box" look comes from ANSI SGR colour (white-on-blue panel) and reverse-
video (`ESC[7m`) selection bars, not from any line-drawing glyph. This renders
identically on the default VGA console and over serial.

---

## 3. `$TERM` and escape sequences

- `install.sub` sets `export TERM=${TERM:-${MDTERM:-vt220}}`; amd64 has no
  `MDTERM`, so the default is **`vt220`**. The console is ISO-8859-1 single-byte
  by default (UTF-8 is opt-in via `ESC % G`).
  - <https://github.com/openbsd/src/blob/master/distrib/miniroot/install.sub>
  - <https://man.openbsd.org/wscons.4>

**Implication:** hardcode vt100/vt220-class CSI/SGR sequences. Sequences used:
`ESC[2J`/`ESC[H` (clear/home), `ESC[r;cH` (cursor position),
`ESC[?25l`/`ESC[?25h` (hide/show cursor), `ESC[Nm` (SGR colour/attributes).

---

## 4. Single-keypress / arrow-key reading

- pdksh `read` has **no** `-n`/`-N`/`-k`/`-t`. The portable primitive is
  `stty` + `dd`:
  - `stty -echo -icanon min 1 time 0` then `dd if=/dev/tty bs=1 count=1`.
  - `head -c1` does **not** work (OpenBSD `head` has no `-c`).
  - <https://man.openbsd.org/ksh.1>, <https://man.openbsd.org/stty.1>,
    <https://man.openbsd.org/dd.1>, <https://man.openbsd.org/head.1>
- Arrow keys are 3-byte sequences `ESC [ A/B/C/D`. To distinguish a lone `ESC`
  from the start of an arrow, switch to `stty min 0 time 1` (0.1 s) for the
  continuation bytes, then restore `min 1 time 0`.
- `stty -g` saves the opaque state; restore with `stty "$saved"`. `stty -raw`
  does **not** restore prior state.
  - <https://man.openbsd.org/stty.1>

**Implication:** `velo_readkey` reads one byte at a time via `dd`. Because the
ramdisk lacks `od`/`tr`, control bytes (CR/LF/TAB/BS/DEL/ESC) are compared
against literals built once at source time, and a trailing sentinel `X` is
appended to each read so command-substitution does not strip a trailing
newline byte.

---

## 5. softraid CRYPTO full-disk encryption (used by later milestones)

- Non-interactive creation: `bioctl -s` reads the passphrase from `/dev/stdin`
  with no prompt/confirm:
  `print -r -- "$PASS" | bioctl -s -c C -l /dev/sdNa softraid0`
  (the installer uses `bioctl -Cforce -cC -l${chunk}a -s softraid0`).
  - <https://man.openbsd.org/bioctl.8>
  - <https://github.com/openbsd/src/blob/master/distrib/miniroot/install.sub>
    (`encrypt_root()`, `get_softraid_volumes()`)
- Preceding steps: `fdisk -iy sdN`; `disklabel` a single **RAID**-type
  partition; after attach, `dd if=/dev/zero of=/dev/rsdMc bs=1m count=1`.
  - <https://www.openbsd.org/faq/faq14.html>
- The CRYPTO volume takes the **next free `sd` unit** — parse `bioctl softraid0`
  output, never hardcode the number.

**Implication for the TUI:** `tui_password` returns the secret via the
`VELO_PASSWORD` global only — never a temp file, never argv — so the caller can
pipe it straight into `bioctl -s` and then clear the variable.

---

## 6. Delivery / hook point (later milestones)

- There is **no `install.sh`**. The installer is `install.sub`; `/install`,
  `/upgrade`, `/autoinstall` are symlinks to it (mode chosen from `$0`).
  - <https://github.com/openbsd/src/blob/master/distrib/miniroot/install.sub>
  - <https://github.com/openbsd/src/blob/master/distrib/amd64/ramdisk_cd/list>
- The interactive menu lives in **`/.profile`** (built from
  `distrib/miniroot/dot.profile`). That is the hook point for a custom TUI.
  Do **not** drop `auto_install.conf` for an interactive flow — it arms a 5 s
  timeout that bypasses the menu.
  - <https://raw.githubusercontent.com/openbsd/src/master/distrib/miniroot/dot.profile>
- Repack cycle: `gunzip` -> `rdsetroot -x bsd.rd disk.fs` -> `vnd=$(vnconfig
  disk.fs)` -> `mount /dev/${vnd}a /mnt` -> edit -> `umount` / `vnconfig -u` ->
  `rdsetroot bsd.rd disk.fs` -> `gzip`. `rdsetroot -s bsd.rd` prints the hard
  size ceiling.
  - <https://man.openbsd.org/rdsetroot>, <https://man.openbsd.org/vnconfig>
  - <https://github.com/echothrust/openbsd-patchrd>
- Post-install config: ship `site79.tgz` (extracted last); an executable
  `/install.site` runs chrooted at end of install (no network — defer
  `pkg_add` from a mirror to `/etc/rc.firsttime` via `>>`).
  - <https://man.openbsd.org/install.site.5>, <https://www.openbsd.org/faq/faq4.html>

---

## UNVERIFIED — must confirm in the OpenBSD 7.9 VM at M3

1. **Exact 7.9 ramdisk contents.** All crunch-list facts above are from the
   `master` branch `distrib/amd64/ramdisk_cd/list`. The list is historically
   stable, but the byte-exact 7.9 set should be confirmed by unpacking the
   shipped `bsd.rd` (`rdsetroot -x` -> `vnconfig` -> `mount` -> `ls /bin /sbin
   /usr/bin /usr/sbin /dev`). In particular re-confirm the absence of
   `od`/`tr`/`dirname`/`printf` and the presence of `dd`/`stty`/`sed`.
2. **Real wscons rendering of our exact escape sequences** (SGR `37;44`, `7`,
   cursor hide/show `?25l`/`?25h`, `ESC[r;cH`) on the 7.9 glass console — read
   from source/termcap, not yet observed on a live 7.9 console.
3. **`dd if=/dev/tty bs=1 count=1` latency / behaviour on the wscons keyboard**
   (wskbd0) under the ramdisk — verified to work under a Linux PTY in M0; the
   `min 0 time 1` arrow-disambiguation timing should be eyeballed on real
   hardware/VM where `dd` per-byte spawn cost differs.
4. **`stty -g` round-trip on the ramdisk tty** (`ttyC0`/`tty00`) — the
   save/restore string format is OpenBSD-native, but the exact ramdisk tty was
   tested only under a Linux PTY in M0.
5. Whether the 7.9 reserved ramdisk size (`rdsetroot -s`) leaves room to add
   the velo scripts in place, or whether the RAMDISK kernel must be rebuilt.
