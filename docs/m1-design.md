# velo M1 — `velo-install` design (DRY-RUN 7-screen wizard)

Status: design (Ворота-3 input). Implements the M1 milestone from `PLAN.md`,
built on the `src/velo-tui.ksh` API (M0, frozen — do **not** modify it).

**ABSOLUTE SAFETY:** M1 is **DRY-RUN**. `velo-install` WRITES NOTHING to any
disk and NEVER executes `fdisk` / `disklabel` / `bioctl` / `newfs` / `dd`. It
only **prints** the planned shell commands and the generated `install.conf`.
The destructive path is M3/M4, gated behind the summary screen (the Ворота-СТОП).

All facts below are grounded in OpenBSD source / man pages; the exact question
strings come from `distrib/miniroot/install.sub` and `autoinstall(8)` — see
**§9 Sources**.

---

## 1. The autoinstall reality that shapes the whole design

Verified against OpenBSD source and `autoinstall(8)`:

1. A response file is line-oriented `question = answer`; `question` may be any
   non-ambiguous whitespace-separated substring of the real installer prompt
   (the `?` is dropped). Example from the man page: `System hostname = server1`.
2. **Guided full-disk encryption is interactive-ONLY.** The
   `Encrypt the root disk with a (p)assphrase or (k)eydisk?` question is asked
   only in an interactive install — **never under `autoinstall(8)`**. Therefore
   a passphrase **cannot** be delivered through `install.conf`.

Consequence for velo: encryption is **not** an `install.conf` line. Instead, when
the user asks for encryption, velo plans a **manual pre-install shell sequence**
(`fdisk` → `disklabel` RAID slice → `bioctl -c C` CRYPTO volume) that runs at the
ramdisk `(S)hell` *before* `install`, and the generated `install.conf` then points
`Which disk is the root disk` at the **resulting softraid `sd` unit** (whole disk).
This is exactly how the installer's own `encrypt_root()` does it, and it is the
only way to combine FDE with a scripted install. M1 only PRINTS this sequence.

This split — **plan_crypto → shell script**, **gen_install_conf → response file**
— is the central design decision and the reason the two generators are separate
pure functions.

---

## 2. State model

A flat set of `VELO_S_*` globals (ksh has no associative arrays we can rely on in
pdksh 5.2.14; flat scalars are the portable choice). The wizard never holds two
screens' state in one struct — one datum per screen (M1 req §5).

| Global | Set by screen | Meaning / domain |
|---|---|---|
| `VELO_S_DISK`        | (1) disk        | raw device name, e.g. `sd0` / `wd0` (validated `^sd|wd`) |
| `VELO_S_ENCRYPT`     | (2) encrypt?    | `yes` / `no` |
| `VELO_S_PASSPHRASE`  | (2) passphrase  | secret; lives ONLY here + `VELO_PASSWORD`; cleared after plan built |
| `VELO_S_HOSTNAME`    | (3) hostname    | RFC-952/1123 label (validated) |
| `VELO_S_PROFILE`     | (4) profile     | `minimal` / `desktop` / `fortress` |
| `VELO_S_PKGS`        | (5) packages    | space-separated package names (re-indexed from checklist) |
| `VELO_S_STARTMODE`   | (6) start mode  | `L1` / `L2` / `L3` |
| `VELO_S_ROOTDISK`    | derived         | the disk `install.conf` actually targets (see §5) |

Derived, never stored as wizard state but recomputed in the generators:
- the **crypto chunk disk** (= `VELO_S_DISK`) and the **CRYPTO sd unit** (a
  placeholder `sdN` in DRY-RUN, since the real unit only appears after `bioctl`
  attaches at install time — §5).

Screen indices map 1:1 to the brief: (0) welcome, (1) disk, (2) encrypt+pass,
(3) hostname, (4) profile, (5) packages, (6) start mode, (7) summary/Ворота-СТОП.

### Navigation contract
- A screen returns `0` on confirm, `1` on ESC/cancel.
- ESC on any screen ≥1 steps **back** one screen (re-prompt previous datum); ESC
  on screen 0/back-past-start offers Quit. The summary's **No** also steps back to
  screen 1 so the user can revise. This keeps every datum revisable before the
  single irreversible gate, matching the Ворота discipline.
- Defaults: highlight starts at index 0; checklists start all-OFF (M1 req §4). So
  the *first* radio entry is the sensible default: profile `minimal`-first?  No —
  **`desktop` first** (the v0.1 product is a hardened desktop, per PLAN.md), then
  `minimal`, then `fortress`. Start mode lists **`L1` first** (most permissive
  baseline), then `L2`, `L3`. Documented here so the ordering is intentional.

---

## 3. Pure, testable functions (no tty, no globals-as-input where avoidable)

All take arguments and echo a result / set a single documented out-global, so they
can be unit-tested under bash AND oksh with no terminal. None of them write to disk.

### 3.1 `velo_list_disks` — INJECTABLE disk detection
```
velo_list_disks            # prints whitelisted disk names, one per line
```
- Source of truth: `sysctl -n hw.disknames` on OpenBSD.
- **Injection for host testing:** if `VELO_FAKE_DISKS` is set, use its value
  verbatim instead of calling `sysctl` (so it runs on the Void host and in CI).
- `hw.disknames` format is `name:DUID,name:DUID,...` (DUID may be empty), e.g.
  `sd0:4b84...,cd0:,sd1:954c...,wd0`. Parsing (pure pdksh, no `tr`/`awk`):
  split on `,` via `IFS=,`, strip `:DUID` suffix with `${tok%%:*}`.
- **Whitelist:** keep only tokens matching `^sd[0-9]+$` or `^wd[0-9]+$`
  (drops `cd*` install media, `fd*`, `rd*`, sr/raid pseudo names). The matcher is
  `is_valid_disk` (§3.2), reused so detection and validation can't diverge.

### 3.2 `is_valid_disk NAME` — whitelist predicate (exit status only)
```
is_valid_disk sd0   # 0
is_valid_disk wd12  # 0
is_valid_disk cd0   # 1
is_valid_disk "sd0; rm -rf /"  # 1  (injection guard)
is_valid_disk ""    # 1
```
Implementation: pure case glob, **anchored**, digits-only tail:
```
case "$1" in
  sd+([0-9])|wd+([0-9])) return 0 ;;   # ksh extended glob, anchored by case
  *) return 1 ;;
esac
```
`+([0-9])` is pdksh extended globbing (works in oksh and bash≥3). The `case`
pattern is implicitly anchored at both ends, so `sd0x`, `xsd0`, and any shell
metachar fail. This is the §M1-security `^sd|wd` gate — called before the name is
ever interpolated into a `/dev/...` path or a planned command.

### 3.3 `idx_to_disk INDEX` — index→label mapping (M1 req §3)
Selectors return only a 0-based index. velo keeps its **own positional list**
(captured the same order it passed items to `tui_menu`) and re-indexes:
```
idx_to_disk 0   # -> first name from velo_list_disks
```
Implemented with the same positional-stable pattern the TUI uses
(`set -- $list; eval echo "\${$((INDEX+1))}"`), guarded so out-of-range → empty +
nonzero. Parallel helpers `idx_to_profile`, `idx_to_startmode`, and
`idxset_to_pkgs LIST "$VELO_CHECKED"` (maps the space-separated checked-index list
back to package names) cover the radio/checklist screens.

### 3.4 `valid_hostname NAME` — predicate
RFC-1123 label: 1–63 chars, `[A-Za-z0-9-]`, no leading/trailing `-`. Pure case
glob; rejects empty, dots (we want a label, not FQDN — the DNS domain is a
separate installer question we leave default), spaces, and shell metachars.

### 3.5 `profile_pkgs PROFILE` — package set per profile (data table)
Returns the **default checklist** for a profile (the universe shown on screen 5;
all start unchecked per M1 req §4). Single source of truth, also used by the
checklist screen to build items. Proposed sets (packages, not base sets — base/
xbase/etc. are install *sets*, handled by `Location of sets`, not pkg_add):

| profile  | package universe (checklist items) |
|----------|-------------------------------------|
| minimal  | `(none)` — base only; checklist shows just `git`, `curl`, `tmux`, `vim` as opt-ins |
| desktop  | `xfce`, `xfce-extras`, `firefox`, `chromium`, `git`, `curl`, `tmux`, `vim`, `mpv` |
| fortress | `tor`, `torsocks`, `wireguard-tools`, `gnupg`, `pwgen`, `git`, `tmux`, `vim`, `mupdf` |

(Exact lists are a product decision, refined in M2's `site79.tgz`; the function is
the seam.) Packages are **not** put in `install.conf` — OpenBSD installs pkgs only
post-reboot. They are recorded for M2's `pkg_add -l list` and printed in the plan.

### 3.6 `plan_crypto DISK` — the manual FDE shell sequence (PRINTS only)
Emits the exact, copy-pasteable shell the operator (or M3) runs at the ramdisk
`(S)hell` **before** `install`, when encryption is requested. Grounded in
`install.sub:encrypt_root()` and FAQ 14. With `DISK=sd0`:
```
# velo: planned full-disk-encryption setup (DRY-RUN — not executed)
fdisk -iy -g -b 960 "sd0"                          # GPT, EFI sys partition
disklabel -E "sd0" <<'EOF'                          # one RAID slice 'a'
a
a

RAID

w
q
EOF
print -r -- "$VELO_PASSPHRASE" | \
    bioctl -Cforce -cC -l"sd0a" -s softraid0        # create CRYPTO vol
# CRYPTO volume attaches as the NEXT free sd unit; read it back, never hardcode:
#   bioctl softraid0   ->   parse the 'sd<N>' it reports
dd if=/dev/zero of="/dev/rsdNc" bs=1m count=1       # wipe first MB of new vol
```
Rules honoured:
- Passphrase via **STDIN pipe** (`print -r -- "$VELO_PASSPHRASE" | bioctl -s`),
  never argv/`ps` (M1 security contract). In DRY-RUN the literal printed is the
  string `$VELO_PASSPHRASE` (the **variable name**, not the secret) — the plan is
  a template, so the real passphrase is NEVER rendered to stdout/screen.
- Every device occurrence is **double-quoted**: `"sd0"`, `"sd0a"`, `"/dev/rsdNc"`.
- The CRYPTO sd unit is shown as `sdN` placeholder + an explicit comment to read
  it from `bioctl softraid0` at run time (M1 req: never hardcode the unit).
- `DISK` is validated by `is_valid_disk` before this function is called; the
  function refuses (nonzero, prints nothing destructive) if validation fails.

### 3.7 `gen_install_conf` — the response file (PRINTS only)
Pure function of the state globals → stdout. Emits canonical `question = answer`
lines, **every interpolated answer quoted-safe** (values are pre-validated; we
still avoid putting any user free-text into a position where a `=` or newline
could split a line — hostname/disk are charset-restricted, profile/startmode are
enum, packages don't appear here). See §4 for the exact lines.

---

## 4. Exact `install.conf` lines (grounded in install.sub / autoinstall(8))

Questions are written as the **shortest non-ambiguous substring** of the real
prompt (per `autoinstall(8)`), so they survive minor 7.9 wording drift. Each is
annotated with the full source prompt it matches.

```
# ---- velo-generated install.conf (DRY-RUN preview) ----
System hostname = velo-bsd
Password for root = <bcrypt-hash>            # prompt: "Password for root account?"
Change the default console to com0 = no
Setup a user = anton                         # prompt: "Setup a user? (enter a lower-case loginname, or 'no')"
Full name for user = anton                   # prompt: "Full name for user <login>?"
Password for user = <bcrypt-hash>
Allow root ssh login = no                    # prompt: "Allow root ssh login? (yes, no, prohibit-password)"
What timezone are you in = Europe/Kiev       # prompt: "What timezone are you in? ..."
Which disk is the root disk = sd1            # prompt: "Which disk is the root disk? ('?' for details)"
Use (W)hole disk or (E)dit the MBR = whole   # see note ‡
Location of sets = disk                      # prompt: "Location of sets? (...)"  (offline; cd/disk)
Set name(s) = +* -game* -x11*                # prompt: "Set name(s)? (or 'abort' or 'done')"
Directory does not contain SHA256.sig = yes  # prompt: "Continue without verification?" (offline sets)
```
Field rules:
- **`Which disk is the root disk`** — when `VELO_S_ENCRYPT=no` this is
  `VELO_S_DISK` (e.g. `sd0`); when `=yes` it is the **CRYPTO sd unit** produced by
  `plan_crypto` (placeholder `sdN`, real unit read from `bioctl` at run time).
  `gen_install_conf` uses `VELO_S_ROOTDISK`, set by the wrapper from whichever
  applies. This is the seam where the crypto plan and the response file meet.
- **‡ Whole-disk/layout prompt.** The modern installer asks
  `Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout?`. We answer
  `auto` (a.k.a. whole-disk default). The older `Use (W)hole disk ...` string is
  noted because older 7.x wording differs; M3 confirms the exact 7.9 token in the
  VM and the answer-token table below is the single place to fix it.
- `Password for root` / `Password for user` carry a **bcrypt hash**, never a
  plaintext (the man-page example uses `$2b$14$...`). In M1 DRY-RUN we print a
  placeholder `<bcrypt-hash>` token — M1 does not collect a root password (out of
  scope: brief screens are disk/encrypt/host/profile/pkgs/startmode). The line is
  emitted so the response file is complete and obviously-a-template.
  > **Session 8 update (item A — superseded).** The wizard now DOES collect the
  > root and user passwords: two new confirm-twice screens (`_wiz_rootpw`,
  > `_wiz_userpw`, router cases 3/4) fill secret globals `VELO_S_ROOTPW` /
  > `VELO_S_USERPW`. The `<bcrypt-hash>` token is now the **empty-hash fallback**
  > of `gen_install_conf` (`${VELO_S_ROOTPW_HASH:-<bcrypt-hash>}`), so the DRY-RUN /
  > `plan` / on-screen preview still print only the placeholder. `velo_execute`
  > hashes the two passwords with `encrypt -b a` (stdin pipe, `set +x`) and emits
  > the real `$2b$..` hashes into the 0600 response file ONLY. The old TEST shim
  > (`sed s/<bcrypt-hash>/velotest1/`) is REMOVED — no machine ships a hardcoded
  > password any more.
- Defaults ordering inside the file follows the installer's own question order
  (hostname → root pw → console → user → tz → disk → sets), so a human reading it
  against a real install sees them in sequence.

**Answer-token table (single fix-up point for 7.9 drift, confirm in VM at M3):**

| logical | question substring used | answer |
|---|---|---|
| hostname    | `System hostname`            | `$VELO_S_HOSTNAME` |
| layout      | `Use (A)uto layout`          | `auto` |
| sets loc    | `Location of sets`           | `disk` (offline) |
| sets sel    | `Set name(s)`                | `+* -game* -x11*` (profile-tuned) |
| verify off  | `Continue without verification` | `yes` (offline, no SHA256.sig) |
| root disk   | `Which disk is the root disk`| `$VELO_S_ROOTDISK` |

---

## 5. Encryption flow (screens 1→2→summary) — exact glue

```
disk = idx_to_disk $VELO_MENU_INDEX            # screen 1, validated ^sd|wd
if encrypt == yes:                             # screen 2 radio
    loop:                                      #   confirm-twice (M1 req §1)
        tui_password "passphrase:"   ; p1=$VELO_PASSWORD; VELO_PASSWORD=""
        tui_password "again:"        ; p2=$VELO_PASSWORD; VELO_PASSWORD=""
        [ "$p1" = "$p2" ] && [ -n "$p1" ] && break
        tui_msgbox "Passphrases differ — try again."
    VELO_S_PASSPHRASE=$p1 ; p1=""; p2=""        # clear temp copies immediately
    VELO_S_ROOTDISK="sdN"   # placeholder: real CRYPTO unit read from bioctl @run
else:
    VELO_S_ROOTDISK="$disk"
```
- Confirm-twice with re-loop on mismatch or empty (a mistyped FDE key is
  unrecoverable once piped to `bioctl`). Temp copies `p1/p2` cleared right after.
- `VELO_S_PASSPHRASE` is consumed only by `plan_crypto`, which prints the
  *variable name* not the value, then the wrapper clears `VELO_S_PASSPHRASE` once
  the plan text is built. The secret never reaches stdout, argv, a temp file, or
  the summary screen (the summary shows `encryption: yes (passphrase set)`).

---

## 6. Non-interactive dry-run / test entrypoint

`velo-install` dispatches on `$1` (mirrors the demo's `screenshot|interactive`):

```
velo-install                 # interactive wizard (needs a real tty)
velo-install plan            # NON-INTERACTIVE dry-run: read state from env,
                             #   print install.conf + crypto plan, exit. No tty,
                             #   no raw mode, no reads. CI/test path.
velo-install selftest        # run the pure-function assertions, print PASS/FAIL
```
- `plan` seeds the `VELO_S_*` globals from same-named env vars (with safe
  defaults), then calls `gen_install_conf` and (if `VELO_S_ENCRYPT=yes`)
  `plan_crypto "$VELO_S_DISK"`. It NEVER calls `tui_init`/`velo_readkey`, so it is
  pipe-safe and runs headless on the Void host. Example:
  ```
  VELO_FAKE_DISKS='sd0:abc,cd0:,wd1:def' \
  VELO_S_DISK=sd0 VELO_S_ENCRYPT=yes VELO_S_HOSTNAME=velo-bsd \
  VELO_S_PROFILE=desktop VELO_S_STARTMODE=L2 \
      ./src/velo-install plan
  ```
- `selftest` asserts the pure functions table (see §7) with a tiny `assert`
  helper; exits nonzero on first failure. This is the M1 acceptance harness,
  runnable under both `bash` and `/usr/sbin/ksh` (oksh) on the host.
- A guard at top: if invoked interactively but `! -t 0`, print the `plan` hint and
  exit 2 (same pattern the demo uses).

---

## 7. Test plan (runs on the Void host, no OpenBSD)

Run the **same** suite under `bash -n` / `bash`, and under `/usr/sbin/ksh -n` /
`/usr/sbin/ksh` (oksh) — a construct that passes bash but fails oksh is a real bug.

Pure-function assertions (in `selftest`):
1. `is_valid_disk`: `sd0`,`wd12`→0 ; `cd0`,`sd`,`sd0x`,`xsd0`,`""`,`sd0;rm`→1.
2. `velo_list_disks` with `VELO_FAKE_DISKS='sd0:a,cd0:,wd1:b,rd0:,sd2'`
   → exactly `sd0 wd1 sd2` (cd/rd dropped, DUIDs stripped, order preserved).
3. `idx_to_disk` over that list: `0→sd0`, `1→wd1`, `2→sd2`, `3→""`(nonzero).
4. `valid_hostname`: `velo-bsd`→0 ; `-bad`,`bad-`,`a.b`,`a b`,`""`,63-ok/64-bad.
5. `profile_pkgs minimal|desktop|fortress` → expected lists; unknown→empty.
6. `gen_install_conf` (encrypt=no, disk=sd0): output contains
   `Which disk is the root disk = sd0`, `System hostname = velo-bsd`, and the
   verification-off line; contains NO passphrase, NO `bioctl`.
7. `gen_install_conf` (encrypt=yes): root-disk line uses the CRYPTO `sdN`
   placeholder, still NO secret in output.
8. `plan_crypto sd0`: output contains `bioctl -Cforce -cC -l"sd0a" -s softraid0`,
   the `print -r -- "$VELO_PASSPHRASE" |` stdin pipe (literal var name, not a
   secret), `fdisk -iy ... "sd0"`, the `dd ... "/dev/rsdNc"` wipe; and the string
   does NOT contain any real passphrase. `plan_crypto "cd0"` / bad input → nonzero,
   prints nothing.
9. **DRY-RUN invariant:** grep the entire `plan` output ensures it contains no
   *bare* (unquoted/executed) destructive call — it is text only; assert the
   process touched no disk by construction (the functions only `_put`).
10. Trap/tty: `plan` and `selftest` never call `tui_init` (assert no `?25l` in
    output, exits fast with empty stdin) — same guarantee the demo's screenshot
    mode gives.

Manual (PTY) interactive smoke: walk all 7 screens, mismatch the passphrase once
to exercise the re-loop, ESC to step back, summary **No** to revise, **Yes** to
print the plan. Confirm the secret never appears on screen or in the summary.

---

## 8. What M1 deliberately does NOT do

- No disk writes, no `fdisk/disklabel/bioctl/newfs/dd` execution (DRY-RUN).
- No root/user password collection (not in the 7 screens) — emitted as template
  tokens so the response file is complete.
- No scrolling/paging of the disk list: a real machine shows a handful of disks
  and the menu box height = items+2 (M1 req §2). If detection ever returns more
  than fits the viewport, the wizard truncates to the first N and notes it (a
  pathological case; full paging deferred).
- No L1/L2/L3 *switcher* — v0.1 only records the **start** mode (PLAN.md). The pf/
  doas/sysctl payloads for each level land in M2's `site79.tgz`.
- Packages are not written to `install.conf` (OpenBSD installs pkgs post-reboot);
  they are recorded for M2 and shown in the plan.

---

## 9. Sources (grounded)

- `autoinstall(8)` — response file format (`question = answer`, substring match),
  EXAMPLES block (`System hostname = server1`, `Password for root = $2b$14$...`,
  `Setup a user = puffy`, `What timezone are you in = Europe/Stockholm`,
  `Location of sets = http`). <https://man.openbsd.org/autoinstall.8>
- `install.sub` (miniroot) — exact interactive prompts and `encrypt_root()`:
  - `Which disk is the root disk? ('?' for details)`
  - `Encrypt the root disk with a (p)assphrase or (k)eydisk?` (interactive-only)
  - `Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout?`
  - `Network interface to configure?`, `IPv4 address for $_if? (or 'autoconf'...)`,
    `DNS domain name? (e.g. 'example.com')`, `DNS nameservers? (...)`
  - `Password for root account?`, `Setup a user? (...)`, `Full name for user $ADMIN?`,
    `Allow root ssh login? (yes, no, prohibit-password)`
  - `Location of sets? (...)`, `Set name(s)? (or 'abort' or 'done')`,
    `Directory does not contain SHA256.sig` / `... Continue without verification?`
  - `print -r -- "$_passphrase" | bioctl -Cforce -cC -l${_chunk}a $_args softraid0`
  <https://github.com/openbsd/src/blob/master/distrib/miniroot/install.sub>
- Guided-encryption is interactive-only (no autoinstall): undeadly + OpenBSD
  commit notes. <https://undeadly.org/cgi?action=article;sid=20230308063109>
- `hw.disknames` format `name:DUID,...`: misc@ thread + FAQ 14.
  <https://www.openbsd.org/faq/faq14.html>
- softraid CRYPTO manual setup (`fdisk -iy`, RAID disklabel, `bioctl -c C`,
  next free sd unit, `dd` first MB): FAQ 14 + `bioctl(8)`.
  <https://man.openbsd.org/bioctl.8>
- Ramdisk userland constraints (no printf/od/tr/awk; `print` builtin; `stty`+`dd`
  key reads): `docs/constraints.md` (M0, already verified).
