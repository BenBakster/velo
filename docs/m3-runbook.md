# velo M3 — VM runbook (build, test-boot, encrypted install, verify)

Status: runbook (Ворота-4 execution guide). Followable end-to-end. **Everything
here runs INSIDE an OpenBSD 7.9 VM** (or against a BLANK virtual disk); the only
device-writing step is **M4** (`build/write-usb.sh`) and is the **hard stop** —
never autonomous, never to `sda` (the Void-portable root).

> **LIVE STATUS (Sessions 1–9, 2026-06-05):** this runbook was executed end-to-end
> on **qemu/KVM + OVMF** (not VirtualBox — the Void host has no VBox; see WORKLOG S1).
> A real encrypted `fortress+L3` install completed, the box **FDE-boots**, and the
> L3 **SOCKS-only fail-closed** acceptance (§5.2, T1–T4) is **proven live** (S9,
> commit 99c03a9). The `VirtualBox` commands in §1 are kept as a generic alternative;
> the "NOT IMPLEMENTED / FROZEN M1 DRY-RUN" banners in §4b/§5 are **SUPERSEDED** —
> the destructive-execute wiring exists (commit 92a88c2) and ran live. Only **M4**
> (real hardware) remains a supervised hard stop.

This document is the place where every item the design FLAGGED *verify in the
7.9 VM (M3)* is actually run. The scripts were authored and `ksh -n`/`bash -n`
linted on the Void host; here they execute on real OpenBSD.

Cross-refs: `docs/m3-design.md` (design), `docs/constraints.md` (verified
findings + UNVERIFIED list), `docs/m2-design.md` §8 (FLAGGED items), `docs/
m3-requirements.md` (carried tui_confirm default-No, M4 hard stop).

Inputs already on the host:
- `/home/thx1138/Downloads/install79.iso` (OpenBSD/amd64 7.9 — VM build host + stock control run)
- `/home/thx1138/Downloads/install79.img` (the USB image assemble-media patches)

---

## 0. Map of the flow

```
 install79.iso ──► [VBox VM: stock OpenBSD 7.9 build host]
                         │
   repo + install79.img + pristine bsd.rd  copied into the VM
                         │
        build/build-velo.sh   ──►  dist/bsd.rd.velo   (patched ramdisk)
        build/make-site-tgz.sh ─►  dist/site79.tgz    (M2 packer; host or VM)
        build/assemble-media.sh ─► dist/velo79.img    (patched rd + site)
                         │
        test-boot velo79.img  ──► BLANK virtual disk (qemu / VBox)
                         │
        full ENCRYPTED install in the VM  ──► §5 acceptance matrix
                         │
        ── M4 HARD STOP ── build/write-usb.sh velo79.img sdN  (Anton present)
```

---

## 1. Provision the build-host VM (qemu/KVM, from the ISO)

> **Actual path used (S1):** the Void host has **no VirtualBox**; the build-host was
> provisioned with **qemu/KVM** (headless, SeaBIOS sercon → serial console; the stock
> installer driven by an expect-style script — see WORKLOG S1 for the recipe and the
> `base-7.9` snapshot). The `VBoxManage` block below is kept only as a generic
> alternative; on this host use qemu.

VirtualBox is **not** installed on the Void host (despite an older SATYR/Whonix
note); use qemu/KVM as above. Run everything as `thx1138` (not root):

```sh
cd /home/thx1138/Документи/_Проекты/velo
VBoxManage createvm --name velo-build --ostype OpenBSD_64 --register
VBoxManage modifyvm velo-build --memory 2048 --cpus 2 --firmware efi \
    --nic1 nat --audio none --usbohci on
# 20 GB build disk (holds the repo, the .img, and a couple of patched outputs)
VBoxManage createhd --filename "$HOME/VirtualBox VMs/velo-build/velo-build.vdi" \
    --size 20000
VBoxManage storagectl velo-build --name sata --add sata --controller IntelAhci
VBoxManage storageattach velo-build --storagectl sata --port 0 --device 0 \
    --type hdd --medium "$HOME/VirtualBox VMs/velo-build/velo-build.vdi"
VBoxManage storageattach velo-build --storagectl sata --port 1 --device 0 \
    --type dvddrive --medium /home/thx1138/Downloads/install79.iso
VBoxManage startvm velo-build
```

Install **stock** OpenBSD 7.9 from the ISO. This *is also the control run of the
stock installer* — note the exact prompt wording (it backs the answer-token
table in `m1-design.md` §4 and `gen_install_conf`). Choices for the build host:

- disk: the 20 GB `sd0`/`wd0`; whole-disk, `(A)uto` layout, **no** encryption
  (this is just the build host).
- sets: from the CD; install **`comp`** and **`man`** (needed? — base already
  ships `rdsetroot`, `vnconfig`, `mount`, `disklabel`, `install`, `gzip`,
  `signify`; `comp`/`man` only help if you rebuild a RAMDISK kernel later).
- no X needed on the build host.

After first boot, log in as root. You need **no exotic packages** — the whole
build runs from base.

---

## 2. Get the velo tree + inputs into the VM

Pick one transfer path:

- **Shared folder** (simplest): `VBoxManage sharedfolder add velo-build --name velo \
  --hostpath /home/thx1138/Документи/_Проекты/velo --automount` then in the VM
  mount it; OR
- **scp over the NAT** (enable sshd in the VM, port-forward 2222→22); OR
- a **second `.vdi`** you populate on the host and attach.

You need inside the VM:
- the repo (`src/`, `build/`, `site/`, `tests/`),
- `dist/site79.tgz` — build it on the **host** first (it is reproducible):
  ```sh
  # ON THE VOID HOST:
  cd /home/thx1138/Документи/_Проекты/velo
  sh build/make-site-tgz.sh           # -> dist/site79.tgz (+ manifest)
  ```
  or rebuild it in the VM (byte-identical packer).
- `install79.img` (copy it in),
- a **pristine 7.9 `bsd.rd`** — extract from the mounted ISO so it matches the
  exact 7.9 patch level the sets came from:
  ```sh
  # IN THE VM, with the ISO still attached (cd0):
  mount -t cd9660 /dev/cd0a /mnt
  cp /mnt/7.9/amd64/bsd.rd /root/bsd.rd.orig
  umount /mnt
  ```
  (Fallback: fetch `pub/OpenBSD/7.9/amd64/bsd.rd` from a 7.9 mirror — must be
  the same patch level.)

---

## 3. Build in the VM

```sh
cd /path/to/velo            # the copied repo
# 3a. Patch the ramdisk.  Watch the SIZE-CEILING line.
ksh build/build-velo.sh /root/bsd.rd.orig dist/bsd.rd.velo
```

Expected output includes:
```
build-velo: rd_root_image ceiling = <N> bytes
build-velo: injected /velo-tui.ksh /velo-install /velo-rd-hook.sh
build-velo: inserted the velo hook into /.profile just above the stock menu loop
build-velo: patched fs <M> B fits ceiling <N> B (slack <N-M> B)
build-velo: wrote dist/bsd.rd.velo
```

**If the ceiling check FAILS** (`patched fs ... > ceiling ...`): the stock 7.9
ramdisk has no slack for our ~30 KB of scripts. That is the `constraints.md`
**UNVERIFIED #5** path — the fix is rebuilding the RAMDISK kernel with a larger
`rd_root_image` (a separate, larger task; do **not** force it). Re-running
build-velo on an already-patched rd is idempotent (the `/.profile` sentinel
prevents a double-insert), so you can safely re-run after fixing inputs.

```sh
# 3b. Assemble the bootable media (file copy only).
ksh build/assemble-media.sh /root/install79.img dist/bsd.rd.velo \
    dist/site79.tgz dist/velo79.img
```

assemble-media prints the live `disklabel` so you can **confirm the set
partition letter** (FLAGGED `m3-design.md` §3.2). On the stock `install79.img`
it is `a`; if the label shows the 4.2BSD set partition under a different letter,
re-run with it as the 5th arg:
```sh
ksh build/assemble-media.sh /root/install79.img dist/bsd.rd.velo \
    dist/site79.tgz dist/velo79.img d        # e.g. partition 'd'
```

Sanity-check the assembled image carries our payload. Reuse the **same set
partition letter** you passed to assemble-media (do not hardcode `a`):
```sh
SETS_PART=a                                   # the letter you confirmed/passed above
VND=$(vnconfig dist/velo79.img)
mount /dev/${VND}${SETS_PART} /mnt
ls -l /mnt/7.9/amd64/bsd.rd /mnt/7.9/amd64/site79.tgz
umount /mnt; vnconfig -u "$VND"
```

---

## 4. Test-boot the patched image against a BLANK disk

**Both harnesses boot against a fresh, EMPTY virtual disk** so no real data is
ever at risk. Do the fast qemu loop first, then the closer-to-real VBox boot.

### 4a. qemu (fast iteration — LEGACY/MBR boot under SeaBIOS)

The command below uses qemu's **default firmware (SeaBIOS)**, so this exercises
the **legacy/MBR** boot path of `velo79.img`, not UEFI. That is intentional for
the fast loop (no OVMF dependency). To exercise the **UEFI/EFI** path instead,
`pkg_add edk2-ovmf` (or point at your OVMF build) and add `-bios <path>/OVMF.fd`
to the line below; §4b covers the closer-to-real boot. Test **both** firmware
paths before M4 since the stick must boot on legacy BIOS and UEFI.

```sh
# A throwaway blank target disk:
qemu-img create -f raw blank.img 16G
# Default firmware = SeaBIOS -> LEGACY/MBR boot.  For UEFI add: -bios .../OVMF.fd
# (pkg_add edk2-ovmf on OpenBSD provides it).
qemu-system-x86_64 -m 2048 -smp 2 \
    -drive file=dist/velo79.img,format=raw,if=virtio \
    -drive file=blank.img,format=raw,if=virtio \
    -serial mon:stdio
# UEFI variant (legacy is the default above):
#   qemu-system-x86_64 -m 2048 -smp 2 -bios /usr/local/share/edk2-ovmf/OVMF.fd \
#       -drive file=dist/velo79.img,format=raw,if=virtio \
#       -drive file=blank.img,format=raw,if=virtio -serial mon:stdio
```

On the serial console confirm:
- the velo **ASCII/SGR "DOS blue box"** TUI renders (no `?` walls — that
  validates `constraints.md` §2/§3 rendering on a real OpenBSD console), and
- it appears **via the `/.profile` hook** (you did not type `install`).

### 4b. VBox (closer to the real boot path)

> ############################################################################
> ##  SUPERSEDED (Sessions 5–9).  The destructive-execute wiring IS built     ##
> ##  (commit 92a88c2): velo-install writes /mnt/etc/velo/answers and runs    ##
> ##  real fdisk/bioctl/disklabel/install behind the confirmed Ворота-СТОП.   ##
> ##  A real encrypted box installed and FDE-boots (S5); fortress+L3 and two  ##
> ##  distinct root/anton passwords (S8) are proven live.  The VBox test-     ##
> ##  drive below still works (ESC fall-through; default-No gate); the REAL   ##
> ##  install path is exercised in §5.  Only M4 (real hardware) stays a       ##
> ##  supervised hard stop.                                                   ##
> ############################################################################

Attach `velo79.img` as a raw/USB disk and a blank `.vdi` as the target; boot and
verify (all of this is observable on the DRY-RUN build — nothing writes):
- the velo TUI appears automatically,
- the summary **Ворота-СТОП** defaults to **No**. The typed-confirm-word gate and
  the destructive-execute path **exist** (§2.3 wiring, commit 92a88c2) and are
  exercised for real in §5; for this non-destructive test-drive just **stop at the
  gate** (leave the default **No**) — nothing writes,
- **ESC at the welcome screen FALLS THROUGH to the stock OpenBSD menu**
  (`(I)nstall / (U)pgrade / (A)utoinstall / (S)hell`) — the hook is an *around*
  wrap inserted above the `while :; do` menu loop, not a replacement
  (`m3-design.md` §2.2). Reaching a `(S)hell` from ESC proves the fall-through.

---

## 5. End-to-end ENCRYPTED install IN THE VM (against the blank disk)

> ############################################################################
> ##  IMPLEMENTED + PROVEN LIVE (Sessions 5–9, qemu/OVMF, throwaway disks).   ##
> ##                                                                          ##
> ##  The §2.3 destructive-execute wiring exists (commit 92a88c2): velo-      ##
> ##  install writes /mnt/etc/velo/answers, runs the real plan_crypto         ##
> ##  (fdisk/disklabel RAID/bioctl -cC), writes install.conf and invokes      ##
> ##  `install` — all behind the confirmed Ворота-СТОП (default-No + typed    ##
> ##  confirm word).  A real encrypted fortress+L3 box installed, FDE-boots,  ##
> ##  and passed the L3 fail-closed acceptance T1–T4 (§5.2).  root/anton get  ##
> ##  two distinct operator-set passwords (S8); the `velotest1` shim is gone. ##
> ##                                                                          ##
> ##  Still NOT autonomous: §6 / M4 (dd to a REAL device) — supervised hard   ##
> ##  stop, Anton present, never to sda.                                      ##
> ############################################################################

**VM install walk-through.** The §2.3 destructive-execute wiring **exists** (commit
92a88c2) and ran live (S5–S9); M4 on real hardware is §6. Boot `velo79.img` against
the blank disk and walk the wizard:

1. welcome → **Begin** (Yes).
2. disk → pick the **blank** target (e.g. `sd1` — confirm it is the empty one,
   never the build host's own disk).
3. encrypt → **yes**; enter the passphrase **twice** (the confirm-twice loop).
   Later, when the install actually runs, confirm the **verify-off** prompt
   wording matches what you noted on the §1 stock control run (the
   `Continue without verification = yes` answer-token; `m1-design.md` §4) — the
   modified medium's `SHA256.sig` is invalid by design (§3.3).
4. hostname → e.g. `velo-test`.
5. profile → run **`desktop`** for one pass and **`fortress`** for another (L3
   needs fortress).
6. packages → tick a few.
7. start mode → **L1** with desktop, **L3** with fortress (the two that matter).
8. summary **Ворота-СТОП** → defaults to **No**; choose Yes and type the confirm
   word to proceed.

velo then, in the VM, on the blank disk, runs the §2.3 destructive-execute path
(commit 92a88c2 — proven live S5–S9, no longer a frozen DRY-RUN):
1. run the real `plan_crypto` sequence — `fdisk -iy -g -b 960` → `disklabel -E`
   one **RAID** slice → `bioctl -Cforce -cC -l<chunk>a -s softraid0`, **reading
   the new CRYPTO `sd` unit back from `bioctl softraid0`** (never hardcoded;
   `constraints.md` §5);
2. write `/mnt/etc/velo/answers` (the M2 contract) and the `install.conf`;
3. run `install` with **Location of sets = disk**, **Continue without
   verification = yes**, sets from the medium, **`site79.tgz` extracted LAST**,
   `/install.site` runs chrooted;
4. reboot → first boot → `rc.firsttime` runs the offline `pkg_add` block.

> **Verification-off (FLAGGED `m3-design.md` §3.3):** confirm that selecting
> `disk` sets with verification off cleanly skips the `.sig` check for **both**
> the OS sets and `site79.tgz` (we replaced `bsd.rd` and added `site79.tgz`, so
> the medium's `SHA256.sig` is invalid by design — expected).

Now run the **acceptance matrix** on the booted system.

### 5.1 Acceptance matrix (close every FLAGGED item)

| # | check | command in the VM | pass criterion |
|---|-------|-------------------|----------------|
| 1 | FDE prompt at boot | reboot; observe console | softraid CRYPTO passphrase prompt appears BEFORE the kernel loads `/`; wrong passphrase blocks boot |
| 2 | pf L1/L2/L3 parse | `pfctl -nf /etc/velo/pf/pf.l1.conf` … `.l3.conf` | exit 0, no parse error |
| 3 | correct pf level loaded | `rcctl get pf` (or `pfctl -si \| grep Status`) ; `pfctl -sr` compared to `/etc/velo/pf/pf.lN.conf` for the chosen startmode | pf reports **Enabled** (status `Enabled`/`rcctl get pf` → `pf=YES`); the **loaded** ruleset (`pfctl -sr`) matches the chosen level file `pf.lN.conf` (install.site copied the right one). Note: install.site only copies the level file to `/etc/pf.conf`; it relies on the **stock `pf=YES` default** in `/etc/rc.conf` to load it at boot — confirm pf is actually Enabled, not just that the file is present. |
| 4 | L3 ruleset (SOCKS-only, fail-closed) | `pfctl -nvf /etc/velo/pf/pf.l3.conf` | `block all` first; then exactly two `pass out quick … user _tor` (tcp, udp); **no** `rdr-to`/`divert-to` (this is SOCKS-only, not a transparent gateway) |
| 5 | doas policy | **(a) syntax:** `doas -C /etc/doas.conf` (no command) ; **(b) permission match:** `doas -C /etc/doas.conf pkg_add -u` (as `anton`) | **(a)** prints **nothing** and exits **0** when the config is syntactically valid (non-zero + a parse error on bad syntax). **(b)** with a command, doas prints `permit`, `permit nopass`, or `deny` to stdout and exits 0 — it does **not** run the command. Pass = (a) silent/exit 0, and (b) shows the expected verdict with **no `permit nopass` (nopass) rule for `pkg_add`** (a nopass pkg rule would be the policy bug we are checking for). |
| 6 | xenodm (desktop) | `rcctl get xenodm` ; `rcctl ls on` | enabled for the desktop profile; disabled for minimal/fortress per profile rule |
| 7 | user idempotent | `id anton` | exists with `wheel operator`; install.site's group adjust did not dup/fail |
| 8 | pkg offline closure | `PKG_PATH=/usr/obj/_pkgs pkg_add -n -l /etc/velo/installed.list` | resolves the **full** closure with `-n` (dry) from local blobs ONLY — no fetch |
| 9 | packages present | `pkg_info \| sort` | the profile base ∪ chosen pkgs are installed (rc.firsttime ran) |
| 10 | IPv6 off (L2/L3) | `ifconfig` ; `sysctl net.inet6.ip6.forwarding` | no global v6 addr; pf carries `block out inet6` |
| 11 | site extracted LAST | install log ; `ls -la /` | `/install.site` ran chrooted and was removed; site files present |
| 12 | **L3 Tor fail-closed** | boot the **fortress+L3** install; see §5.2 | tor runs as **_tor**; **direct** egress (nc/ftp) to any IP **fails** (pf `Permission denied`); `torsocks` to check.torproject.org succeeds with `IsTor:true` + a Tor exit IP; stopping tor kills torsocks while direct stays blocked (fail-closed) |

### 5.2 L3 Tor SOCKS-only fail-closed (the headline acceptance)

**Model:** L3 is a SOCKS-only fail-closed box (NOT a transparent gateway). pf
`block all` + the ONLY egress is the `_tor` user; every program reaches the
network through Tor's SOCKS `127.0.0.1:9050`. A program that does not speak SOCKS
gets nothing (it cannot leak to the clearnet). Tor MUST run as `_tor` (torrc
`User _tor` + `DataDirectory /var/tor`) or `block all` drops its egress and the
box bricks.

On the **fortress + L3** install, after first boot completed `rc.firsttime`:

```sh
ps -axo user,pid,comm | grep '[t]or'             # MUST show user "_tor", not root
netstat -ln | grep 9050                           # SOCKS listener on 127.0.0.1:9050
# T1 DIRECT egress MUST FAIL (fail-closed; pf returns EACCES to the local socket):
nc -v -w6 1.1.1.1 443 </dev/null ; echo "direct rc=$?"   # "Permission denied", rc!=0
# T2 only _tor egresses -- tor itself has live outbound sockets:
fstat -p "$(pgrep -x tor)" | grep -i internet            # ESTABLISHED to relay :443/:9001
# T3 the Tor path MUST WORK and exit via a Tor node:
torsocks ftp -o - https://check.torproject.org/api/ip    # {"IsTor":true,"IP":"<exit>"}
# T4 fail-closed: stop tor -> torsocks dies AND direct stays blocked:
rcctl stop tor ; torsocks ftp -o - https://check.torproject.org/api/ip   # FAILS
nc -v -w6 1.1.1.1 443 </dev/null ; echo "still blocked rc=$?"            # still "Permission denied"
```

Pass = direct egress **blocked**, only `_tor` reaches the net, torsocks **succeeds
via a real Tor exit**, and stopping tor leaves **no** path out (fail-closed). This
is the single most important L3 acceptance. **Proven live in Session 9** (qemu/OVMF,
real encrypted box) — see the driver `vm/etapB-l3test.sh` and `docs/WORKLOG.md`.

### 5.3 Validate the M2 `needs_vm` list (offline closure population)

`m2-design.md` §8 FLAGGED the offline `pkg_add` closure as an M3-VM task — M2
ships only the `.list` files; the `*.tgz` blobs in `site/usr/obj/_pkgs/` are
populated **here**. For **L3 the closure MUST be complete** (the fail-closed pf
makes the mirror unreachable on first boot). Populate it one of two ways before
`make-site-tgz.sh`, then re-pack and re-assemble:

```sh
# Option A — enumerate the closure with -n from a 7.9 mirror, copy exactly those:
export PKG_PATH=https://cdn.openbsd.org/pub/OpenBSD/7.9/packages/amd64/
pkg_add -n -l site/usr/obj/_pkgs/fortress.list      # dry-run prints the full closure
#   ...copy each named *.tgz into site/usr/obj/_pkgs/ ...
# Option B — rsync 7.9/packages/amd64/ for the needed packages into site/usr/obj/_pkgs/.

# Then re-pack + re-assemble so the blobs ship in site79.tgz:
sh  build/make-site-tgz.sh
ksh build/assemble-media.sh /root/install79.img dist/bsd.rd.velo \
    dist/site79.tgz dist/velo79.img
```

The hard test is matrix item 8 with `-n` **and the network blocked** (L3): it
must resolve the entire closure from `/usr/obj/_pkgs` alone, with zero fetch
attempts.

Re-run the whole install for each profile/level that matters — **desktop+L1**
and **fortress+L3** at minimum.

### 5.4 legacy/MBR boot-mode acceptance (Backlog-C, ADDED С10)

The boot-mode code (`VELO_S_BOOTMODE=same|uefi|bios`) and its tests are done
(selftest 85, suite 146 incl. the behavioural fail-safe 8c). What is NOT yet
proven LIVE is that a **bios**-mode FDE install actually boots under legacy
SeaBIOS. This is the remaining DoD for C.

**Why it was broken before:** the crypto path always did `fdisk -iy -g -b 960`
→ GPT → boots only under UEFI; under SeaBIOS the chain has no active MBR
partition → **"No active partition"**. bios mode now uses plain `fdisk -iy`
(MBR, single active 0xA6 OpenBSD partition). disklabel/bioctl/installboot are
**unchanged** — installboot is softraid/biosboot-aware and auto-detects the
on-disk scheme, so the change is fdisk-args-only.

**Run it (QEMU/SeaBIOS = legacy — this is the default firmware, NO OVMF):**
```sh
# 1. Boot velo79.img under SeaBIOS (legacy). In the wizard choose:
#       encrypt = yes,  boot mode = bios   (or 'same' — under SeaBIOS it
#       auto-detects legacy, since dmesg.boot has bios0 and no efi0)
# 2. Let the gated real install run (throwaway disk only).
# 3. Reboot from the installed disk (no install medium).
```

**Pass criteria (sr0 must be the BOOT disk):**

| signal | PASS | FAIL / regression |
|---|---|---|
| boot loader disk line | `disk: hd0 sr0*` (note the **`*`** = softraid marked bootable) | `sr0` **without** `*`; drop to `boot>` loading `hd0a` ("Device not configured") |
| FDE prompt | reaches `Passphrase:` and unlocks | "No active partition" (GPT-on-legacy = `-g` slipped through); no prompt |
| partition table | `fdisk sd0` shows MBR partition `*3: A6 … OpenBSD` (active) | a GPT/protective-MBR with no active A6 |

The `*` on `sr0` (and the active A6) is the exact thing S6 lost via a disklabel
**offset** template — so do **not** introduce any disklabel offset; the heredoc
must keep its blank offset/size (auto-place). Also re-verify the **uefi** path
still boots (OVMF) so the table-switch didn't regress GPT.

---

## 6. M4 — HARD STOP (only with Anton, stick physically in hand)

`dist/velo79.img` → external USB. This is **never autonomous** and **never to
`sda`** (the Void-portable root).

First read the **new** device node on the live system (do not assume):

```sh
# OpenBSD:
sysctl hw.disknames            # e.g. sd0:...,sd2:...   the new stick is the new sdN
disklabel sd2                  # eyeball the size/model -- is it the USB stick?
# Linux (Void host):
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT
```

Then, on **OpenBSD**, the guarded canonical path (defaults to DRY-RUN):

```sh
# DRY-RUN first -- prints the dd it WOULD run, writes nothing:
sh build/write-usb.sh dist/velo79.img sd2
# Only when CERTAIN, arm it and type the confirmation when prompted:
VELO_I_AM_SURE=yes sh build/write-usb.sh dist/velo79.img sd2
```

The five+ guards (env-arm, bare-disk-name whitelist, root-disk match, mount
check, hw.disknames existence, size sanity, **typed re-confirm**) each abort
before a single byte is written.

On the **Void host** (not OpenBSD) the documented manual equivalent, with the
same human discipline, is:

```sh
# DOUBLE-CHECK the node with lsblk FIRST. sda is the Void-portable -- NEVER sda.
dd if=dist/velo79.img of=/dev/sdX bs=4M oflag=sync status=progress
```

**The memory rule stands: `sda` is the Void-portable; M4 only with Anton
present.**

---

## 7. Quick reference — what each script touches

| script | runs where | writes | device? |
|--------|-----------|--------|---------|
| `build/build-velo.sh` | OpenBSD VM | `dist/bsd.rd.velo` (file) | no — vnconfig on a FILE |
| `build/assemble-media.sh` | OpenBSD VM | `dist/velo79.img` (file copy) | no — vnconfig on a FILE |
| `build/make-site-tgz.sh` | Void host or VM | `dist/site79.tgz` (file) | no |
| `build/write-usb.sh` | OpenBSD (M4) | **a raw disk** | **YES — the only one; hard stop** |
| `build/velo-rd-hook.sh` | shipped INTO the rd | n/a (sourced at install) | no |

Build/assemble/site scripts are safe to run autonomously in the VM (file images
only). `write-usb.sh` is **never** autonomous.
