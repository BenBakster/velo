# velo M3 — build & test flow design (`bsd.rd` patch + media + VM runbook)

Status: design (Ворота-3 input). Implements the **M3** milestone from `PLAN.md`
and the carried items in `docs/m3-requirements.md`. M3-prep **AUTHORS** the build
and test scripts; it does **not** execute the destructive path. The only
device-writing step (dd image → external SSD) is **M4** and MUST NOT run
autonomously (it would destroy the Void-portable on `sda`).

**WHERE THINGS RUN (the hard split this whole doc rests on):**
- The Void/Linux host (this machine) has **NO** `rdsetroot`/`vnconfig`/`vmd`/
  `VBoxManage`-against-OpenBSD-kernels. It can **author** and `ksh -n`/`bash -n`
  **lint** the scripts only.
- `build/build-velo.sh` and `build/write-usb.sh` **RUN inside the OpenBSD 7.9 VM**
  (or on real OpenBSD). Every OpenBSD command below is grounded in its man page or
  a reference `bsd.rd`-patch project (echothrust/openbsd-patchrd,
  ezaquarii/openbsd-autoinstall). They are linted on the host, executed in the VM.
- Real `oksh` on the host = `/usr/sbin/ksh`. The build script targets the **VM's**
  `/bin/ksh` but is authored to also parse-clean under the host's `oksh`/`bash`
  (same rule as M1/M2).

**Grounding (man pages / projects), cited inline below and collected in §10:**
`rdsetroot(8)`, `vnconfig(8)`, `mount(8)`/`umount(8)`, `disklabel(8)`,
`install.sub` + `dot.profile` (miniroot), `autoinstall(8)`, `vmctl(8)`/`vmd(8)`,
`cdio(1)`/`cd(4)` install-media layout, `pfctl(8)`, `doas(1)`, `pkg_add(1)`,
echothrust/openbsd-patchrd, ezaquarii/openbsd-autoinstall.

---

## 0. M3 deliverables (authored at M3-prep; EXECUTED only in the OpenBSD VM)

| # | artifact | runs where | autonomous? |
|---|----------|-----------|-------------|
| 1 | `build/build-velo.sh` | OpenBSD 7.9 VM | yes (file images only) |
| 2 | `build/velo-rd-hook.sh` | injected INTO `bsd.rd`; runs in ramdisk at install | n/a (shipped) |
| 3 | `build/assemble-media.sh` | OpenBSD 7.9 VM | yes (file images only) |
| 4 | `build/write-usb.sh` (**M4**) | OpenBSD VM **or** host, ANTON PRESENT | **NO — hard stop** |
| 5 | `docs/m3-runbook.md` content (this doc §6) | the operator follows it | manual |

All of #1–#3 operate **only on file images** (`bsd.rd`, `disk.fs`, a copy of
`install79.img`) — never a raw device node. #4 is the single dd-to-device script
and is the M4 hard stop.

---

## 1. `build/build-velo.sh` — patch a 7.9 `bsd.rd`

### 1.1 What it produces

Input:  a pristine 7.9 `bsd.rd` (extracted from `install79.iso`/`.img`, or fetched
from a 7.9 mirror under `pub/OpenBSD/7.9/amd64/bsd.rd`).
Output: `dist/bsd.rd.velo` — a gzip'd ramdisk kernel byte-identical to stock
**except** that its embedded root filesystem now carries:
- `/velo-tui.ksh`         (from `src/velo-tui.ksh`)
- `/velo-install`         (from `src/velo-install`, mode 0755)
- `/velo-rd-hook.sh`      (the ramdisk-side launcher, §2)
- a one-line **append** to `/.profile` that sources the hook (§2)

It changes nothing else: same kernel, same `instbin` crunch, same `install.sub`.

### 1.2 The repack cycle (grounded in constraints §6, patchrd projects)

`bsd.rd` is a kernel with a **compressed** ramdisk image (`disk.fs`, a UFS/FFS
filesystem) embedded in its `.rd_root_image` section. The cycle is the one in
`docs/constraints.md` §6, made concrete:

```sh
#!/bin/ksh
# build/build-velo.sh -- patch a 7.9 bsd.rd with the velo TUI + /.profile hook.
# RUNS IN THE OpenBSD 7.9 VM (needs rdsetroot, vnconfig, mount, disklabel).
# Operates ONLY on file images; never a raw device.  Authored here, linted on
# the host with `ksh -n`; executed only in the VM.
set -eu

RD_IN=${1:?usage: build-velo.sh <pristine-bsd.rd> [out]}
RD_OUT=${2:-dist/bsd.rd.velo}
WORK=$(mktemp -d /tmp/velo-rd.XXXXXX)
FS="$WORK/disk.fs"
MNT="$WORK/mnt"
mkdir -p "$MNT"

# Clean up on ANY exit: unmount, detach vnd, drop the workdir.  vnd id is
# captured into VND once configured; the trap tolerates an empty VND.
VND=""
cleanup() {
    [ -n "$VND" ] && umount "$MNT" 2>/dev/null || true
    [ -n "$VND" ] && vnconfig -u "$VND" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# 1. Work on a COPY so the pristine bsd.rd is never mutated.
cp "$RD_IN" "$WORK/bsd.rd"

# 2. bsd.rd ships gzip'd.  Decompress in place (mv so we keep the .rd name).
#    `file bsd.rd` on a stock image reports gzip; rdsetroot needs the
#    uncompressed kernel.  gzip -dc -> a plain kernel ELF with the rd section.
if gzip -t "$WORK/bsd.rd" 2>/dev/null; then
    gzip -dc "$WORK/bsd.rd" > "$WORK/bsd.rd.raw"
else
    cp "$WORK/bsd.rd" "$WORK/bsd.rd.raw"   # already uncompressed (rare)
fi

# 3. SIZE CEILING: rdsetroot -s prints the reserved rd_root_image size (bytes).
#    This is the hard ceiling -- the patched disk.fs must be <= this or the
#    write-back fails / corrupts.  We capture it BEFORE extracting so we can
#    refuse early if our additions would overflow.  (constraints UNVERIFIED #5)
CEIL=$(rdsetroot -s "$WORK/bsd.rd.raw")        # bytes; man rdsetroot(8) -s
echo "velo: rd_root_image ceiling = $CEIL bytes"

# 4. EXTRACT the embedded filesystem image out of the kernel.
#    rdsetroot -x <kernel> <fsfile>  copies the rd section OUT to fsfile.
rdsetroot -x "$WORK/bsd.rd.raw" "$FS"          # man rdsetroot(8) -x

# 5. ATTACH the fs image to a vnd(4) pseudo-device (FILE image, not a disk).
#    vnconfig prints the assigned vnd name (e.g. vnd0) -- capture it, never
#    hardcode (man vnconfig(8)).
VND=$(vnconfig "$FS")                           # e.g. "vnd0"

# 6. MOUNT the ramdisk fs read-write.  The rd image is a single FFS 'a' slice;
#    mount /dev/${VND}a.  (patchrd: mount -t ffs /dev/vnd0a /mnt)
mount /dev/"${VND}"a "$MNT"

# 7. INJECT the velo files.  install(1) sets owner/mode atomically.
install -o root -g wheel -m 0644 src/velo-tui.ksh   "$MNT/velo-tui.ksh"
install -o root -g wheel -m 0755 src/velo-install    "$MNT/velo-install"
install -o root -g wheel -m 0755 build/velo-rd-hook.sh "$MNT/velo-rd-hook.sh"

# 8. HOOK /.profile -- INSERT one guarded source line just ABOVE the stock
#    interactive menu loop (see §2.2).  Never clobber the stock dot.profile, and
#    do NOT append after its closing `fi` (that runs only after the operator has
#    left the menu -- too late to wrap it).  Anchor on the menu loop header
#    `while :; do`; refuse if absent.  Sentinel-guarded so a re-run is idempotent.
HOOK_MARK="# --- velo hook (injected by build-velo) ---"
if ! grep -qF -- "$HOOK_MARK" "$MNT/.profile"; then
    grep -qE '^[[:space:]]*while :; do' "$MNT/.profile" || \
        { echo "velo: no menu-loop anchor in /.profile -- refusing to hook" >&2; exit 1; }
    awk -v mark="$HOOK_MARK" '
        !done && /^[[:space:]]*while :; do/ {
            print mark; print ". /velo-rd-hook.sh"; print ""; done = 1
        }
        { print }
    ' "$MNT/.profile" > "$MNT/.profile.velo.$$"
    grep -qF -- "$HOOK_MARK" "$MNT/.profile.velo.$$" || \
        { echo "velo: hook splice produced no marker -- aborting" >&2; exit 1; }
    cat "$MNT/.profile.velo.$$" > "$MNT/.profile"; rm -f "$MNT/.profile.velo.$$"
fi

# 9. Optional sanity: the ramdisk really is the install ramdisk (has install.sub
#    and dot.profile-derived /.profile), and we did NOT drop auto_install.conf.
[ -f "$MNT/install.sub" ] || { echo "velo: not an install ramdisk?" >&2; exit 1; }
[ -e "$MNT/auto_install.conf" ] && { echo "velo: REFUSING -- auto_install.conf present (would arm 5s timeout)" >&2; exit 1; }

# 10. UNMOUNT + DETACH cleanly (order matters: umount before vnconfig -u).
sync
umount "$MNT"
vnconfig -u "$VND"; VND=""

# 11. SIZE CHECK before write-back: the (possibly grown) fs image must still fit
#     the kernel's reserved rd section.  If it overflows, FAIL LOUDLY (the fix is
#     to rebuild the RAMDISK kernel with a bigger image -- a separate, larger task
#     flagged in constraints UNVERIFIED #5; v0.1 expects our few-KB additions to
#     fit the slack the stock rd carries).
FSZ=$(wc -c < "$FS")
if [ "$FSZ" -gt "$CEIL" ]; then
    echo "velo: FS image $FSZ B > ceiling $CEIL B -- will not fit. Rebuild RAMDISK kernel." >&2
    exit 1
fi
echo "velo: patched fs $FSZ B fits ceiling $CEIL B (slack $((CEIL - FSZ)) B)"

# 12. WRITE the patched fs back INTO the kernel's rd section.
#     rdsetroot <kernel> <fsfile>  copies fsfile IN (the inverse of -x).
rdsetroot "$WORK/bsd.rd.raw" "$FS"             # man rdsetroot(8) (no -x)

# 13. RE-COMPRESS to the shipped gzip form and emit.
mkdir -p "$(dirname "$RD_OUT")"
gzip -9 -c "$WORK/bsd.rd.raw" > "$RD_OUT"
echo "velo: wrote $RD_OUT"
```

**Why each grounded choice:**
- **`rdsetroot -s` for the ceiling.** `rdsetroot(8)`: `-s` prints the size of the
  reserved `rd_root_image` without modifying anything. This is the only honest way
  to know the in-place budget before we grow the fs. Captured *first*, checked
  *before* write-back (constraints UNVERIFIED #5).
- **`rdsetroot -x` to extract, plain `rdsetroot` to insert.** Per the man page and
  echothrust/openbsd-patchrd, `-x` copies the rd image *out*; the default form
  copies an fs file *in*. We operate on a **copy** of the kernel so a failed run
  never corrupts the source.
- **gzip decompress/recompress around it.** Shipped `bsd.rd` is gzip'd;
  `rdsetroot` needs the raw kernel. `gzip -t` detects the format so the script is
  robust to an already-raw input.
- **`vnconfig` on a FILE, capture the assigned unit.** `vnconfig(8)` attaches a
  *regular file* as a block device; it prints the unit it chose. We never hardcode
  `vnd0` (another build may already hold it). The trap detaches it on any exit.
- **`mount /dev/${VND}a`.** The install rd is one FFS partition `a`. patchrd uses
  exactly `mount -t ffs /dev/vnd0a`.
- **`install(1)` for the injects** sets owner `root:wheel` and the mode in one
  atomic step — `velo-install` 0755 (executed), the library + hook 0644/0755.
- **INSERT above the menu loop, never clobber `/.profile`** with a sentinel
  guard — splice the source line on the line *above* the stock `while :; do`
  menu loop (anchored on that header; refuse if absent), so velo runs FIRST,
  *around* the menu, and on cancel control RETURNS into the still-pending stock
  menu. Appending after the closing `fi` would run only after the operator had
  already left the menu — too late to wrap it. The sentinel makes the patch
  idempotent (re-running build-velo does not double-insert). Mirrors the M2
  install.site sentinel-guard idiom; see §2.2 for the anchor rationale.
- **Refuse if `auto_install.conf` exists** — the one bright-line constraints rule
  (it arms a 5 s timeout that bypasses the interactive menu). The build *asserts*
  it is absent rather than ever creating it.
- **File-images only.** `vnconfig` is pointed at `$FS` (a temp file); `dd` to a
  device never appears in this script. That property is what makes build-velo
  safe to run autonomously in the VM.

### 1.3 Host-side lint (what M3-prep can do NOW, no OpenBSD)

`ksh -n build/build-velo.sh` and `bash -n build/build-velo.sh` (and the host
`/usr/sbin/ksh -n`). A grep-assert that the script contains **no** `dd ... of=/dev/`
and **no** `auto_install.conf` *creation* (only the refuse-guard). These run on
the Void host; everything that needs `rdsetroot`/`vnconfig` is **FLAGGED verify in
the 7.9 VM (M3)**.

---

## 2. The `/.profile` hook — run velo-install around the stock menu, NO auto_install.conf

### 2.1 Why `/.profile` and not `install.sub` or `auto_install.conf`

- **No `install.sh`.** The installer is `install.sub`; `/install`, `/upgrade`,
  `/autoinstall` are symlinks to it (mode chosen from `$0`). We do not edit
  `install.sub` — it is the crunchgen'd userland's central script and editing it
  is fragile across versions (constraints §6).
- **The interactive menu lives in `/.profile`** (built from
  `distrib/miniroot/dot.profile`). The stock `dot.profile` (rev 1.52) drives the
  choice with a `while :; do read REPLY?'(I)nstall, (U)pgrade, (A)utoinstall or
  (S)hell? ' ... done` loop, inside an `if [[ -z $DONEPROFILE ]]; then ... fi`
  block. That loop is the documented hook point (constraints §6); velo splices
  in just **above** its header `while :; do` (see §2.2).
- **`auto_install.conf` is forbidden.** Dropping it arms a 5 s timeout that
  bypasses the interactive menu — the opposite of an interactive TUI. We never
  create it; build-velo §1.2 step 9 *refuses* if it is present.

### 2.2 The hook launcher (`build/velo-rd-hook.sh`, injected as `/velo-rd-hook.sh`)

**Where the line is inserted, and the anchor.** build-velo does **not** append
`. /velo-rd-hook.sh` after the stock `dot.profile`'s closing `fi`. The menu loop
exits the *enclosing block* via `&& break` on a successful `(I)/(U)/(A)`, so
anything after `fi` runs only once the operator has already left the menu — too
late to wrap it. Instead build-velo **splices** the two-line snippet
(`build/dot.profile.hook`) onto the line **above** the menu loop, anchored on its
header:

```
	while :; do
		read REPLY?'(I)nstall, (U)pgrade, (A)utoinstall or (S)hell? '
		...
	done
```

It matches `^[[:space:]]*while :; do` (one tab in the stock file), inserts the
hook block immediately before that line via a single-pass `awk`, and **refuses**
if the anchor is absent (unexpected layout). Why `while :; do` is the stable
anchor: it is the **one structurally invariant feature** of the installer menu
across releases. The prompt wording (`(A)utoinstall` was added; `com0`/serial
text varies), the autoinstall-timeout block above it, and the `case $REPLY`
arms below it have all changed between versions — but the menu has always been a
`while :; do ... read REPLY ... done` loop. Anchoring on the loop header (not on
volatile prompt text) is what keeps the insertion robust. Result: the velo
launcher runs **before** the loop's first `read REPLY`, so velo owns the console
first; on ESC/cancel/non-tty the hook RETURNS and that first `read REPLY` runs
exactly as on a stock image, so `(I)/(U)/(A)/(S)` stay reachable.

The injected `/.profile` line is `. /velo-rd-hook.sh`. The launcher decides
whether to show the velo TUI and how to hand off to the stock `install`:

```sh
# /velo-rd-hook.sh -- velo ramdisk launcher, sourced from /.profile on the line
# ABOVE the stock `while :; do` install menu loop.  Runs under the ramdisk
# /bin/ksh.  Authored to also parse-clean under host oksh/bash (ksh -n / bash -n).
#
# CONTRACT with the stock dot.profile:
#   - We do NOT replace the stock menu; we run the velo wizard FIRST.  If the
#     operator completes it, velo performs the real install and then we let the
#     ramdisk drop to the (S)hell prompt (the stock menu still appears, idle).
#   - ESC/cancel at the welcome screen FALLS THROUGH to the stock menu, so a
#     human can always reach the plain OpenBSD installer or a shell.
#   - No auto_install.conf is involved: the menu's 5s autoinstall timeout is
#     never armed.  This file is sourced interactively, on a real tty.
#
# SAFETY: in M3 the wizard is no longer DRY-RUN (it writes to disk in the VM).
# The destructive path is reached ONLY after the summary Ворота-СТОП is confirmed
# (tui_confirm default-No, per m3-requirements).  Until that gate, nothing writes.

# Only engage on a real tty (the ramdisk console / serial).  A non-tty (rare)
# falls straight through to the stock flow.
[ -t 0 ] || return 0 2>/dev/null || exit 0

# Run the wizard.  velo-install sources /velo-tui.ksh via its own ${0%/*} logic;
# here both live in / so that resolves to /velo-tui.ksh.
/velo-install
_rc=$?

# rc 0  -> velo handled the install (or user chose to fall through inside it).
# rc !=0 (ESC/cancel/no-tty) -> say so and let /.profile's stock menu take over.
if [ "$_rc" -ne 0 ]; then
    echo "velo: cancelled -- dropping to the stock OpenBSD installer menu."
fi
return 0 2>/dev/null || true
```

- **Sourced, not exec'd**, from a point *above* the menu loop, so when it
  returns control flows straight into the still-pending stock menu loop (the
  `(I)/(U)/(A)/(S)` prompt's first `read REPLY`) — a true *around* wrap, not a
  replacement. A cancel always lands the operator at the stock menu/shell.
- **`return`-with-`exit`-fallback** so it works whether `/.profile` sources it in
  a context where `return` is legal (it is, since `.` sources it).
- The path resolution inside `velo-install` (`case "$0" in */*) ...`) already
  derives `VELO_HERE=.` when run as `/velo-install` (no slash after the leading
  one? — `$0` is `/velo-install`, which *does* match `*/*`, so `VELO_HERE=""`,
  giving the source path `"/../src/velo-tui.ksh"`). **This is the one wiring change
  M3 makes to `velo-install`'s harness** (see §2.3).

### 2.3 The single M3 wiring change to `velo-install` (flagged, minimal)

`src/velo-install` is frozen as the M1 DRY-RUN. M3 turns it into the real
installer. Two surgical changes, both **authored at M3-prep, behaviour confirmed
in the VM**:

1. **Source path when living in `/`.** In the ramdisk both files are at `/`, so
   the M1 line `. "$VELO_HERE/../src/velo-tui.ksh"` must become tolerant of the
   flat layout. Cleanest: have the hook/launcher set `VELO_TUI=/velo-tui.ksh` and
   `velo-install` honour an override:
   ```sh
   : "${VELO_TUI:=$VELO_HERE/../src/velo-tui.ksh}"
   . "$VELO_TUI"
   ```
   On the host (tests) `VELO_TUI` is unset → the repo-relative path (unchanged
   behaviour, existing tests pass). In the ramdisk the hook exports
   `VELO_TUI=/velo-tui.ksh`. **No test breakage; one env seam.**
2. **DRY-RUN → real execute, gated.** The M1 `velo_wizard` ends by *printing* the
   plan. M3 adds, **after the summary Ворота-СТОП returns Yes**, the real steps:
   write `/mnt/etc/velo/answers` (the M2 contract, m2-design §2.3 writer), run the
   `plan_crypto` sequence for real (when encrypt=yes), write `install.conf` to the
   path the ramdisk `install` reads, and invoke `install`. This is the milestone's
   core risk surface; every destructive token stays **behind** the confirmed gate,
   and `tui_confirm` for that gate defaults to **No** and ideally requires typing a
   word (m3-requirements carried item; cf. the harden-gui `KEEP` pattern).

**Both changes are FLAGGED `verify in the 7.9 VM (M3)`**; M3-prep authors them and
extends `tests/velo-install-test.ksh` to cover the new `VELO_TUI` override and the
default-No gate, but the real `install`/`bioctl` only runs in the VM.

---

## 3. Media assembly — patched `bsd.rd` + `site79.tgz` alongside the sets

### 3.1 Which medium, and the layout

Two candidate boot media are already downloaded:
- `install79.iso` (798 MB) — full ISO with **all sets** (`base79.tgz`, `comp79.tgz`,
  `man79.tgz`, `xbase79.tgz`, … plus `bsd`, `bsd.mp`, `bsd.rd`, `SHA256`/`.sig`).
- `install79.img` (839 MB) — the USB image: MBR + a 0xEF EFI partition (960
  sectors) + an active 0xA6 OpenBSD partition (1 637 376 sectors) that carries the
  same `7.9/amd64/` tree including the sets and `bsd.rd`.

velo targets an **offline** install (`Location of sets = disk`, verification off),
so the medium must carry the sets *and* our `site79.tgz`. The **`.img`** is the
right base for M4 (it dd's straight to USB), so M3 assembly produces
`dist/velo79.img` = a copy of `install79.img` with:
- its `7.9/amd64/bsd.rd` **replaced** by `dist/bsd.rd.velo`, and
- `dist/site79.tgz` **added** into `7.9/amd64/` alongside `base79.tgz` etc.

(The ISO is kept as the **VM build host** install source — §6 — and as a control
run of the stock installer.)

### 3.2 `build/assemble-media.sh` (runs in the VM; file image only)

```sh
#!/bin/ksh
# build/assemble-media.sh -- swap the patched bsd.rd into a COPY of install79.img
# and drop site79.tgz beside the sets.  RUNS IN THE VM.  File image only; the dd
# to a real USB is the SEPARATE M4 script (write-usb.sh), never here.
set -eu
IMG_IN=${1:?usage: assemble-media.sh <install79.img> <bsd.rd.velo> <site79.tgz> [out]}
RD=${2:?}; SITE=${3:?}; OUT=${4:-dist/velo79.img}

cp "$IMG_IN" "$OUT"            # work on a COPY -- never mutate the download

# The OpenBSD partition (0xA6) holds the FFS with 7.9/amd64/.  Find its start
# offset from the MBR and mount it via vnconfig with an offset, OR (simpler and
# what the runbook uses) mount the partition by its disklabel letter after
# vnconfig'ing the whole image.  vnconfig a FILE, then disklabel shows the FFS
# partition; mount that.  (man vnconfig(8), disklabel(8).)
VND=$(vnconfig "$OUT")
trap 'umount /mnt 2>/dev/null||true; vnconfig -u "$VND" 2>/dev/null||true' EXIT INT TERM

# The sets live on the partition that disklabel reports as the FFS 'a' (or the
# 4th MBR partition mapped to a disklabel partition).  Identify it from
# `disklabel $VND` (look for the 4.2BSD fstype), then mount it.  The runbook
# pins the exact letter after inspecting the live label in the VM (FLAGGED).
SETS_PART=a                 # confirm in VM via: disklabel $VND  (FLAGGED M3)
mount /dev/"${VND}${SETS_PART}" /mnt

DEST=/mnt/7.9/amd64         # the set directory on the install medium
[ -d "$DEST" ] || { echo "velo: $DEST not found on image" >&2; exit 1; }

# Replace bsd.rd with the patched one; add site79.tgz beside the sets.
install -o root -g wheel -m 0644 "$RD"   "$DEST/bsd.rd"
install -o root -g wheel -m 0644 "$SITE" "$DEST/site79.tgz"

sync; umount /mnt; vnconfig -u "$VND"
echo "velo: assembled $OUT (patched bsd.rd + site79.tgz in $DEST)"
```

### 3.3 Why this layout (grounded)

- **`site79.tgz` is selectable from local media, extracted LAST.** When the
  installer asks *Location of sets = disk* and the operator selects the medium and
  the `7.9/amd64/` directory, the installer lists the `*.tgz` it finds. A custom
  `siteXX.tgz` placed there is offered and, per `install.site(5)`/constraints §6,
  is extracted **after** the OS sets, then its `/install.site` runs chrooted. **No
  `index.txt` is required** — the installer scans the directory (constraints §6).
- **Replacing `bsd.rd` on the medium** means the *booted installer itself* is the
  velo-patched ramdisk: the operator boots `velo79.img`, the velo TUI appears
  (via the `/.profile` hook), and the very same medium also hosts the sets +
  `site79.tgz`. One self-contained stick.
- **SHA256/.sig caveat.** Replacing `bsd.rd` and adding `site79.tgz` invalidates
  the medium's `SHA256`/`SHA256.sig`. That is *expected* and harmless because velo
  installs **offline with verification off** (`Continue without verification =
  yes`, m1-design §4). We do **not** re-sign (no signify key); the runbook notes
  the operator will see — and accept — the verification-off prompt. **FLAGGED**:
  confirm in the VM that selecting `disk` sets + verification-off cleanly skips the
  `.sig` check for *both* the OS sets and `site79.tgz`.
- **EFI + MBR boot paths** are untouched (we only edit files *inside* the FFS
  partition), so the stick boots on UEFI and legacy BIOS exactly as the stock
  `install79.img` does.

### 3.4 Host-side lint now

`ksh -n`/`bash -n` on `assemble-media.sh`; grep-assert it works on `$OUT` (a copy)
and contains no `of=/dev/`. Everything `vnconfig`/`mount` is **FLAGGED for the VM**.

---

## 4. The SEPARATE, heavily-guarded USB-write script (M4 — never auto-run)

This is the **only** script that writes to a real device. It is authored at
M3-prep but is the **M4 hard stop**: it MUST NOT run autonomously, because the
external TOSHIBA-bridged SSD is `sda` = the **Void-portable** root (project memory:
`project-void-portable-ssd-no-trim`, `feedback-user-home-not-root`). A wrong
target node bricks the daily-driver OS.

### 4.1 Guard stack (defence in depth)

```sh
#!/bin/sh
# build/write-usb.sh -- M4 HARD STOP.  Writes dist/velo79.img to a REMOVABLE USB.
# This DESTROYS the target device.  It is NEVER run autonomously.  Multiple
# independent guards; ANY failing guard aborts before a single byte is written.
set -eu

IMG=${1:?usage: write-usb.sh <velo79.img> <target-device>}
DEV=${2:?refusing: no explicit target device}

# GUARD 1 -- env arming.  The script refuses unless VELO_I_AM_SURE=yes is set in
# the environment by a HUMAN this session.  No default; no prompt-only bypass.
[ "${VELO_I_AM_SURE:-no}" = "yes" ] || { echo "refusing: set VELO_I_AM_SURE=yes (human gate)"; exit 1; }

# GUARD 2 -- the target must be a removable disk, NOT the system/boot disk and
# NOT sd0/the SSD carrying the OS.  On OpenBSD: refuse anything mounted; refuse
# the disk that backs '/'.  (root disk from `mount`/`df /`.)
ROOTDISK=$(df / | awk 'NR==2{print $1}' | sed 's,/dev/,,;s,[a-p]$,,')
case "$DEV" in
*"$ROOTDISK"*) echo "refusing: $DEV looks like the ROOT disk ($ROOTDISK)"; exit 1 ;;
esac

# GUARD 3 -- the device must be currently UNMOUNTED everywhere.
if mount | grep -q "^/dev/${DEV}"; then echo "refusing: $DEV has mounted partitions"; exit 1; fi

# GUARD 4 -- typed confirmation of the EXACT device + its reported size/model, so
# the human re-reads what they are about to erase.  (disklabel/sysctl for size.)
echo "About to OVERWRITE: $DEV"
disklabel "$DEV" 2>/dev/null | sed -n '1,6p' || true
printf 'Type the device name again to confirm: '
read CONFIRM
[ "$CONFIRM" = "$DEV" ] || { echo "mismatch -- aborted"; exit 1; }

# GUARD 5 -- size sanity: the image must be <= the device (else it is not the
# stick we think).  Refuse if the device is implausibly large (an internal SSD).
# (Sizes via disklabel total sectors.)
# ... (computed; abort if image > device or device > 256GB without --huge) ...

# Only here, after ALL guards, do we write.  Raw device, block size 1m, sync.
dd if="$IMG" of=/dev/r"$DEV"c bs=1m status=progress
sync
echo "velo: wrote $IMG to $DEV"
```

### 4.2 Posture

- **No autonomous invocation anywhere.** No build step, no test, no CI calls
  `write-usb.sh`. It is documented in the runbook as the *final manual step Anton
  performs with the stick physically in hand*, after `lsblk`/`sysctl hw.disknames`
  on the live system to read the new device's node.
- **Five independent guards** (env-arm, root-disk match, mount check, typed
  re-confirm, size sanity) — any one failing aborts before `dd`. The `dd` target is
  the **raw char device** `/dev/r${DEV}c` (whole disk) only after all pass.
- **On the Void host (not OpenBSD)** the analogous manual command is
  `dd if=dist/velo79.img of=/dev/sdX bs=4M oflag=sync status=progress` with the
  same human discipline — but the **canonical** velo write path is from OpenBSD
  with the guarded script. The memory rule stands: **sda is the Void-portable;
  M4 only with Anton present.**

---

## 5. Validating the M2 `needs_vm` items (what only the VM can prove)

m2-design §8 FLAGGED a precise list. M3 closes each in the VM after an end-to-end
install. The runbook §6.5 walks these; here is the acceptance matrix:

| # | check | command in the VM | pass criterion |
|---|-------|-------------------|----------------|
| 1 | pf L1/L2/L3 parse | `pfctl -nf /etc/velo/pf/pf.l1.conf` … `.l3.conf` | exit 0, no parse error |
| 2 | L3 ruleset (SOCKS-only) | `pfctl -nvf /etc/velo/pf/pf.l3.conf` then inspect ruleset | `block all` first; two `pass out quick … user _tor` (tcp,udp); **no** `rdr-to`/`divert-to` (SOCKS-only fail-closed, not a transparent gateway) |
| 3 | doas policy | `doas -C /etc/doas.conf` (syntax: silent, exit 0) ; `doas -C /etc/doas.conf pkg_add -u` (match: prints `permit`/`permit nopass`/`deny`, exit 0, runs nothing) | config syntactically valid (silent exit 0); no `permit nopass` rule for `pkg_add`. See runbook §5.1 item 5. |
| 4 | xenodm enable | `rcctl get xenodm` (desktop install) | `xenodm_flags=` set / status enabled; `rcctl ls on` shows it |
| 5 | user idempotency | `id anton` after install | exists with `wheel operator`; install.site `usermod` did not fail/dup |
| 6 | pkg_add offline closure | `PKG_PATH=/usr/obj/_pkgs pkg_add -n -l /etc/velo/installed.list` | resolves the **full** closure with `-n` (dry) from local blobs ONLY — no fetch attempt |
| 7 | L3 Tor end-to-end | boot fortress+L3; `ps … grep tor`; `torsocks ftp -o - https://check.torproject.org/api/ip` | tor runs as **_tor**; **direct** egress (nc/ftp) **fails** (pf `Permission denied`); torsocks returns `IsTor:true`+exit IP; stop tor → torsocks dies, direct stays blocked. **Proven live S9** (see runbook §5.2). |
| 8 | IPv6 off (L2/L3) | `ifconfig` / `sysctl net.inet6.ip6` | no global v6 addr; pf `block out inet6` present |
| 9 | site extracted LAST | install log / `ls -la /` post-install | `/install.site` ran chrooted, was removed; site files present |

**Item 6 is the offline-closure gate** and the reason `/usr/obj/_pkgs/*.tgz` is an
M3-VM task: M2 ships only the `.list` files. In the VM the operator populates the
closure (one of two ways, FLAGGED for the runbook to pick):
- `pkg_add -z` / a `dpb`-free **mirror snapshot**: `PKG_PATH=<7.9 mirror>` then
  `pkg_add -n` to enumerate the dependency closure of each profile list, and copy
  exactly those `*.tgz` into `site/usr/obj/_pkgs/` before `make-site-tgz.sh`; or
- a full `rsync` of `7.9/packages/amd64/` for the needed packages.
For **L3 the closure MUST be complete** (the fail-closed pf makes the mirror
unreachable on first boot — m2-design §6/§9); item 6 with `-n` and a **blocked
network** is the hard test.

---

## 6. The VM runbook (outline — `docs/m3-runbook.md` to be filled as we go)

The runbook is executed by the operator (Anton) inside an OpenBSD 7.9 VM. It is
where every FLAGGED-for-VM item is actually run. Outline:

### 6.1 Provision the build-host VM (VirtualBox, from the ISO)

```
# On the Void host (VirtualBox is available per the SATYR/Whonix memory):
VBoxManage createvm --name velo-build --ostype OpenBSD_64 --register
VBoxManage modifyvm velo-build --memory 2048 --cpus 2 --firmware efi \
    --nic1 nat --audio none
VBoxManage createhd --filename velo-build.vdi --size 20000     # 20 GB build disk
VBoxManage storagectl velo-build --name sata --add sata --controller IntelAhci
VBoxManage storageattach velo-build --storagectl sata --port 0 --device 0 \
    --type hdd --medium velo-build.vdi
VBoxManage storageattach velo-build --storagectl sata --port 1 --device 0 \
    --type dvddrive --medium /home/thx1138/Downloads/install79.iso
VBoxManage startvm velo-build
```
- Plain **stock** OpenBSD 7.9 install from `install79.iso` (this is also the
  control run of the stock installer — confirm the prompt wording the answer-token
  table depends on, m1-design §4). Install `comp`/`man`; no X needed on the build
  host.
- After install, `pkg_add` nothing exotic — the build needs only base
  (`rdsetroot`, `vnconfig`, `mount`, `disklabel`, `gzip`, `install`, `signify` —
  all in base). `git` optional to clone the repo in; or attach the repo via a
  shared folder / a second `.vdi` / `scp`.

### 6.2 Get the velo tree + inputs into the VM

- Copy the repo (`src/`, `build/`, `site/`, `dist/site79.tgz`) into the VM
  (`scp`/shared folder). Build `dist/site79.tgz` first **on the host**
  (`build/make-site-tgz.sh` runs on Void) so the VM consumes a ready tarball; OR
  rebuild it in the VM. Either way it is byte-identical (reproducible packer).
- Get a **pristine** `7.9 bsd.rd`: either extract it from the mounted ISO
  (`/7.9/amd64/bsd.rd`) or fetch from a 7.9 mirror.

### 6.3 Build in the VM

```
ksh build/build-velo.sh /path/to/pristine/bsd.rd dist/bsd.rd.velo
ksh build/assemble-media.sh /home/.../install79.img dist/bsd.rd.velo \
    dist/site79.tgz dist/velo79.img
```
Watch the **size-ceiling** line from build-velo (§1.2 step 11). If it overflows,
the v0.1 fallback is documented (rebuild RAMDISK kernel) but expected unnecessary
for a few KB of scripts.

### 6.4 Test-boot the patched image against a BLANK disk

Two complementary harnesses; **both boot against a fresh, empty virtual disk** so
no real data is ever at risk:

- **qemu (fast iteration):**
  ```
  qemu-img create -f raw blank.img 16G
  qemu-system-x86_64 -m 2048 -bios /usr/local/share/...OVMF.fd \
      -drive file=dist/velo79.img,format=raw,if=virtio \
      -drive file=blank.img,format=raw,if=virtio -serial mon:stdio
  ```
  The serial console confirms the **ASCII/SGR** rendering (constraints §2/§3) and
  the velo TUI appearing via the `/.profile` hook. (qemu may run on the Void host
  directly if installed, or inside the VM.)
- **VBox (closer to the real boot path / UEFI):** attach `velo79.img` as a USB or
  raw disk and a blank `.vdi` as the target; boot; verify the TUI, the
  default-**No** destructive gate, and that **ESC at the welcome falls through to
  the stock menu** (§2.2).

### 6.5 End-to-end encrypted install IN THE VM (against the blank disk)

Walk the wizard: choose the blank disk, **encrypt=yes** + passphrase (confirm-
twice), hostname, a profile (run `desktop` and `fortress`/L3 at least), package
checklist, start mode. Confirm the **Ворота-СТОП** (default No; type the confirm
word). Then velo:
1. runs the real `plan_crypto` (`fdisk`→`disklabel` RAID→`bioctl -c C`), reading
   the CRYPTO `sd` unit back from `bioctl softraid0` (never hardcoded);
2. writes `/mnt/etc/velo/answers` (M2 contract) + `install.conf`;
3. runs `install` with `Location of sets = disk`, verification off, sets from the
   medium, **`site79.tgz` extracted last**, `/install.site` runs chrooted;
4. reboot → first boot → `rc.firsttime` runs the offline `pkg_add` block.

Then run the **§5 acceptance matrix** on the booted system. Re-run the install for
each profile/level that matters (desktop+L1, fortress+L3 especially for the Tor
fail-closed test).

### 6.6 M4 (HARD STOP — only with Anton, stick in hand)

`dist/velo79.img` → external USB via `build/write-usb.sh` (all five guards) on
OpenBSD, or the documented manual `dd` on the host. **Never autonomous; never to
`sda`.**

---

## 7. What M3-prep does NOW (host, no OpenBSD) vs. FLAGGED for the VM

**Authored + linted NOW (Void host):**
1. `build/build-velo.sh`, `build/velo-rd-hook.sh`, `build/assemble-media.sh`,
   `build/write-usb.sh` — written and parse-clean under `bash -n`, the host
   `/usr/sbin/ksh -n`, and (for the `/bin/sh` scripts) `sh -n`. A construct that
   passes one shell but not another is a bug (M1/M2 rule).
2. The two `src/velo-install` wiring edits (§2.3): the `VELO_TUI` source-override
   and the gated DRY-RUN→real switch, with `tests/velo-install-test.ksh` extended
   for the override path and the default-No gate. The real `install`/`bioctl`
   stays unreached on the host (no tty / `VELO_DRYRUN`-style guard).
3. Grep-asserts: no script writes `of=/dev/` except `write-usb.sh`; no script ever
   *creates* `auto_install.conf`; build-velo only ever `vnconfig`s a **file**.
4. Rebuild/refresh `dist/site79.tgz` via `make-site-tgz.sh` (reproducible).

**FLAGGED — verify in the 7.9 VM (M3):** everything needing
`rdsetroot`/`vnconfig`/`mount`/`disklabel`/`pfctl`/`doas`/`rcctl`/`pkg_add`/`bioctl`
— the rd-patch repack and size ceiling (constraints UNVERIFIED #5), the exact
disklabel partition letter for the set directory on the `.img` (§3.2), the
verification-off acceptance for the modified medium (§3.3), the answer-token
wording (m1-design §4), the offline pkg closure completeness (§5 item 6), and the
L3 Tor end-to-end fail-closed (§5 item 7). Plus the M0/M1 ramdisk-rendering
UNVERIFIED items (constraints §155+) confirmed on the live 7.9 console while the
velo TUI runs.

---

## 8. Open decisions to confirm before/while building

1. **Source directory in the ramdisk.** Chosen: inject both files at `/` and add a
   `VELO_TUI` override (§2.3). Alternative (place under `/velo/`) rejected — flat
   `/` matches the M1 `${0%/*}` logic with the least change.
2. **bsd.rd source.** Prefer extracting from the **ISO** (`/7.9/amd64/bsd.rd`) so
   the patched rd matches the exact 7.9 build the sets came from. Mirror fetch is
   the fallback (must be the *same* 7.9 patch level).
3. **Medium base for M4.** Chosen: `install79.img` (USB image, dd-able). The ISO
   stays the VM build-host source + stock control run.
4. **Closure population method** (§5 item 6) — mirror-snapshot `pkg_add -n` vs.
   directory rsync. Decide in the VM by closure size; L3 requires completeness.
5. **RAMDISK kernel rebuild** — only if the size ceiling (§1.2 step 11) is
   exceeded. Expected unnecessary for ~30 KB of scripts; if hit, that is a
   separate, larger sub-task (build a custom RAMDISK kernel) and is flagged, not
   attempted blindly.

---

## 9. What M3 deliberately does NOT do

- **No device writes from any build/test/CI path.** Only `write-usb.sh` writes a
  device, and only manually at M4 with Anton present (never to `sda`).
- **No `auto_install.conf`** ever created (it would bypass the interactive menu) —
  build-velo *refuses* if it finds one.
- **No editing of `install.sub`** or the crunch — we hook only `/.profile`.
- **No re-signing** of the modified medium — velo installs offline with
  verification off (the modified `bsd.rd`/`site79.tgz` invalidate `SHA256.sig` by
  design; the operator accepts the verify-off prompt).
- **No change to `src/velo-tui.ksh`** (frozen M0). The only `src/` change is the
  two minimal `velo-install` wiring edits in §2.3.
- **No autonomous run of the destructive install** outside the VM, against
  anything but a blank virtual disk.

---

## 10. Sources (grounded) / cross-refs

- `rdsetroot(8)` — `-s` size ceiling, `-x` extract rd image, default insert.
  <https://man.openbsd.org/rdsetroot.8>
- `vnconfig(8)` — attach a **file** as a block device, prints/uses the vnd unit.
  <https://man.openbsd.org/vnconfig.8>
- `mount(8)` / `umount(8)` — mount `/dev/${vnd}a` (FFS); unmount before detach.
  <https://man.openbsd.org/mount.8>, <https://man.openbsd.org/umount.8>
- `disklabel(8)` — read the partition map / FFS partition letter on the `.img`.
  <https://man.openbsd.org/disklabel.8>
- `install(1)` — atomic owner/mode file install of the injected scripts.
  <https://man.openbsd.org/install.1>
- `dot.profile` (miniroot) — the install menu lives in `/.profile`; hook point.
  <https://raw.githubusercontent.com/openbsd/src/master/distrib/miniroot/dot.profile>
- `install.sub` (miniroot) — no `install.sh`; `(I)/(U)/(S)` menu; offline sets.
  <https://github.com/openbsd/src/blob/master/distrib/miniroot/install.sub>
- `autoinstall(8)` — response-file format; **do NOT** ship `auto_install.conf`
  (arms a timeout that bypasses the interactive menu). <https://man.openbsd.org/autoinstall.8>
- `install.site(5)` — `siteXX.tgz` extracted **last**, `/install.site` chrooted.
  <https://man.openbsd.org/install.site.5>
- `pkg_add(1)` — `-n` dry-run closure, `-l` name list, local `PKG_PATH`.
  <https://man.openbsd.org/pkg_add.1>
- `pfctl(8)` — `-nf` parse-only, `-nvf` show ruleset (L3 order check).
  <https://man.openbsd.org/pfctl.8>
- `doas(1)` — `-C` config check. <https://man.openbsd.org/doas.1>
- `rcctl(8)` — `get`/`ls on` for xenodm/tor/pf. <https://man.openbsd.org/rcctl.8>
- `bioctl(8)` — softraid CRYPTO; read the new `sd` unit from `bioctl softraid0`.
  <https://man.openbsd.org/bioctl.8>
- `vmctl(8)`/`vmd(8)` — OpenBSD's own VM monitor (alternative to qemu/VBox for the
  blank-disk test boot, if the VM nests). <https://man.openbsd.org/vmctl.8>
- Reference rd-patch projects: echothrust/openbsd-patchrd (rdsetroot/vnconfig/
  mount cycle), ezaquarii/openbsd-autoinstall (autoinstall + media assembly).
  <https://github.com/echothrust/openbsd-patchrd>,
  <https://github.com/ezaquarii/openbsd-autoinstall>
- velo internal: `docs/constraints.md` §6 (hook/repack/site), `docs/m1-design.md`
  §4–§6 (install.conf, crypto seam, entrypoints), `docs/m2-design.md` §5/§8/§9
  (install.site, FLAGGED VM items, offline closure), `docs/m3-requirements.md`
  (carried tui_confirm default-No, M4 hard stop).
