# velo — план (живой документ)

**Что это:** «свойвелосипед изкоробки» — самодельный установщик OpenBSD **7.9 amd64**
с рукодельным «DOS-окошком» (ksh+ANSI TUI), ставящий зашифрованный (softraid
crypto) преднастроенный hardened-десктоп на внешний SSD.

**Репо:** git с GitHub-remote (`BenBakster/velo`, опубликован 2026-06-14). Локальные
коммиты — свободно; **push — только по явному согласию Антона** («пуш»).

## Решения (Ворота 0–2, согласовано)
- Интерфейс: **свой ksh+ANSI TUI** (не dialog/ncurses — их нет в ramdisk).
- Объём v0.1: мастер «спрашивает много» (диск, шифрование+пароль, hostname,
  профиль, чеклист пакетов, стартовый режим L1/L2/L3).
- Разрез: полный *переключатель* L1/L2/L3 → **v0.2**; в v0.1 мастер только
  задаёт стартовый уровень.
- Build-хост: свежая **OpenBSD 7.9 ВМ** из `install79.iso`.
- **box_strategy = ASCII** (проверено: консоль установщика — wscons, шрифт
  Spleen 8x16 ISO-8859-1; и Unicode, и DEC line-drawing рендерятся как `?`).
  «Синева» = ANSI SGR-цвет, рамка = `+ - |`. См. `docs/constraints.md`.

## Милстоуны
- **M0 — `src/velo-tui.ksh` + `demo/tui-demo.ksh`** ✅ собран, верифицирован под
  oksh+bash (screenshot parity), ревью 4 линзы, 3 блокера + 2 major закрыты.
- **M1** ✅ — `velo-install`: мультиэкранный мастер + генератор `install.conf`,
  DRY-RUN (ничего не пишет), тестируется под bash/oksh на Void.
- **M2** ✅ — `site79.tgz`: `install.site` (chroot) + `/etc/rc.firsttime` (1-й буст)
  + pf.conf L1/L2/L3 + doas.conf + sysctl + списки пакетов + dotfiles + xenodm.
- **M3-prep** ✅ — `build-velo.sh` (патч `bsd.rd` через `rdsetroot`/`vnconfig`,
  хук в `/.profile`) + setup свежей 7.9 ВМ + тест-загрузка в qemu/VBox.
- **M4 — запись на реальный внешний SSD + установка на железо** ✅ ПРОЙДЕН 2026-06-08
  (supervised, при живом участии Антона): зашифрованный XFCE установился и грузится.
- **Сверх плана (реализовано):** legacy/MBR boot-mode (Бэклог-C); **hybrid** boot-mode
  (`29af128`, диск грузится и на BIOS, и на UEFI); firefox-only XFCE desktop-профиль
  (`fb44d0f`); TUI-SAFE + TUI-POLISH; metal-фиксы (pre-wipe stale target + size-correct
  media detect, `a74537b`/`24e6db7`).

## ~~Статус после D/M4 + вердикт D2 (2026-06-08)~~ [история]
Инсталляторная дуга **закрыта**: velo надёжно ставит зашифрованный OpenBSD.
Полевой **вердикт D2** (кириллица-кракозябры, stock XFCE) — **пересмотрен** 2026-06-12:
причина не «OpenBSD плохой», а незаконченный skel (`.Xdefaults` без DejaVu/utf8).
Установочный USB-носитель затёрт 2026-06-08 (Void-portable).

## Стратегическое решение (Ворота-0, 2026-06-11)
Velo = **installer framework** (аналог Calamares для OpenBSD): guided TUI + FDE +
BIOS/UEFI/hybrid + профили. НЕ: privacy-дистрибутив, SecBSD-клон, SATYR-gateway.

**Текущий roadmap v0.2:**
- **homely** (default): openbox+tint2, DejaVu+noto, UTF-8/кириллица в xterm, xenodm.
  ✅ serial acceptance (qemu); ⬜ VGA/visual acceptance; ⬜ supervised metal re-test.
- **minimal**: CLI-only, без X. ✅ Фикс set-mask (`-xbase* -xfont* -xserv* -xshare*`).
- **fortress**: L3/Tor/hardening. ✅ verified.
- **terminal** профиль: backlog v0.3 — без package list и тестов не добавлять.
- Остаточный hybrid caveat: live Insyde/AMI UEFI metal-прогон не снят.

Внешняя рецензия: `docs/review-codex-2026-06-11.md`.

## Проверенные ограничения (кратко, полностью — docs/constraints.md)
- Ramdisk shell: `/bin/ksh` (pdksh/oksh). Есть: `stty dd sed cat sleep`.
  НЕТ: `printf head tput od tr awk` → вывод через builtin `print`.
- `$TERM=vt220`, ISO-8859-1; hardcode CSI/SGR, без terminfo.
- Ключи: `stty -echo -icanon min 1 time 0` + `dd bs=1 count=1`.
- Хука `install.sh` нет — установщик `install.sub`; точка внедрения TUI —
  `/.profile`. НЕ класть `auto_install.conf` (взводит 5-сек таймаут).
- Crypto: `print -r -- "$PASS" | bioctl -s -c C -l /dev/sdNa softraid0`;
  до этого `fdisk -iy`, disklabel RAID-раздел, `dd` обнулить 1-й МБ; брать
  следующий свободный `sd`-юнит из вывода `bioctl softraid0`.
- `site79.tgz` ставится последним; `install.site` — chroot, без сети;
  пакеты — `PKG_PATH=<локальная дир> pkg_add -I -l list` (оффлайн).

## Этапы по сессиям и журнал
Разбивка остатка на этапы (1 сессия = 1 этап) и бортовой журнал — в
**`docs/WORKLOG.md`**. Каждая новая сессия: читать WORKLOG → делать ОДИН этап →
дописывать опись в его «Журнал». Сделано: этап A (M0–M3-prep) + этапы 1–4 +
ядро этапа 5 (реальная зашифрованная установка в ВМ + L3 SOCKS-only fail-closed,
доказан вживую С9, 99c03a9). Бэклог **C** (legacy/MBR boot-mode) — ЗАКРЫТ полностью
(С10: код+тесты selftest 85/suite 146 + Ворота-4 + live-SeaBIOS-FDE-boot вживую).
**D**/Этап 6 (M4 на реальный SSD) — ✅ пройден на железе 2026-06-08 (supervised). Дальше —
стратегическое решение Антона о направлении (см. «Статус после D/M4 + вердикт D2» выше).
