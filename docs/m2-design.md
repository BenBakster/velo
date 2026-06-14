# velo M2 — `site79.tgz` preset tree design

Status: design (Ворота-3 input). Implements the **M2** milestone from `PLAN.md`,
consuming the per-install choices that **M1 `velo-install`** collects.

**DRY-RUN posture (M2).** Nothing is installed now. M2 *authors* the preset tree
(`site/`), a deterministic *packer* (`build/make-site-tgz.sh`) that produces
`site79.tgz`, and *static* structure/syntax validation. Anything that needs a
real `pfctl -nf`, `doas -C`, `rcctl`, `pkg_add`, or `bioctl` is **STATIC-checked
here and FLAGGED `verify in the 7.9 VM (M3)`** — those tools do not exist on the
Void build host.

Everything below stays **byte-consistent** with `src/velo-install`:
- profiles: `desktop`, `minimal`, `fortress` (exact tokens, `VELO_PROFILES`);
- start modes: `L1`, `L2`, `L3` (`VELO_STARTMODES`);
- per-profile package universes copied **verbatim** from `profile_pkgs()`
  (§3 below is the single cross-check table).

---

## 1. The integration problem M2 must solve

`site79.tgz` is **STATIC** — the *same bytes every install* (it is baked into the
patched `bsd.rd`/install media at M3 and cannot vary per run). But the install
must apply the **per-install TUI choices**: which profile, which start mode
(L1/L2/L3), and which optional packages the operator checked.

The seam: **`velo-install` stages a tiny answers file into the target filesystem
*before* the static `install.site` runs; `install.site` *parses KEY=value lines*
from that file (data, never sourced as code) and falls back to safe defaults
(`minimal` + `L1`, no extra pkgs) if it is absent.**

```
   TUI (M1)                         site set (M2, STATIC)            first boot
   --------                         ---------------------            ----------
 velo-install  --writes-->  /mnt/etc/velo/answers
 (in ramdisk,               profile=… startmode=… pkgs=…
  before `install`             |
  unpacks the                  | install (autoinstall) unpacks base/man/x…
  site set)                    | then unpacks site79.tgz LAST  (constraints §6)
                               v
                       /install.site runs CHROOTED at /mnt   (NO network)
                         . /etc/velo/answers  (or defaults)
                         -> install correct pf.conf for $startmode
                         -> drop doas.conf / sysctl.conf / dotfiles / skel
                         -> useradd anton + groups, set shells
                         -> rcctl enable xenodm/ntpd/pf  (desktop -> xenodm)
                         -> APPEND offline pkg_add block to /etc/rc.firsttime
                                                          |
                                                          v
                                       FIRST BOOT: rc.firsttime runs
                                         PKG_PATH=<local[:mirror @ L1/L2]> \
                                            pkg_add -I -l /etc/velo/installed.list
```

Why this split (grounded in `docs/constraints.md` §6 and `install.site(5)`):
- `install.site` runs **chrooted with NO network**, so it cannot `pkg_add` from a
  mirror. It *can* run the level-pick, file drops, user creation, and `rcctl`
  enables — all local.
- Package installation needs the network, which only comes up on the **first
  boot**. So pkg_add is **appended (`>>`) to `/etc/rc.firsttime`** and runs then.
- BUT velo ships the packages **offline** inside the site set (`/usr/obj/_pkgs/`), so
  pkg_add reads from a **local `PKG_PATH`**, not a mirror — first-boot network is
  only needed to satisfy pkg dependency closure if the bundled set is incomplete.
  Decision: **bundle the full dependency closure** so the install is fully
  offline-capable, and the rc.firsttime network step is belt-and-suspenders.
  (Closure size and exact bundling are an M3-VM task — flagged below.)

### Why not pass choices a different way?
- **Not via `install.conf`** — that response file is consumed by `autoinstall`,
  which has no field for "velo profile/startmode/pkgs". (M1 already established
  encryption can't even go there.)
- **Not by baking N variant site sets** — `site79.tgz` is one static blob; we'd
  need 3 profiles × 3 levels = 9 blobs and a selector. The **answers file** keeps
  one static set + one tiny per-install file the TUI writes. Simpler, auditable.
- **Not by re-running the TUI on the target** — install.site is non-interactive,
  chrooted, no tty.

---

## 2. The TUI → install.site **answers contract**

### 2.1 Location & ownership
- **File:** `/etc/velo/answers` on the **target** (i.e. `/mnt/etc/velo/answers`
  while the installer is running; the post-reboot path is `/etc/velo/answers`).
- **Writer:** `velo-install` (M1), as the **last step before it hands control to
  the stock `install`** — i.e. after the summary Ворота-СТОП is confirmed and the
  target root is mounted at `/mnt`. (M1 currently DRY-RUN-prints; the actual
  write is wired at M3 when velo-install is no longer dry-run. The *format* is
  frozen here so both ends agree.)
- **Reader:** the static `/install.site` (shipped inside `site79.tgz`), which
  **parses KEY=value lines** of `/etc/velo/answers` early (data, never sourced as
  code — a `$(...)`/`;cmd` in a value can never execute), then validates every
  value against the same whitelists the TUI uses.
- **Why `/etc/velo/`:** survives into the booted system as an audit record of how
  this box was provisioned; `install.site` and any future L1/L2/L3 *switcher*
  (v0.2) read the same file. Mode `0600`, owned `root:wheel` (it records no
  secret, but keep it tight).

### 2.2 Format (strict, KEY=value data, injection-proof)
A flat `KEY=value` file, **no spaces around `=`**, values from a restricted
charset only. install.site **parses** it line-by-line (split on the first `=`,
whitelisted keys only) — it is **never** sourced as code, so even a malformed
value cannot execute. install.site also re-validates every value (defence in
depth — never trust the file even though the TUI wrote it).

```
# /etc/velo/answers — written by velo-install, read by install.site
# Per-install TUI choices. install.site falls back to safe defaults if absent.
profile=desktop
startmode=L2
pkgs=git curl tmux vim
hostname=velo-bsd
encrypt=yes
schema=1
```

Field rules (each re-validated in install.site; bad value -> documented default):

| key         | domain (whitelist)                                  | default if absent/invalid |
|-------------|-----------------------------------------------------|---------------------------|
| `schema`    | `1`                                                 | `1` (warn on mismatch)    |
| `profile`   | `minimal` \| `desktop` \| `fortress`                | `minimal`                 |
| `startmode` | `L1` \| `L2` \| `L3`                                 | `L1`                      |
| `pkgs`      | space-separated tokens `^[A-Za-z0-9._+-]+$` each     | `` (empty = profile base only) |
| `hostname`  | RFC-1123 label (`valid_hostname`)                    | already set by installer; advisory only |
| `encrypt`   | `yes` \| `no`                                        | `no` (advisory; FDE already done pre-install) |

- **`pkgs`** is the operator's *checklist* selection from screen 5 — the extra
  opt-ins **on top of** the profile's mandatory base. install.site composes the
  final pkg_add list = (profile mandatory list) ∪ (validated `pkgs`). Each token
  is re-validated `^[A-Za-z0-9._+-]+$`; anything else is dropped (a package name
  can never carry a shell metachar, so this is also the injection gate).
- **Safe-default rule (the contract's core):** if `/etc/velo/answers` is missing
  OR unreadable OR `profile`/`startmode` invalid, install.site proceeds with
  **`minimal` + `L1`** and **no optional packages** — a sane, *most-restrictive-
  that-still-boots* baseline (minimal install, permissive-but-firewalled L1). It
  logs the fallback to `/var/log/velo-install.site.log` and to the console.
- **Why `minimal`+`L1` as the floor (not desktop+L1):** an absent answers file
  means "we don't know what the operator wanted"; install the *least* (base +
  CLI tools), not a full desktop. L1 (not L3) because a fail-closed Tor-only
  firewall on a box whose Tor pkg might not have installed would be a brick.
  Note this differs from the **TUI's** highlight defaults (`desktop`, `L1`) —
  those are *interactive* defaults a human sees and can change; the answers-file
  default is the *unattended* floor. Documented divergence, intentional.

### 2.3 Exact writer (M1, wired at M3) and reader (M2) snippets
Writer (conceptual — M1 emits this once /mnt is mounted; DRY-RUN prints it):
```sh
mkdir -p /mnt/etc/velo
{
    echo "schema=1"
    echo "profile=$VELO_S_PROFILE"
    echo "startmode=$VELO_S_STARTMODE"
    echo "pkgs=$VELO_S_PKGS"
    echo "hostname=$VELO_S_HOSTNAME"
    echo "encrypt=$VELO_S_ENCRYPT"
} > /mnt/etc/velo/answers
chmod 0600 /mnt/etc/velo/answers
```
Reader (M2, inside `/install.site`, runs chrooted so paths are `/etc/...`):
```sh
profile=minimal startmode=L1 pkgs=""        # safe floor BEFORE parsing
if [ -r /etc/velo/answers ]; then
    # PARSE KEY=value lines (data, never sourced as code). Split on the FIRST
    # '=', strip any trailing CR (CRLF-safe), assign whitelisted keys only.
    while IFS= read -r _l; do
        case "$_l" in ""|"#"*) continue ;; *=*) : ;; *) continue ;; esac
        _k=${_l%%=*}; _v=${_l#*=}; _v=${_v%"$(printf '\r')"}
        case "$_k" in
        profile) profile=$_v ;; startmode) startmode=$_v ;; pkgs) pkgs=$_v ;;
        esac
    done </etc/velo/answers
fi
case "$profile"   in minimal|desktop|fortress) : ;; *) profile=minimal ;; esac
case "$startmode" in L1|L2|L3)                 : ;; *) startmode=L1 ;; esac
# pkgs re-validated token-by-token below before any pkg_add list is written.
```

---

## 3. Profiles & packages — **byte-consistent with `src/velo-install`**

The site set carries one `*.list` per profile under `/usr/obj/_pkgs/`. These lists
are the **mandatory base** for each profile and MUST equal `profile_pkgs()` in
`src/velo-install` exactly. Cross-check table (copy in both places; CI asserts
equality — see §8):

| profile  | `/usr/obj/_pkgs/<profile>.list` (== `profile_pkgs()`)                          |
|----------|----------------------------------------------------------------------------|
| minimal  | `git curl tmux vim`                                                         |
| desktop  | `xfce xfce-extras firefox chromium git curl tmux vim mpv`                   |
| fortress | `tor torsocks wireguard-tools gnupg pwgen git tmux vim mupdf`               |

(One token per line in the `.list` files — `pkg_add -l` reads a newline list.
The space-joined form above is the `profile_pkgs()` echo; the packer splits it.)

- **`pkgs=` from the TUI** are *additional* opt-ins the operator checked; they are
  unioned with the profile list at install.site time. (In M1 the checklist
  universe IS the profile list, so today `pkgs ⊆ profile list` — but the contract
  allows future extra opt-ins without changing the format.)
- **install *sets* vs *packages*:** base/man/xbase/etc. are install **sets**
  handled by `install.conf`'s `Set name(s)` line in M1, NOT by site/pkg_add. M2's
  lists are `pkg_add` packages only. The `_gic_sets` tokens in M1
  (`+* -game* -x11*` for minimal, `+* -game*` otherwise) stay in M1; M2 does not
  duplicate them. Cross-check: **minimal drops x11 sets** in M1, so the minimal
  pkg list correctly contains **no X packages** — consistent.

---

## 4. The preset file tree (rooted at `/`)

`site79.tgz` is a gzip tarball whose members are **rooted at `/`** and extracted
by the installer with `tar -xzphf` **into the target root** as the *last* set
(`constraints.md` §6). So a member `etc/doas.conf` lands at `/etc/doas.conf` on
the target. The authoring tree lives under `site/` in the repo; the packer
(`build/make-site-tgz.sh`) tars `site/`'s contents with `/`-rooted paths.

```
site/                                  (repo authoring root; packer tars its CONTENTS)
├── install.site                       -> /install.site   (0755) chroot hook, runs LAST
├── etc/
│   ├── velo/
│   │   ├── pf/                         level pf.conf variants (install.site picks one)
│   │   │   ├── pf.l1.conf              -> staged to /etc/pf.conf when startmode=L1
│   │   │   ├── pf.l2.conf              -> ...                       startmode=L2
│   │   │   └── pf.l3.conf              -> ...                       startmode=L3 (Tor)
│   │   ├── sysctl/
│   │   │   ├── sysctl.l1.conf          extra sysctl appended per level (L1=baseline)
│   │   │   ├── sysctl.l2.conf          L2 += IPv6 off, stricter
│   │   │   └── sysctl.l3.conf          L3 += L2 + anti-leak
│   │   └── README                      what this dir is; audit note
│   ├── doas.conf                       -> /etc/doas.conf (0600) wheel persist policy
│   ├── sysctl.conf                     -> /etc/sysctl.conf BASE (level file appended)
│   ├── login.conf.d/
│   │   └── velo                        -> /etc/login.conf.d/velo  (umask/limits class)
│   └── skel/                           -> /etc/skel/ (new-user dotfile template)
│       ├── .profile
│       ├── .kshrc
│       └── .Xdefaults
├── etc/X11/                            (desktop only — install.site prunes if !desktop)
│   └── xenodm/
│       └── Xsetup_0                    -> /etc/X11/xenodm/Xsetup_0 (optional tweak)
├── root/
│   └── .profile                        root shell rc (minimal)
├── usr/obj/_pkgs/                       OFFLINE package dir (PKG_PATH target; /usr/obj
│   │                                    = the largest auto-layout partition, see §4)
│   ├── minimal.list                    git/curl/tmux/vim         (== profile_pkgs)
│   ├── desktop.list                    xfce/.../mpv              (== profile_pkgs)
│   ├── fortress.list                   tor/.../mupdf            (== profile_pkgs)
│   └── .keep-empty                     (M2 ships LISTS only; the .tgz package files
│                                        are populated at M3 in the VM via
│                                        `pkg_add -n`/mirror snapshot — FLAGGED)
└── etc/tor/                            (fortress/L3 only — pruned otherwise)
    └── torrc                           SOCKS-only L3 client (User _tor, SOCKSPort
                                         127.0.0.1:9050, SafeSocks, ClientOnly)

build/
└── make-site-tgz.sh                        deterministic packer -> dist/site79.tgz
                                        (sorted, fixed mtime/uid/gid, reproducible)

dist/
└── site79.tgz                          packer output (gitignored; not committed)
```

Notes on the tree:
- **`/install.site`** is the chroot hook. It is the only executable; everything
  else is config/data. It must be `#!/bin/sh` (the *target's* `/bin/sh`, not the
  ramdisk) and POSIX-portable.
- **Level pf/sysctl variants** live under `/etc/velo/` (not directly at
  `/etc/pf.conf`), so the static tarball carries *all three* and `install.site`
  **copies the chosen one** to `/etc/pf.conf`. The unused variants remain under
  `/etc/velo/pf/` on the booted system — useful for the v0.2 L1/L2/L3 switcher.
- **`/usr/obj/_pkgs/`** is the offline `PKG_PATH`. M2 ships the **`.list` files**; the
  actual `*.tgz` package files (and their dependency closure) are populated at
  **M3 in the VM** (the Void host has no OpenBSD packages). FLAGGED below.
  *Why `/usr/obj` and not `/root/pkgs`* (Сессия 7, `docs/WORKLOG.md`): the stock
  auto-layout — the layout the softraid FDE boot depends on — gives `/` only
  ~239 MiB, too small for the ~134 MiB closure, and a custom disklabel to enlarge
  `/` broke the FDE boot. `/usr/obj` is the **largest** auto-layout partition
  (~8.2 GiB) and dead "scratch" space a fortress/desktop appliance never uses, so
  the closure fits without touching the layout. It is **separate from
  `/usr/local`** (pkg_add's write target — co-locating would double-peak the disk),
  and is **reclaimed (`rm -rf`) on the first-boot pkg_add success** to free the space.
- **No `home/` is shipped** — velo does NOT bake a populated home into the tree;
  the user `anton` is created by the installer (`install.conf`'s
  `Setup a user = anton`) and `install.site` only adjusts groups (§5). New-user
  dotfiles are delivered via `/etc/skel`, the dotfile delivery vector.
- **Profile-conditional members** (`etc/tor/`, `etc/X11/xenodm/`) are shipped in
  the *static* set but **pruned by install.site** when the profile/level doesn't
  use them (e.g. remove `/etc/tor/torrc` if `startmode!=L3`; don't enable xenodm
  if `profile!=desktop`). Shipping-then-pruning keeps one static blob.

---

## 5. `install.site` responsibilities (chroot, NO network) — ordered

Runs `#!/bin/sh`, chrooted at the new root, as the final install step. Order
matters; each step is local-only. (Pseudocode; real script authored alongside
this doc, validated `sh -n` on the host, behaviour FLAGGED for the VM.)

1. **Log + parse answers** (§2.3). Establish `profile`, `startmode`, `pkgs`
   with the safe floor `minimal`/`L1`/`` first, then **parse** `/etc/velo/answers`
   as KEY=value data (never sourced as code) + re-validate.
2. **Firewall — install the level pf.conf.**
   `cp /etc/velo/pf/pf.$lvl.conf /etc/pf.conf` (lvl from startmode). `chmod 0600`.
   - STATIC check only here (`pfctl -nf` unavailable on Void) → **verify in VM (M3)**.
   - `rcctl enable pf` is implicit (pf is on by default), but ensure `pf=YES` and
     the right `pf_rules=/etc/pf.conf` via `/etc/rc.conf.local` if needed.
3. **sysctl.** Base `/etc/sysctl.conf` is shipped; **append** the level file:
   `cat /etc/velo/sysctl/sysctl.$lvl.conf >> /etc/sysctl.conf`. (Append, never
   overwrite, so base hardening + level deltas compose.)
4. **doas.** `/etc/doas.conf` shipped (`permit persist :wheel` + a `nopass` rule
   for `pkg_add` during first-boot if needed). `chmod 0600 /etc/doas.conf`
   (doas requires not-group/other-writable). STATIC syntax check only;
   `doas -C /etc/doas.conf` → **verify in VM (M3)**.
5. **User creation.** Create `anton` (matches M1's `Setup a user = anton`):
   `useradd -m -G wheel,operator -s /bin/ksh anton` (groups per profile:
   fortress may add `_tor`-adjacent as needed at M3). Skel dotfiles copy from
   `/etc/skel` automatically. NOTE: M1's `install.conf` ALSO creates `anton` via
   `Setup a user = anton`; install.site must be **idempotent** — check
   `id anton` and only `usermod -G …` (adjust groups / shell) if the user already
   exists, rather than failing. Decision: **let install.conf create the user; let
   install.site only adjust groups + drop dotfiles.** (Avoids the double-create
   race. FLAGGED to confirm install.conf's user exists at site time.)
6. **Desktop display manager.** If `profile=desktop`: `rcctl enable xenodm`
   (the OpenBSD X display manager; `rcctl enable xenodm` + first boot starts it).
   Else (`minimal`/`fortress`): ensure xenodm is **disabled** and prune
   `/etc/X11/xenodm/Xsetup_0`. (fortress is a CLI/anonymity stack — no DM.)
7. **Profile pruning.** Remove members that don't apply:
   - `startmode!=L3` → `rm -f /etc/tor/torrc` (Tor torrc only needed for L3 rdr).
   - `profile!=fortress` AND `startmode!=L3` → also fine to drop tor bits.
   - `profile!=desktop` → `rm -rf /etc/X11/xenodm/Xsetup_0` & keep DM disabled.
8. **Compose the offline pkg list.** Final list = profile mandatory
   (`/usr/obj/_pkgs/$profile.list`) ∪ validated `pkgs`. Write to
   `/etc/velo/installed.list` (one token/line, de-duplicated with a `grep -qxF`
   **literal** match so `.`/`+` in package names are not treated as regex, each
   re-validated `^[A-Za-z0-9._+-]+$`). The list lives in `/etc/velo/`, **outside**
   the `PKG_PATH` dir, so `/usr/obj/_pkgs/` stays pure package blobs.
9. **APPEND the pkg_add block to `/etc/rc.firsttime`** (runs on first boot).
   Append (`>>`), never overwrite — rc.firsttime may already carry
   installer-generated lines; a **sentinel-grep guard** makes the append
   idempotent (a re-run cannot double-append). The `PKG_PATH` value **branches on
   `startmode`** for honesty about the network fallback:
   ```sh
   # L1/L2 (network open): local-then-mirror fallback
   export PKG_PATH=/usr/obj/_pkgs:installpath
   # L3 (fail-closed pf already loaded by /etc/rc -> mirror UNREACHABLE): local ONLY
   export PKG_PATH=/usr/obj/_pkgs
   if [ -s /etc/velo/installed.list ]; then
       if pkg_add -I -l /etc/velo/installed.list >/var/log/velo-pkg.log 2>&1
       then echo "velo: offline package install OK"
       else echo "velo: ERROR pkg_add FAILED -- see /var/log/velo-pkg.log" >&2  # LOUD, no silent partial
       fi
   fi
   ```
   - `-I` = no interactive prompts; `-l` = read package names from a file list.
   - **`/etc/rc` loads the level pf.conf BEFORE it runs rc.firsttime.** So at L3
     the fail-closed firewall is already active when pkg_add runs: only `_tor`
     egresses and rc.firsttime runs as **root**, not `_tor`, so the mirror is
     unreachable. Therefore **L3 PKG_PATH is local-ONLY** and the bundled offline
     **closure MUST be complete** (else first boot has missing packages and no
     network fallback — the loud-failure log surfaces this). L1/L2 keep the real
     `local-then-mirror` fallback (`/usr/obj/_pkgs:installpath`).
   - **DECISION on chroot-vs-firsttime:** packages are bundled locally, so they
     *could* be `pkg_add`'d inside the chroot. BUT pkg_add's dependency resolution
     and `ldconfig`/shared-lib hooks are more reliable on a *booted* system, and
     the offline closure completeness can't be guaranteed until M3. So **default =
     rc.firsttime** (fail-safe). An M3 flag may switch to in-chroot if the VM
     proves the closure is complete and chroot pkg_add is clean.
10. **Cleanup.** `chmod 0600 /etc/velo/answers`; `rm -f /install.site` is done by
    the installer automatically after it runs; scrub nothing secret (no secrets
    here). Log "velo site done: profile=$profile startmode=$startmode".

All of steps 2/4 (pfctl/doas -C) and 9 (pkg_add) are **STATIC-only on Void** and
explicitly **FLAGGED `verify in the 7.9 VM (M3)`**.

---

## 6. L1 / L2 / L3 pf.conf semantics

Three static `pf.conf` files under `/etc/velo/pf/`; `install.site` copies the one
matching `startmode` to `/etc/pf.conf`. All are **STATIC-validated** here
(`pfctl -nf` does not exist on Void) → **verify in the 7.9 VM (M3)**.

Design principles common to all levels:
- `set skip on lo` — loopback always passes (local services, X, Tor's own loop).
- **Default deny inbound** (`block in`), **stateful outbound** (`pass out keep
  state`) — the OpenBSD default-deny posture, tightened per level.
- No inbound services opened in v0.1 (no sshd pass rule by default; M1 sets
  `Allow root ssh login = no` and we don't ship a server profile). Anti-spoof on
  the egress interface.

### L1 — sane baseline (permissive-but-firewalled)
```
# velo pf.conf — L1 (baseline). block in default; pass out keep state.
set skip on lo
set block-policy drop
block in all                      # default deny inbound
block return out log              # (optional) visible local denies
pass out keep state               # stateful egress (any proto)
antispoof quick for { egress }    # drop spoofed src on the wan if
# ICMP for PMTU/diag, rate-limited
pass in inet proto icmp icmp-type { echoreq unreach }
```
- Semantics: **block in by default, pass out (stateful), allow loopback.** A
  normal desktop that initiates connections works; nothing can connect *in*.
- Use: the L1 "it just works, but the door is shut" baseline.

### L2 — tightened (L1 + IPv6 disabled + stricter)
```
# velo pf.conf — L2 (= L1 + IPv6 off + stricter egress).
set skip on lo
set block-policy drop
block in all
block out log inet6 all           # belt: drop any v6 that slips the sysctl off
pass out inet keep state          # IPv4 egress only
antispoof quick for { egress }
block in quick from urpf-failed   # unicast reverse-path filter
pass in inet proto icmp icmp-type { echoreq unreach }
# NO inbound; NO inet6 pass anywhere.
```
- Paired with `sysctl.l2.conf`: `net.inet6.ip6.forwarding=0` and, crucially,
  **disable IPv6 at the stack** (no global v6 addrs) — the pf `block out inet6`
  is the second layer so a leaked v6 packet is still dropped.
- Stricter egress: IPv4 only, urpf-failed drop, still default-deny in.
- **FLAG:** the exact 7.9 idiom to fully disable IPv6 (rc.conf.local / `ifconfig
  inet6 ...` / sysctl) confirmed in VM (M3). pf `inet6 block` is the fail-safe.

### L3 — lockdown / Tor-only (SOCKS-only, fail-closed)

The strongest level: **`block all`, and the only process allowed to touch the
network is Tor (user `_tor`).** Every other program reaches the outside world
EXCLUSIVELY through Tor's SOCKS proxy on `127.0.0.1:9050` (loopback is skipped, so
app→SOCKS passes); a program that does not speak SOCKS gets **nothing** — it cannot
leak to the clearnet, it simply fails. If Tor is down there is no path out at all
→ **fail-closed** (no anonymity-stripping fallback to a direct connection).

```
# velo pf.conf — L3 (Tor-only, SOCKS-only, fail-closed).
# Canonical, fully-commented rationale: site/etc/velo/pf/pf.l3.conf.
tor_uid = "_tor"
set skip on lo                    # loopback free: apps reach 127.0.0.1:9050 (Tor SOCKS)
set block-policy drop
block all                         # FAIL-CLOSED: deny in AND out by default
pass out quick proto tcp user $tor_uid keep state   # Tor — and only Tor — egresses
pass out quick proto udp user $tor_uid keep state   # parity / future UDP transports
# Everything else (incl. clearnet DNS) stays blocked: NO rdr-to, NO divert-to, NO
# direct egress for any non-_tor process.  No inbound at all.
```
- Semantics: **`block all` + only the `_tor` user egresses; every other program
  uses Tor's SOCKS `127.0.0.1:9050`.** No transparent redirect (no `rdr-to`/
  `divert-to`). `torsocks` resolves DNS through Tor, so there is no DNS leak; a
  non-SOCKS program is *blocked*, never leaked to the clearnet.
- Companion `torrc` (shipped under `/etc/tor/`, kept only when L3) — see
  `site/etc/tor/torrc`: `User _tor` + `DataDirectory /var/tor` (so pf's
  `pass out user _tor` matches and the privilege-drop survives), `SOCKSPort
  127.0.0.1:9050`, `SafeSocks 1`, `SocksPolicy accept 127.0.0.1/32` + `reject *`,
  `ClientOnly 1`.
- Companion `sysctl.l3.conf` = `sysctl.l2.conf` (IPv6 off) + anti-leak knobs.
- Boot-time invariant: `install.site.velo` re-asserts `/etc/pf.conf` from
  `/etc/rc.local` (idempotent, retried, loud) so a slow boot can never leave the
  permissive early-boot ruleset active (live-observed; WORKLOG S9).
- L3 implies the **fortress** set carries `tor`/`torsocks`; if a user picks
  `startmode=L3` with a non-fortress profile, install.site **adds `tor`** (else the
  box bricks on first boot with no route out).

> **Design history:** an earlier L3 used a *transparent* Tor gateway (pf `rdr-to`
> into Tor's TransPort + DNS into a DNSPort). It was **rejected** after live VM
> testing — a transparent single-host redirect is fragile on OpenBSD (Tor must read
> `/dev/pf` for the NAT lookup; `divert-to` is meant for forwarded gateway traffic,
> not the host's own packets). Replaced by the SOCKS-only model above in Session 9
> (commit 99c03a9); proven live (direct blocked, torsocks→real Tor exit,
> fail-closed). A future 2-box Whonix-style split could use transparent redirect
> cleanly — out of scope here.

| level | inbound | outbound | IPv6 | egress path |
|-------|---------|----------|------|-------------|
| L1 | block (deny) | pass out keep state | allowed | direct |
| L2 | block (deny) | IPv4-only keep state | **off** (sysctl + pf block) | direct (v4) |
| L3 | block (deny) | **block all** except `_tor` | off | **Tor only** (SOCKS 127.0.0.1:9050), fail-closed |

---

## 7. The packer — `build/make-site-tgz.sh` (DRY-RUN authoring tool)

A small POSIX/ksh script that builds `dist/site79.tgz` **deterministically** from
`site/`:
- Tar members **rooted at `/`** (so `etc/doas.conf` → `/etc/doas.conf`).
- **Reproducible:** sorted member order, fixed `mtime`, `--owner=root --group=wheel`
  (or `0`), no `.keep-empty`/`.gitkeep` in the output.
- Sets `install.site` mode `0755`, pf/doas/answers `0600`, configs `0644`.
- Emits a manifest (`dist/site79.manifest.txt`: path, mode, size) for review.
- Runs on the Void host (it only needs `tar`/`gzip`, both present). It does NOT
  populate `/usr/obj/_pkgs/*.tgz` — those are added in the VM at M3.
- Self-check: refuses to pack if any `/usr/obj/_pkgs/<profile>.list` disagrees with
  `profile_pkgs()` (greps `src/velo-install`) — keeps M1/M2 byte-consistent.

---

## 8. Validation done at M2 (static, on Void) + what is FLAGGED for the VM

**Done now (host, no OpenBSD):**
1. `sh -n install.site` and `sh -n build/make-site-tgz.sh` (parse-only) under bash
   AND `/usr/sbin/ksh` (oksh) — a construct that passes one but not the other is
   a bug (same rule as M1).
2. **Consistency assertion:** `/usr/obj/_pkgs/<profile>.list` == `profile_pkgs()` for
   all three profiles (the packer's self-check, also a standalone test).
3. **Answers round-trip:** write a sample `/etc/velo/answers`, **parse** it
   through install.site (data, never sourced), assert profile/startmode/pkgs
   parse and that a garbage value falls back to `minimal`/`L1`/``. A CRLF file
   must not silently demote to the floor (trailing CR is stripped).
4. **Injection guard:** an answers file with `profile=desktop; rm -rf /` or
   `pkgs=a;b` must NOT execute — re-validation drops the bad token; assert no
   metachar survives into the pkg list.
5. **pf.conf static lint:** structural grep (balanced rules, every level file
   present, L3 has `block all` + `pass out … user $tor_uid` and **no** `rdr-to`/`divert-to`), since `pfctl -nf`
   is unavailable.
6. Packer produces a byte-stable `site79.tgz` (same input → same sha256).

**FLAGGED — verify in the 7.9 VM (M3):**
- `pfctl -nf /etc/pf.conf` accepts all three level files; confirm L3 loads as
  `block all` + exactly the two `pass out … user _tor` rules (tcp, udp) with **no**
  `rdr-to`/`divert-to` (SOCKS-only fail-closed).
- `doas -C /etc/doas.conf` validates the policy (no nopass pkg_add rule).
- `rcctl enable xenodm` / `rcctl get xenodm` on a desktop install; `rcctl ls on`.
- `useradd`/`id anton` idempotency vs the install.conf-created user.
- `pkg_add -I -l /etc/velo/installed.list` from the offline `PKG_PATH` — and the
  **dependency-closure completeness** of the bundled `/usr/obj/_pkgs/*.tgz`. At **L3**
  this closure MUST be complete: the fail-closed pf (loaded by `/etc/rc` before
  rc.firsttime) makes the mirror unreachable, so L3 PKG_PATH is **local-only**.
- L3 end-to-end: `tor` installs and runs as `_tor`, SOCKS on `127.0.0.1:9050`,
  `torsocks` → `check.torproject.org` reports `IsTor:true`, and **direct egress
  fails** (fail-closed). (Proven live S9 — WORKLOG.)
- IPv6 truly off at L2/L3 (sysctl idiom + pf `inet6` block both confirmed).
- `site79.tgz` extracts LAST and `/install.site` runs chrooted (constraints §6).

---

## 9. What M2 deliberately does NOT do

- No live `pf`/`doas`/`pkg_add` execution (those tools are absent on Void; DRY-RUN).
- No populated `/usr/obj/_pkgs/*.tgz` — only the `.list` files; package blobs are an
  M3-VM step (offline mirror snapshot / `pkg_add -zn` closure).
- No L1/L2/L3 *switcher* on the booted system — v0.2 (PLAN.md). M2 only installs
  the **chosen start level**; it ships all three pf/sysctl variants under
  `/etc/velo/` so the future switcher has them.
- No secrets in the site set or answers file (the FDE passphrase lives only in the
  ramdisk per M1; it is never written to the target by M2).
- No modification of `src/velo-tui.ksh` (frozen, M0) or `src/velo-install` logic
  beyond the future M3 wiring that writes `/mnt/etc/velo/answers`.

---

## 10. Sources (grounded) / cross-refs

- `install.site(5)` — the `/install.site` chroot hook, extracted-last site set.
  <https://man.openbsd.org/install.site.5>
- `rc.firsttime(8)` / FAQ 4 — first-boot script, network up, `>>` append idiom.
  <https://www.openbsd.org/faq/faq4.html>
- `pkg_add(1)` — `-I` no-interactive, `-l file` name list, `PKG_PATH` local dir.
  <https://man.openbsd.org/pkg_add.1>
- `pf.conf(5)` — `set skip on lo`, `block`/`pass ... keep state`, `antispoof`,
  `user`, `block-policy`. <https://man.openbsd.org/pf.conf.5>
- `rcctl(8)` — `enable`/`disable`/`get` for services (xenodm/pf/ntpd).
  <https://man.openbsd.org/rcctl.8>
- `xenodm(1)` — the OpenBSD X display manager. <https://man.openbsd.org/xenodm.1>
- `doas.conf(5)` — `permit persist :wheel`, mode-0600 requirement, `doas -C`.
  <https://man.openbsd.org/doas.conf.5>
- Tor as a SOCKS proxy on OpenBSD (`SOCKSPort 127.0.0.1:9050`, `SafeSocks`; the box
  egresses only via the `_tor` user): Tor manual + OpenBSD `tor` port (`_tor` user).
  <https://2019.www.torproject.org/docs/>
- velo internal: `docs/constraints.md` §6 (site set / install.site / rc.firsttime),
  `docs/m1-design.md` §3.5 (`profile_pkgs` seam), `src/velo-install`
  (`VELO_PROFILES`, `VELO_STARTMODES`, `profile_pkgs()`, `Setup a user = anton`).
