# velo — threat model, non-goals & product statement

Velo is a guided installer that turns a **dedicated target disk** into a
ready-to-use, encrypted, hardened OpenBSD 7.9 workstation with switchable
**protection profiles** and a Tor-only fail-closed egress guard.

> **Status note.** This document describes both shipped behaviour and planned
> capability. Where a capability is on the roadmap but not yet implemented, it
> is marked as such (see the backlog P-items in `docs/WORKLOG.md`). Read
> "planned (Pn)" as "not a current guarantee".

This document states — honestly and without marketing — what velo protects
against, what it does **not**, and where its boundaries are. It is the
load-bearing reference for the rest of the backlog: every other feature is
calibrated against the boundaries written here. The main text is English; a
Russian product statement and summary are duplicated at the end.

---

## What velo is

Velo does not promise anonymity or an OS in the class of Tails / Whonix /
Qubes. It promises **managed reduction of attack surface and leaks**: a
ready-to-use encrypted OpenBSD workstation with sane defaults, switchable
protection profiles (L1 / L2 / L3), a Tor-only fail-closed egress guard, a
control surface (the in-place L1/L2/L3 switch / Velo Control Center is a later
milestone — P2, roadmap v0.2; v0.1 chooses the starting profile at install),
and fewer manual-configuration mistakes.

The canonical term for the L1 / L2 / L3 switch is **protection profiles**, not
"security profiles" — the latter reads as a guarantee velo does not make. The
L3 profile is the **Tor-only fail-closed profile**, never an "anonymous mode".

---

## What velo is NOT (non-goals)

- **Not an anonymous OS.** Velo reduces accidental leaks; it does not make a
  user anonymous.
- **Not a Whonix replacement.** No separate gateway VM or gateway domain. Tor
  enforcement is host-local pf + a Tor SOCKS proxy, not an isolated gateway.
- **Not a Tails replacement.** No amnesia by design — velo installs a
  persistent encrypted system, it does not run as a forget-everything live OS.
- **Not a Qubes replacement.** No VM isolation and no disposable per-app model.
  A compromise inside the user session is not contained.
- **Not protection against** targeted 0-day exploits, firmware compromise,
  physical coercion, or global traffic correlation.

These names are listed only to help a reader calibrate expectations. No claim
of superiority or equivalence is made or implied.

---

## Protection profiles (L1 / L2 / L3)

The installer sets a **starting** profile. A full in-place L1/L2/L3 switch is a
later milestone (Velo Control Center); v0.1 only chooses the initial level.

### L1 — Normal / Baseline protection

**Goal:** a normal OpenBSD desktop without manual setup pain and without
unnecessary exposed-by-default surface.

**Protects against:**
- accidentally exposed inbound services;
- basic pf / doas / user / xenodm misconfiguration;
- loss of an unencrypted disk, **if FDE was selected**;
- the typical "installed OpenBSD and forgot to turn on baseline protection".

**Does NOT protect against:**
- direct clearnet egress;
- ISP / local-network observation;
- browser fingerprinting;
- a malicious application inside the user session;
- targeted exploit / kernel or browser 0-day.

**Summary:** sane encrypted desktop baseline, not a privacy mode.

### L2 — Restricted / Reduced network surface

**Goal:** a stricter ordinary desktop, without a Tor-only model.

**Protects against (in addition to L1):**
- IPv6 leaks / dual-stack surprises (IPv6 is disabled);
- part of the network surface, via stricter pf / sysctl / service posture;
- misconfiguration cases where the user expected an IPv4-only / more closed
  posture.

**Does NOT protect against:**
- direct IPv4 clearnet egress;
- tracking by IP;
- browser fingerprinting;
- traffic correlation;
- a compromised browser or application.

**Summary:** stricter direct-network workstation, not an anonymity mode.

### L3 — Tor-only fail-closed

**Goal:** eliminate accidental direct clearnet egress from ordinary
applications.

**Model:**
- pf `block all`;
- only user `_tor` is allowed out;
- applications reach the network through Tor SOCKS at `127.0.0.1:9050`;
- non-SOCKS traffic gets no network;
- if Tor is stopped, the system is **fail-closed** — there is no direct
  fallback to clearnet.

**Protects against:**
- accidental direct IP leaks;
- accidental direct DNS / clearnet leaks when SOCKS / torsocks is used
  correctly;
- applications that try to go out directly while L3 is active;
- the "Tor died → the system silently went to clearnet" failure.

**Partially protects against:**
- site tracking by IP — **if** the application actually goes through Tor;
- a local network observer who sees Tor traffic but not the direct
  destinations.

**Does NOT protect against:**
- browser fingerprinting;
- login-based deanonymization;
- malicious browser extensions;
- a compromised browser or application;
- a global passive adversary / traffic correlation;
- VM-grade isolation expectations;
- Whonix / Tails / Qubes-level threat models.

**Summary:** a Tor-only egress guard, not an anonymous OS.

---

## Adversary model

How each profile fares against a concrete adversary. **Protected** = designed
to stop it; **Partial** = helps but does not fully stop it (see notes);
**Not protected** = out of scope for that profile.

| Adversary | L1 | L2 | L3 | Notes |
|---|---|---|---|---|
| Lost / stolen target disk | Protected* | Protected* | Protected* | *only if FDE (softraid CRYPTO) was selected at install |
| Local network attacker / hostile Wi-Fi | Partial | Partial | Partial | inbound closed by pf; L3 also hides direct destinations behind Tor |
| ISP / passive network observer | Not protected | Not protected | Partial | L1/L2 egress is clearnet; under L3 the observer sees Tor traffic, not destinations |
| Website tracking by IP | Not protected | Not protected | Partial | L3 only if the app actually goes through Tor; non-Tor apps get no network |
| Website / browser fingerprinting | Not protected | Not protected | Not protected | velo does not ship an anti-fingerprinting browser; out of scope at every level |
| Malicious or compromised app | Not protected | Not protected | Not protected | no VM / per-app isolation; L3 still constrains egress to Tor but does not contain the app |
| Browser / kernel 0-day | Not protected | Not protected | Not protected | targeted exploitation is explicitly out of scope |
| Global passive adversary / traffic correlation | Not protected | Not protected | Not protected | inherent Tor limitation; velo adds nothing here |
| User misconfiguration | Partial | Partial | Partial | sane defaults + fail-closed L3 reduce footguns; they do not remove every one |
| Current host disk destruction / wrong target disk | Mitigated | Mitigated | Mitigated | multi-layer refusal: arming env gate + typed-confirm of the exact disk name (default-deny) + mounted-partition refusal; the USB-flashing tool additionally derives and refuses the live root disk — see Target disk boundary |

---

## Key honest boundary

This is the single most important calibration in this document.

- **Stream / circuit isolation — possible, on the roadmap (P3, not yet
  shipped).** The architecture *can* separate application traffic into
  independent Tor circuits using multiple `SocksPort`s with `Isolate*`
  directives (the same mechanism Whonix uses) — but v0.1 ships a single
  `SocksPort` with no isolation directives. Per-application circuit isolation
  and per-app launchers are backlog item **P3** (roadmap v0.3), not a current
  guarantee. The point of this row is the *direction* of the boundary: stream
  isolation is achievable here; compromise isolation is not.
- **Compromise isolation — NO.** Once an application (e.g. a browser) is
  exploited via RCE, velo does **not** contain it. Containing a compromised
  application requires a VM or a separate gateway — without virtualization this
  is physically not the same class of system. L3 still forces the compromised
  app's egress through Tor, but it does not isolate the compromise.

---

## Target disk boundary

Velo installs to a **dedicated target disk** and turns it into a ready-to-use
encrypted workstation. This is a guided installer for a dedicated target disk —
**not** an "external-only fortress".

- **External SSD** is the recommended v0.1 real-hardware target, because it is
  the safest choice for destructive testing.
- **A second internal disk / VM disk / spare test disk** is also a valid
  dedicated target.
- The **system / internal disk** is **not** a normal v0.1 path. It would
  require separate advanced / supervised guards and is not offered as an
  ordinary user scenario.
- The **current host root disk / `sda`** is **never** a target. This is
  enforced at multiple layers: the installer's destructive path requires an
  arming env gate, a typed confirmation of the exact disk name (default-deny),
  and refuses any disk with a mounted partition; the USB-flashing tool
  (`build/write-usb.sh`) additionally derives the live root disk and refuses to
  write to it. The installer does not match a literal `sda` by name — the
  protection is behavioural (busy-disk and root-disk derivation), which is why
  it holds regardless of how the host disk is named.

---

## Summary

Velo is a guided OpenBSD installer that produces an encrypted, hardened,
ready-to-use workstation on a dedicated target disk, with switchable protection
profiles (L1 baseline, L2 reduced network surface, L3 Tor-only fail-closed) and
a control surface. It reduces attack surface, configuration mistakes,
and accidental network leaks. It is **not** an anonymity tool and not a
substitute for Tails, Whonix, or Qubes: there is no amnesia, no gateway VM, and
no VM-grade isolation of a compromised application. Stream isolation across Tor
circuits is achievable in this architecture and is on the roadmap (P3); it is
not yet shipped in v0.1. Isolation of a compromised app is out of scope at
every level.

## Краткое резюме (RU)

**Product statement.** Velo — это управляемый установщик OpenBSD, который
превращает **выделенный целевой диск** в готовую к работе зашифрованную
hardened-станцию с переключаемыми **профилями защиты** (L1 базовый, L2
сниженная сетевая поверхность, L3 Tor-only fail-closed) и панелью управления
(переключатель L1/L2/L3 / Velo Control Center — отдельная веха P2, дорожная
карта v0.2; в v0.1 мастер задаёт только стартовый профиль).

Velo **не** обещает анонимность и не является заменой Tails / Whonix / Qubes:
нет amnesia, нет отдельной gateway-VM, нет VM-уровневой изоляции
скомпрометированного приложения. Velo даёт *управляемое снижение поверхности
атаки и утечек*, а не анонимность. Изоляция потоков по разным Tor-цепочкам
архитектурно достижима и есть в дорожной карте (P3), но в v0.1 ещё не
реализована; изоляция самого компрометированного приложения — вне рамок
(для этого нужна VM или отдельный шлюз). Целевой диск — выделенный
(рекомендуется внешний SSD); системный диск и `sda` хоста — никогда.
