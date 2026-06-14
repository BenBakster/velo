# velo — безопасный установщик зашифрованного OpenBSD

**velo** — самодельный интерактивный установщик («свойвелосипед изкоробки»): рукодельный
ASCII-TUI (ksh + ANSI, работает в ограниченном ramdisk `bsd.rd` без `printf`/`awk`/`tput`),
который превращает **выделенный внешний носитель** в готовый, зашифрованный (softraid
CRYPTO / FDE), hardened десктоп/рабочую станцию OpenBSD 7.9 amd64 — с воспроизводимыми
**профилями защиты** и guarded-операциями над диском (многоуровневая защита от записи не на
тот диск). Цель: «воткнул носитель в любой ноут — завёлся» (BIOS, UEFI и hybrid).

Репозиторий опубликован на GitHub; push выполняется только по явному согласию.
После аварии `git filter-repo` 2026-06-14 история пересоздана из уцелевших
артефактов (чистый базовый коммит `dbd1616` + post-recovery правки покрытия тестов) —
детали в `docs/RECOVERY-2026-06-14.md`.

> **Как собрать / записать / установить → `docs/OPERATIONS.md`** — канон
> последовательности: собрать → проверить → записать → загрузить → установить.

## Статус (на 2026-06-14)

- **Инсталляторная дуга M0–M4 — ЗАКРЫТА** (metal 2026-06-08). Поддержаны `bios` / `uefi` /
  `hybrid` boot-mode.
- **Новое направление v0.2 (2026-06-12):** guided pre-installer + профиль **`homely`**
  (openbox+tint2, UTF-8/кириллица в xterm/terminator, en_US + us/ua/ru Shift+Alt) вместо stock XFCE.
  См. `docs/SESSION-PLAN-2026-06-12.md`.
- **homely qemu acceptance (serial) — ✅ 2026-06-13:** firstboot offline `pkg_add OK`,
  `homely-verify.py` EXIT=0 на 28 GiB target. Детали — `docs/HANDOFF.md`, журнал в `docs/WORKLOG.md`.
  Остаток: VGA/screenshot кириллицы + supervised metal re-test.
- **Ворота-0 (2026-06-11):** узкая роль **installer framework**; SATYR-gateway и архив
  отклонены. SATYR (`satyr-whonix`) — отдельный daily-driver на Devuan.
- **D2-вердикт** (2026-06-08, XFCE) пересматривается после homely+кириллица; wscons
  (Ctrl+Alt+F1) кириллицу не даёт — documented limitation OpenBSD.
- Профиль **`homely` требует целевой диск не меньше 28 GiB**; меньший или
  неопределимый размер отклоняется до destructive gate.

## Профили защиты (Protection profile)

Стартовый уровень сетевой защиты, задаётся в мастере (по умолчанию **L1**):

- **L1 — baseline:** обычная сеть, базовый pf. Дефолт для домашнего стола.
- **L2 — hardened:** ужесточённый pf, IPv6 выключен (`block out inet6`).
- **L3 — Tor SOCKS-only (fail-closed):** pf `block all`, наружу ходит только пользователь
  `_tor`; приложения работают через Tor SOCKS `127.0.0.1:9050`, а не-SOCKS-трафик сети не
  получает (нет клирнет-утечки). Это **не** прозрачный Tor-шлюз. Полный L3-acceptance —
  `docs/m3-runbook.md` §5.2.

> Не путать с **профилями установки** (что ставится на диск): **`homely`** (домашний
> стол, default), **`minimal`** (CLI без X), **`fortress`** (L3/Tor/hardening) — см.
> `docs/SESSION-PLAN-2026-06-12.md` §4.1.

## Документация

- **`docs/OPERATIONS.md`** — канон последовательности (собрать → проверить → записать → установить). **Начни отсюда.**
- `docs/HANDOFF.md` — текущее состояние арки M0–M4, что закрыто/осталось.
- `docs/SESSION-PLAN-2026-06-12.md` — направление v0.2 (профиль `homely`) + acceptance §4.3.
- `PLAN.md` — решения Ворот 0–2, милстоуны, проверенные ограничения.
- `docs/m3-runbook.md` — детальный VM-рунбук (сборка, test-boot, зашифр. install, acceptance, M4).
- `docs/usb-write-runbook.md` — запись образа на USB (HARD STOP, guard-стек, карта дисков).
- `docs/constraints.md` · `docs/threat-model.md` · `docs/ownership-boundary.md` — ограничения ramdisk/TUI, модель угроз, граница ответственности.
- `docs/WORKLOG.md` — бортовой журнал по сессиям.
- `docs/RECOVERY-2026-06-14.md` — авария git и восстановление.
- `docs/review-codex-2026-06-11.md` · `docs/terminal-profile-proposal.md` — внешняя рецензия; дизайн-спека профиля `terminal` (backlog v0.3).
