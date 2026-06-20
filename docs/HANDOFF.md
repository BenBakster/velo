# velo — HANDOFF (после v0.3 release, 2026-06-20)

Состояние на конец последней сессии. Подробности по сессиям — `docs/WORKLOG.md`;
дизайн — `docs/m{0,1,2,3}-*.md`, `PLAN.md`. **Push:** при аварийном
восстановлении 2026-06-14 содержимое опубликовано на GitHub
(`docs/RECOVERY-2026-06-14.md`); дальнейший push — только по явному «пуш».

> **➡️ СЛЕДУЮЩАЯ СЕССИЯ — НАЧНИ ОТСЮДА:** **v0.3 release — ✅ ЗАКРЫТ**
> (2026-06-20, Т-800). Профиль `terminal` и switcher `velo-level` полностью реализованы.
> Все тесты (297 assertions в velo-install-test, 123 в site-validate, 15 в velo-level, 9 в velo-report) зеленые.
> Образ установочного носителя: `dist/velo79.img`.
>
> **Следующий шаг:** **(supervised) terminal qemu acceptance** и **metal re-test** на внешнем SSD.
>
> **VGA/visual acceptance — ✅ ЗАКРЫТА 2026-06-14 (KVM):** xenodm-greeter рисуется,
> вход anon → openbox+tint2, **кириллица «Привіт / Привет» видна в xterm И terminator**
> (`vm/vga-accept-4-xterm-cyrillic.png`, `vm/term-3-xterm.png`). Канон `homely-vga-accept.py`
> теперь честный — добавлена проверка `XTERM_WINDOW_MAPPED` (раньше «PASS» был пустым:
> serial-only, окна не было). Root-cause пустого окна: на OpenBSD `su -c` = login-class, НЕ
> команда → GUI не запускался; фикс — трейлинг-арг `su -l -s /bin/sh USER SCRIPT </dev/null`.
> Побочно: terminator-конфиг ломался (дубль layout, `6ce49bb`); base-xterm без Xft (faceName мёртв,
> кириллица идёт через core+`-u8`).
>
> **Следующий шаг:** **(supervised) metal re-test** на внешнем SSD — последнее физическое
> подтверждение (инсталляторная дуга и визуальная приёмка закрыты). USB-носителя сейчас нет
> (затёрт 2026-06-08) → запись по `docs/OPERATIONS.md` Шаг 2 на отдельную флешку, Ворота-СТОП.
>
> **Повтор acceptance (test harness):** `bash vm/homely-accept.sh` (install → fix-ttys → firstboot → verify).
> На уже установленном диске: `ln -sf homely-test-target.img vm/desktop-test-target.img &&
> python3 vm/desktop-fix-ttys.py && python3 vm/homely-verify.py`.
> ⚠ `desktop-fix-ttys.py` — test-only: включает tty00 только на VM-диске для serial-verify;
> этот шаг **не встраивается** в `install.site.velo` (не нужен реальному пользователю).

## Где мы сейчас

| Веха | Статус |
|---|---|
| **M0–M3-prep** (TUI, velo-install, site79, build-скрипты) | ✅ собрано, verified oksh+bash |
| **Этап 1** build-хост 7.9 ВМ (qemu/KVM) | ✅ 2026-06-05 |
| **Этап 2** сборка `velo79.img` в ВМ | ✅ 2026-06-05 |
| **Этап 3** test-boot DRY-RUN | ✅ 2026-06-05 |
| **Этап 4** `needs_vm` (pf/doas/offline-pkg/IPv6) + **L3 fail-closed** | ✅ 2026-06-05 |
| **Этап 5** деструктивная обвязка + реальная зашифрованная установка в ВМ | ✅ ядро (С5–С9) |
| **Бэклог-A** экран паролей root/anton (снят шим `velotest1`) | ✅ С8 |
| **Бэклог-B** `item7-live` — L3 SOCKS-only fail-closed доказан вживую | ✅ С9 (99c03a9) |
| **Бэклог-C** legacy/MBR режим для старого железа | ✅ ЗАКРЫТ (С10): код+тесты+Ворота-4+live-SeaBIOS-FDE-boot |
| **TUI-SAFE + TUI-POLISH** (термин Protection profile, step-counters, help-line, danger-гейт) | ✅ 2026-06-06 (`3bd8096`..`43783c1`) |
| **desktop-профиль** firefox-only XFCE + iwm WiFi | ✅ 2026-06-07 (`fb44d0f`), offline-verify |
| **Бэклог-P1** threat-model док (`docs/threat-model.md`) | ✅ P1-сессия (worktree velo-p17, `9a44aa8`) |
| **Бэклог-P7** ownership boundary (`docs/ownership-boundary.md`) | ✅ P7-сессия (worktree velo-p17, `b0625ee`) |
| **hybrid boot-mode** (диск ВЕЗДЕ: legacy+UEFI, FDE) | ✅ реализован `29af128` (Gate A GREEN qemu); остаточный caveat — live-приёмка на реальном Insyde/AMI UEFI не снята |
| **Бэклог-D / Этап 6** M4 — запись на реальный SSD | ✅ ПРОЙДЕН на железе 2026-06-08 (зашифр. XFCE ставится+грузится); носитель затёрт |

## Что закрыто в последней сессии (С10 / Бэклог-C код)
- **boot-mode `VELO_S_BOOTMODE=same|uefi|bios`** (default `same`): мастер ставит FDE-бокс под выбранную
  прошивку. uefi→`fdisk -iy -g -b 960` (GPT+ESP), bios→`fdisk -iy` (legacy MBR, active 0xA6). Переключение —
  ТОЛЬКО fdisk-аргументы (disklabel/bioctl/installboot не тронуты).
- **Детект (verify-first переписал план):** `^efi0 at bios0: UEFI`/`^efifb0 at mainbus0`→uefi, иначе
  `^bios0`→bios, иначе unknown. Записанный `acpi [5-9]` ОТВЕРГНУТ как ненадёжный (ложь в обе стороны).
- **fail-safe:** на реальном пути `same`+unknown = STOP (не угадывать); `velo_fdisk_args` = единый источник
  истины fdisk-аргументов для plan+real (анти-дрейф).
- Тесты: selftest 85, suite 146 (вкл. behavioral fail-safe 8c, доказан мутацией), site-validate 110.
- **LIVE-SeaBIOS-acceptance ✅:** пересобран `velo79.img`, bios-установка на throwaway-диск
  (`fdisk -iy`/softraid CRYPTO/`CONGRATULATIONS`), загрузка под SeaBIOS: `disk: fd0 hd0+ sr0*`
  → `Passphrase:` → `booting sr0a:/bsd` → `entry point`. Ни «No active partition», ни `sr0` без `*`.
  **Бэклог-C ЗАКРЫТ полностью.**

## Что закрыто в Сессии 9 (С9 / item7-live)
- **L3 = SOCKS-only fail-closed** (НЕ прозрачный Tor-шлюз): pf `block all` +
  наружу только `_tor`; приложения ходят через Tor SOCKS `127.0.0.1:9050`;
  не-SOCKS трафик не получает сети (нет клирнет-утечки). Прозрачный rdr-to/divert-to
  отвергнут (хрупок на single-host OpenBSD).
- **3 реальных бага** velo, вскрытых только живым прогоном, исправлены: torrc без
  `User _tor`; torrc без `DataDirectory /var/tor`; недетерминированная загрузка
  `/etc/pf.conf` на бутте → инвариант переутверждения pf в `/etc/rc.local`.
- **`dist/site79.tgz` актуален** — пересобран, несёт текущие `pf.l3.conf` / `torrc`
  (SOCKS-only) / `install.site.velo` (rc.local-инвариант).

## Проверки (зелёные, oksh `/usr/sbin/ksh` + bash; прогон 2026-06-14)
- `velo-install selftest` — **104/104**
- `tests/velo-install-test.ksh` — **249/249** (post-recovery: homely size-gate
  unit+behavioural restored, valid_wifi_value line-injection guard added,
  replay-duplicated scrub block removed)
- `tests/site-validate.ksh` — **115/115** (closure-validator parse-check restored,
  replay-duplicated rc.local/torrc blocks removed)
- `tests/integrity-test.ksh` — **27/27** (build-цепочка целостности; sha256-сайдкары)
- `tests/check-pkg-closure-test.sh` — **11/11** (unit tests; run standalone с `sh`)
- **LIVE (qemu/OVMF, реальный FDE-бокс, throwaway-диски):** T1 прямой egress
  blocked · T2 наружу только `_tor` · T3 `torsocks`→реальный Tor-exit (`IsTor:true`)
  · T4 `stop tor`→fail-closed (нет пути наружу) — **все PASS**.

## Ключевые факты (выверены по исходникам OpenBSD; `docs/constraints.md`)
- **box_strategy = ASCII**: консоль установщика (wscons, Spleen 8x16 ISO-8859-1)
  рендерит Unicode/DEC line-drawing как `?`. «Синева» = ANSI SGR.
- Ramdisk: `/bin/ksh`; есть `stty dd sed cat sleep`, НЕТ `printf head tput od tr awk`.
- Хука `install.sh` нет; точка внедрения — `/.profile` (вставка ПЕРЕД циклом меню
  `while :; do`, не append). НЕ класть `auto_install.conf`.
- Crypto: `print -r -- "$VELO_PASSPHRASE" | bioctl -s -c C -l /dev/sdNa softraid0`.
- Оффлайн-замыкание пакетов лежит на `/usr/obj/_pkgs` (самый большой auto-layout
  раздел; reclaim `rm -rf` после успешного `pkg_add`).

## Осталось
- **homely v0.2:** ✅ VGA/visual acceptance ЗАКРЫТА 2026-06-14 (KVM; кириллица в xterm+terminator,
  `XTERM_WINDOW_MAPPED`, скриншоты в `/vm/`) + ⬜ supervised metal re-test на внешнем SSD.
  Найдено+исправлено при приёмке: `su -c`-баг харнесса (OpenBSD) и дубль-layout terminator (`6ce49bb`).
- **homely v0.2 — ЗАКРЫТО в qemu (serial):** firstboot offline `pkg_add` + verify пакетов/dotfiles.
- **VGA acceptance script готов** (`vm/homely-vga-accept.py`, parse-checked): boot → FDE serial →
  xenodm sendkey login → screendumps → Cyrillic xterm → apps check → PASS/FAIL. Запускать только
  supervised (нужен KVM + homely-test-target.img).
- **VM hygiene script** (`build/vm-cleanup.sh`): dry-run по умолчанию, 76 кандидатов (~40 GiB).
  Запустить `--delete` только с явного ок Антона после просмотра кандидатов.
- **`terminal` профиль и `velo-level` CLI (v0.3):** ✅ РЕАЛИЗОВАНО. Профиль `terminal` (X + xterm + dev, лимит 16 GiB) полностью интегрирован. Утилита `velo-level`, диагностический `velo-report` и smoke-тест `velo-egress-test` развернуты и покрыты тестами.
- **Package closure validator:** stem-based (`build/check-pkg-closure.sh`); `--exact` режим;
  11 unit tests (`tests/check-pkg-closure-test.sh`). Версионные constraints — только через чистую
  OpenBSD 7.9 VM `pkg_add -n`.
- **tty00/serial — test-only, не продуктовый долг:** `desktop-fix-ttys.py` включает
  `tty00 on secure` только на тест-диске перед headless-verify; это инструмент VM-харнесса.
  `install.site.velo` **не должен** постоянно включать serial root-login — это расширяет
  attack surface без пользы реальному пользователю. Если потребуется CI-автоматизация —
  явный test-only механизм (отдельный флаг/post-step), не часть штатной установки.
- **Инсталляторная дуга M0–M4 — ЗАКРЫТА.** C (legacy/MBR), hybrid, TUI-SAFE/POLISH,
  metal D/M4 — всё сделано и доказано (qemu + железо 2026-06-08).
- **Остаточный caveat hybrid:** live-приёмка `0xEF`-на-MBR-ESP на реальном Insyde/AMI UEFI
  (U748) не снята — qemu/OVMF GREEN это не гарантирует. Если velo поедет дальше — первый
  metal-прогон гонять именно в hybrid.
- **Стратегическое решение (Ворота-0) ПРИНЯТО 2026-06-11:** направление = **installer framework**
  (зафиксировать узкую сильную роль «безопасный установщик зашифрованного OpenBSD»). Архив и
  SATYR-gateway-профиль отклонены на этой развилке.
- **Долги качества (из ревизии 2026-06-11, `docs/review-codex-2026-06-11.md` + аудит):**
  **Wi-Fi PSK долг ЗАКРЫТ** 2026-06-14: `site/etc/hostname.iwm0` — чистый template
  (ни `join`, ни `wpakey` в активных строках; repo-grep на `wpakey`/PSK чист),
  реальные креды пишутся только install-time из мастера; добавлена install-time
  валидация `valid_wifi_value` (newline/quote line-injection закрыт). **Build-цепочка целостности ЗАКРЫТА**
  2026-06-11: signify-сверка firmware (`openbsd-79-fw.pub`, закрыт plain-HTTP MITM) + `.sha256`-сайдкары
  образа (assemble/grow эмитят, write-usb/flash-sda сверяют до `dd`) + `build/lib-integrity.sh` +
  `tests/integrity-test.ksh` 27/27. Надёжность installer-а ЗАКРЫТА: pre-flight до destroy-gate +
  TOCTOU-ремень + mount-fail (hybrid FATAL / DEGRADED) + 12 поведенческих тестов.

## Hard stop (не нарушать автономно)
- **sda не трогать никогда** (Void-portable root).
- **Никакого `push`** без явного «пуш» от Антона.
- **Реальные диски** — только supervised (Ворота-СТОП).

## Как возобновить
- Репо: `~/Документи/_Проекты/velo` (git, GitHub-remote `origin` = `BenBakster/velo`;
  push только по явному «пуш»). `git log --oneline`.
- Тест-pdksh на Void: `/usr/sbin/ksh`. Демо рамки: `bash demo/tui-demo.ksh screenshot`.
- Сборка site: `ksh build/make-site-tgz.sh` → `dist/site79.tgz` (gitignored).

## Заметка (repo hygiene)
Владельцы файлов приведены к `thx1138` 2026-06-11 (`chown -R` + `git fsck` чист). Чтобы
рецидив не повторялся — **все правки в репо только под `sudo -u thx1138`**, не из-под root.
