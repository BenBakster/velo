# velo — ownership boundary (policy contract)

This document defines who owns each file on an installed velo system: what
velo **may recreate**, what it **may only append to**, what it must **never
touch**, and what it created but the user **may have edited**. It is a policy
contract, not a description of one tool — it is the **precondition for P2**
(the Velo Control Center must never silently clobber a user's edits) and for
**P6** (the update / migration story must know what it is allowed to rewrite).

> **Prime rule.** If velo does not know a path's ownership class, it does not
> touch it. Ownership knowledge is a precondition for any write.

The main text is English; a short Russian summary is at the end.

---

## Source of truth

`/etc/velo/` is the **canonical velo namespace**. Everything velo can keep
there, it keeps there:

- `answers` — the install-time choices (parsed as data, never sourced as code);
- the active protection mode (the chosen `startmode`);
- last-generated checksums of derived/shipped files — so velo can later tell
  "did the user edit this?" (see class 4). **planned (P2): `install.site.velo`
  does not yet record checksums; the class-4 detect-diff below depends on this
  being produced.**
- the installed-package manifest (`installed.list`);
- the profile definitions themselves: `pf/pf.l{1,2,3}.conf`,
  `sysctl/sysctl.l{1,2,3}.conf`.

Consequence for the firewall and sysctl: the **source of truth for the L1/L2/L3
profiles is `/etc/velo/pf/pf.l{1,2,3}.conf` and
`/etc/velo/sysctl/sysctl.l{1,2,3}.conf`**. `/etc/pf.conf` is the *active derived
artifact* copied from the chosen pf profile; the velo block inside
`/etc/sysctl.conf` is likewise derived from `/etc/velo/sysctl/*`. Neither
`/etc/pf.conf` nor the sysctl deltas are themselves the source of truth (see the
`/etc/pf.conf` policy section).

---

## Ownership classes

### Class 1 — velo-owned / overwrite-safe

velo's own namespace and files velo can regenerate from its source of truth.
velo may freely recreate these.

- `/etc/velo/*` (answers, active mode, `installed.list`, `pf/`, `sysctl/`,
  `README`; recorded checksums — **planned (P2)**)
- `/etc/skel/.kshrc`, `.profile`, `.Xdefaults` — velo-shipped login templates.
  These are the *template* (overwrite-safe); the per-user `$HOME` copies made at
  account creation are class 3 (user-owned), not these.
- `/root/.profile` — velo-shipped root login profile.
- `/usr/obj/_pkgs/{minimal,desktop,fortress}.list` + the offline closure
  `*.tgz` — build-fixed, velo-owned, **one-shot**: read at first boot and
  `rm -rf`'d after a successful `pkg_add` (self-pruning, not persistent).
- `/usr/local/bin/velo-*` — **planned (P2)**
- `/usr/local/libexec/velo-*` — **planned (P2)**
- `/usr/local/share/velo/*` — **planned (P2)**
- `/usr/local/share/applications/velo-control-center.desktop` — **planned (P2)**
- `/usr/local/share/pixmaps/velo.*` — **planned (P2)**

### Class 2 — velo-co-owned / append-only sentinel blocks

System files velo extends with a **single marked block**. velo may modify only
its own sentinel block; everything outside the markers is left untouched.

- `/etc/sysctl.conf` (opening marker `# --- velo: <mode> sysctl deltas ... ---`;
  the block content is derived from `/etc/velo/sysctl/sysctl.l{1,2,3}.conf`.
  Note: this block has only an opening marker — it runs to end-of-file — so the
  velo region is "from the marker onward", not strictly between two markers.)
- `/etc/rc.firsttime` (velo's offline `pkg_add` block, opening + `end` markers)
- `/etc/rc.local` (velo's `pfctl -f /etc/pf.conf` re-assert invariant,
  opening + `end` markers)
- `/etc/rc.conf.local` (managed only through `rcctl`, never hand-rewritten)

### Class 3 — user-owned / never touch after install

User files and profiles. velo may seed a starting template via `/etc/skel`,
but once a `$HOME` is created the copies there are the user's.

- `/home/*/.xsession`
- browser profiles
- user dotfiles (the `$HOME` copies of `/etc/skel/.kshrc`, `.profile`,
  `.Xdefaults`)
- user documents, keys, personal settings

### Class 4 — managed-origin / user-may-have-edited / detect-diff + ask

Files velo provides (either copied/derived at install time, or shipped as
static files in the site set) but which the user is likely to edit by hand.
Before any overwrite, velo must detect whether the file still matches the
velo-provided reference; if it differs, velo must not overwrite silently — it
backs up and asks. Only one of these is *derived at install time* (`/etc/pf.conf`,
copied from `/etc/velo/pf/*`); the rest are *shipped static* files that the
installer only chmods or prunes — their velo reference is the site-set version.

- `/etc/pf.conf` — derived (`cp` from `/etc/velo/pf/*`); see dedicated policy below
- `/etc/doas.conf` — shipped static; installer only sets `root:wheel 0600`
- `/etc/tor/torrc` — shipped static; installer prunes it if startmode ≠ L3
- `/etc/X11/xenodm/Xsetup_0` — shipped static; installer prunes it if profile ≠ desktop
- `/etc/login.conf.d/velo` — shipped static; installer does not touch it

---

## Ownership table

| Path / pattern | Class | Write mode | Source of truth | Install-time behavior | P2/P6 update behavior | Overwrite policy |
|---|---|---|---|---|---|---|
| `/etc/velo/*` | 1 | full create | self | velo writes its namespace | velo may regenerate | overwrite-safe |
| `/etc/velo/pf/pf.l{1,2,3}.conf` | 1 | full create | self | shipped profile defs | velo may regenerate | overwrite-safe |
| `/etc/velo/sysctl/sysctl.l{1,2,3}.conf` | 1 | full create | self | shipped profile defs | velo may regenerate | overwrite-safe |
| `/etc/skel/.kshrc`, `.profile`, `.Xdefaults` | 1 | shipped static | site set | shipped template | velo may regenerate template | overwrite-safe (template only; `$HOME` copies are class 3) |
| `/root/.profile` | 1 | shipped static | site set | shipped | velo may regenerate | overwrite-safe |
| `/usr/obj/_pkgs/*.list` + closure `*.tgz` | 1 | shipped static | site set | read at first boot | n/a | one-shot: `rm -rf` after successful `pkg_add` |
| `/usr/local/bin/velo-*` | 1 | full create | self | **planned (P2)** | velo may regenerate | overwrite-safe |
| `/usr/local/libexec/velo-*` | 1 | full create | self | **planned (P2)** | velo may regenerate | overwrite-safe |
| `/usr/local/share/velo/*` | 1 | full create | self | **planned (P2)** | velo may regenerate | overwrite-safe |
| `/usr/local/share/applications/velo-control-center.desktop` | 1 | full create | self | **planned (P2)** | velo may regenerate | overwrite-safe |
| `/usr/local/share/pixmaps/velo.*` | 1 | full create | self | **planned (P2)** | velo may regenerate | overwrite-safe |
| `/etc/sysctl.conf` | 2 | append (sentinel) | base + velo block | append marked block | update only own block | block-only |
| `/etc/rc.firsttime` | 2 | append (sentinel) | installer + velo block | append marked block | update only own block | block-only |
| `/etc/rc.local` | 2 | append (sentinel) | velo block | append re-assert block | update only own block | block-only |
| `/etc/rc.conf.local` | 2 | `rcctl` only | `rcctl` | enable/disable services | via `rcctl` only | never hand-rewrite |
| `/home/*/.xsession` | 3 | none | user | not written | never touch | never |
| browser profiles | 3 | none | user | not written | never touch | never |
| user dotfiles (`$HOME` copies of skel) | 3 | none (seed via skel) | user | seeded once via `/etc/skel` | never touch | never |
| `/etc/pf.conf` | 4 | full create (derived) | `/etc/velo/pf/*` | `cp` chosen profile | detect-diff + ask + backup | see pf.conf policy |
| `/etc/doas.conf` | 4 | shipped static | site set | shipped; `root:wheel 0600` | detect-diff + ask + backup | backup before replace |
| `/etc/tor/torrc` | 4 | shipped static | site set | shipped (pruned if not L3) | detect-diff + ask + backup | backup before replace |
| `/etc/X11/xenodm/Xsetup_0` | 4 | shipped static | site set | shipped (pruned if not desktop) | detect-diff + ask + backup | backup before replace |
| `/etc/login.conf.d/velo` | 4 | shipped static | site set | shipped (untouched by script) | detect-diff + ask + backup | backup before replace |
| unknown path / unknown class | — | none | — | — | — | **never touch (prime rule)** |

---

## `/etc/pf.conf` policy

This is the sharpest ownership conflict: velo creates `/etc/pf.conf`, but it is
the first file a user is likely to edit by hand.

- The **source of truth for the L1/L2/L3 modes is
  `/etc/velo/pf/pf.l{1,2,3}.conf`**. `/etc/pf.conf` is the *active derived
  artifact*.
- When the Velo Control Center (P2) switches profile, it may replace
  `/etc/pf.conf` **only if**:
  1. the current file matches the last velo-generated variant (unchanged), **or**
  2. the user has explicitly confirmed the overwrite.
- If `/etc/pf.conf` has been edited by hand (differs from the last
  velo-generated checksum):
  - show a diff / status;
  - offer a backup;
  - do **not** overwrite silently;
  - ideally save `/etc/pf.conf.velo-backup.TIMESTAMP` before replacing.

Rationale: declaring `/etc/pf.conf` fully user-owned after the first edit would
strip the Control Center of its purpose as a profile switch. So `/etc/pf.conf`
stays class 4 (managed-origin, detect-diff + ask), not class 3.

---

## Invariant rules

1. **Never overwrite without ownership knowledge.** If a path's class is
   unknown, velo does not touch it. (The prime rule, restated as an invariant.)
2. **Backup before destructive config replacement.** For class 4
   (managed-origin, user-may-have-edited): back up first, then overwrite only
   after an explicit confirm or if the file is unchanged from the last
   velo-generated state.
3. **Sentinel blocks are the only mutable region.** For class 2 (append-only):
   velo may update only its own block between the markers; everything outside
   the markers is left untouched.
4. **`/etc/velo` is the canonical velo namespace.** Whatever can live there,
   lives there: `answers`, active mode, the installed manifest, and the profile
   definitions (`pf/`, `sysctl/`). Last-generated checksums (the input the
   class-4 detect-diff in rule 2 depends on) are **planned (P2)** — not yet
   produced by `install.site.velo`.
5. **P6 hook.** The future `velo-update` / migration path is **required** to
   read this document (and any machine-readable manifest derived from it) as a
   policy contract before rewriting any config — it must honor the classes and
   the detect-diff + ask + backup rule for class 4.

---

## Summary

velo classifies every file on an installed system into four ownership classes:
**(1) velo-owned / overwrite-safe** (`/etc/velo/*`, plus planned P2 helpers);
**(2) velo-co-owned / append-only** (sentinel blocks in `/etc/sysctl.conf`,
`/etc/rc.firsttime`, `/etc/rc.local`, and `rcctl`-managed `/etc/rc.conf.local`);
**(3) user-owned / never touch** (`.xsession`, browser profiles, user
dotfiles); **(4) managed-origin / user-may-have-edited** (`/etc/pf.conf`,
`/etc/doas.conf`, `/etc/tor/torrc`, `/etc/X11/xenodm/Xsetup_0`,
`/etc/login.conf.d/velo`) — which velo backs up and never overwrites silently.
The source of truth for the L1/L2/L3 profiles is `/etc/velo/pf/*`; `/etc/pf.conf`
is the active derived artifact. The Control Center (P2) and the update story
(P6) must read this contract before writing.

## Краткое резюме (RU)

velo делит файлы установленной системы на **4 класса владения**: (1)
**velo-owned / overwrite-safe** — собственный namespace `/etc/velo/*` (+
запланированные хелперы P2); velo может пересоздавать. (2) **velo-co-owned /
append-only** — velo дописывает только свой маркированный блок в
`/etc/sysctl.conf`, `/etc/rc.firsttime`, `/etc/rc.local` (и через `rcctl` —
`/etc/rc.conf.local`); чужое содержимое нетронуто. (3) **user-owned / never
touch** — `.xsession`, browser-профили, пользовательские дотфайлы после
создания HOME. (4) **managed-origin / user-may-have-edited** — `/etc/pf.conf`,
`/etc/doas.conf`, `/etc/tor/torrc`, `/etc/X11/xenodm/Xsetup_0`,
`/etc/login.conf.d/velo`: velo делает backup и **не затирает молча** (detect-diff
+ ask). Источник истины для профилей L1/L2/L3 — `/etc/velo/pf/*`; `/etc/pf.conf`
— активный производный артефакт. Panel (P2) и update (P6) обязаны читать этот
контракт перед записью. Главное правило: **не знаешь класс пути — не трогай.**
