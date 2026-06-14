# velo — безопасный установщик зашифрованного OpenBSD

**velo** — самодельный интерактивный установщик («свойвелосипед изкоробки»): рукодельный
ASCII-TUI (ksh + ANSI, работает в ограниченном ramdisk `bsd.rd` без `printf`/`awk`/`tput`),
который превращает **выделенный внешний носитель** в готовый, зашифрованный (softraid
CRYPTO / FDE), hardened десктоп/рабочую станцию OpenBSD 7.9 amd64 — с воспроизводимыми
**профилями защиты** и guarded-операциями над диском (многоуровневая защита от записи не на
тот диск). Цель: «воткнул носитель в любой ноут — завёлся» (BIOS, UEFI и hybrid).

Репозиторий **локальный, без remote**; push выполняется только по явному согласию.

## Статус (на 2026-06-13)

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
