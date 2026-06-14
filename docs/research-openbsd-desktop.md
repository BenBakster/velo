# Готовые «OpenBSD desktop» решения — research для velo (2026-06-05)

Курировано под velo (свой установщик 7.9 → зашифрованный преднастроенный hardened-десктоп;
преднастройка едет в site79.tgz). Отсеяны generic-Linux dotfiles.

## ГЛАВНОЕ: база OpenBSD даёт десктоп БЕСПЛАТНО
- В base уже есть WM: **cwm(1), fvwm(1), twm(1)** (+ctwm как Xsession-фоллбэк). Рабочий
  десктоп возможен БЕЗ единого pkg_add.
- Запуск: **xenodm(1)** + пользовательский **~/.xsession** (последняя строка = WM в foreground).
- Вывод для velo: **минимальный desktop-профиль = просто файлы в site79.tgz** —
  /etc/skel/.xsession (`exec cwm`/`exec fvwm`), опц. .cwmrc/Xresources, `rcctl enable xenodm`.
  Ноль внешних пакетов, ноль сети на 1-м бутте → идеально под fail-closed/offline velo.
- Owner-доки: FAQ11 (X) https://www.openbsd.org/faq/faq11.html ; install.site(5)
  https://man.openbsd.org/install.site.5 ; FAQ4 https://www.openbsd.org/faq/faq4.html

## TOP PICKS (что реально стащить в velo)
1. bfmartin/fvwm-config-on-openbsd — https://github.com/bfmartin/fvwm-config-on-openbsd
   FVWM-конфиг под OpenBSD, **Unlicense (public domain)**, fvwm в базе → рисованный десктоп
   БЕЗ пакетов. Кладёшь в /etc/skel. 54★. Зеркало: https://worktree.ca/bfmbfm/fvwm-config-on-openbsd
2. daniel-mueller/bsd-dots — https://github.com/daniel-mueller/bsd-dots
   Готовый **cwm + .xsession + Xresources** под OpenBSD/FreeBSD, **BSD-3-Clause**. Основа cwm-профиля.
3. Solène — OpenBSD extreme privacy setup (2024-06-08) —
   https://dataswamp.org/~solene/2024-06-08-openbsd-privacy-setup.html
   pf block-all, unwind+DoT, MAC-random, kill webcam/mic. Прямо в hardened-слой site79.tgz; пересекается с L1/L3.
4. azazelpy/openbsd-desktop — https://github.com/azazelpy/openbsd-desktop
   Актуальный (7.8) package-list + порядок настройки демонов для Xfce. Бери список пакетов
   (проверь LICENSE перед копированием кода). Современный форк isotop.
5. install.site(5) + dywisor/omir — https://github.com/dywisor/omir
   Owner-механизм velo: как паковать site-tarball + кастомный bsd.rd + autoinstall + локальное зеркало.

## Post-install бутстрапперы (референс архитектуры)
- outpaddling/desktop-installer — https://github.com/outpaddling/desktop-installer
  Зрелый кросс-BSD post-install (релиз 31.05.2026, 498 коммитов, 113★, BSD-2). Референс «что донастроить».
- isotop (ориг., ~2021, полу-заброшен) — split root.sh/user.sh; azazelpy — живой форк под 7.8.
- dane/desktop-openbsd — https://github.com/dane/desktop-openbsd — cwm+xenodm авто-конфиг.
  ⚠ БЕЗ ЛИЦЕНЗИИ — только как референс, переиспользовать формально нельзя.
- jhx0/openbsd-desktop-playbook — Ansible Xfce, BSD-2 — task-лист портируется в ksh.
- ⚠ Amonadidis/openbsd-xfce-install-script — OpenBSD 6.3, slim/consolekit — ЗАБРОШЕН, не тащить.

## Dotfiles / WM-конфиги
- daniel-mueller/bsd-dots (cwm, BSD-3) — см. выше.
- bfmartin/fvwm-config (fvwm, Unlicense) — см. выше.
- hckme4/dotfiles — dwm rice (BSD-2), но dwm = компиляция (лишний build-шаг).
- drkhsh dotfiles ветка _openbsd/dwm — https://git.drkhsh.at/dotfiles/ — качественные OpenBSD-правки dwm config.h.
- Victxrlarixs/OpenBSD — https://github.com/Victxrlarixs/OpenBSD — ценен hardening-гайдами + pf/doas (BSD-2, 33★).
- raffaelschneider/awesome-openbsd-desktop — https://github.com/raffaelschneider/awesome-openbsd-desktop
  Мета-список: 8 WM (cwm/fvwm/i3/dwm/spectrwm/openbox/bspwm) + 5 DE. Источник №1 для добора.

## OpenBSD-based десктоп-дистры (идейные соседи velo)
- FuguIta — https://github.com/ykaw/FuguIta — LiveUSB/in-RAM на OpenBSD, АКТИВЕН (под каждый релиз),
  дефолт WM = IceWM. Лучший пример «преднастроенного OpenBSD-десктопа». 576 коммитов.
- myfuguita (nabeken) — порт FuguIta на штатный release(8) build — референс сборки образа.
- adJ — https://pasosdejesus.github.io/usuario_adJ/ — OpenBSD + i18n (исп.), живой (7.8, 22.04.2026).
  Модель «дистро = OpenBSD + тонкий слой через site/патчи» = модель velo. Полезно для XDG-укр.
- ⚠ ResedaOS — НЕ НАЙДЕН (вероятно ошибка в названии; уточнить).

## Методички / радар
- Eric Radman — autoinstall — https://eradman.com/posts/autoinstall-openbsd.html
- Solène — getting started — https://dataswamp.org/~solene/2021-05-03-openbsd-getting-started.html
- vermaden — Valuable News (еженедельный BSD-дайджест) — https://vermaden.wordpress.com/
