# velo — план для новой Grok-сессии (2026-06-12)

> **НАЧНИ ОТСЮДА.** Этот файл — handoff после обсуждения с Антоном 2026-06-12.
> Предыдущий handoff (`docs/HANDOFF.md`) описывает installer-framework v0.1 (M0–M4 закрыты).
> Здесь — **новое продуктовое направление** и конкретные шаги.

---

## 1. Продукт (зафиксировано)

**Velo ≠ SecBSD-клон, ≠ gateway, ≠ privacy-дистрибутив, ≠ конкурент SATYR.**

Velo = **guided pre-installer для OpenBSD** (аналог Calamares на Linux):

- понятный TUI-мастер вместо сырого `install.sub`;
- FDE (softraid CRYPTO), hybrid BIOS/UEFI boot, guarded disk ops;
- ставит **любой base OpenBSD 7.9** (vanilla / SecBSD `install18.img` / FuguIta — цель, не блокер v0.2);
- на выходе — **дружелюбный домашний стол**, не cwm и не «голый XFCE».

**Целевой пользователь:** простой человек, который хочет поставить OpenBSD на выделенный/внешний диск и дальше работать в графике + терминале (Grok, Codex, Claude Code).

**SATYR** (`~/Документи/_Проекты/satyr-whonix`) — отдельный продукт (анонимная Devuan-ВМ + OpenBSD-шлюз). Velo его не заменяет.

---

## 2. Что уже сделано (не переделывать)

| Область | Статус |
|---|---|
| TUI-мастер (`velo-tui.ksh`, `velo-install`) | ✅ M0–M1 |
| `site79.tgz` + `install.site.velo` | ✅ M2 |
| Патч `bsd.rd`, сборка образа | ✅ M3 |
| Metal install D/M4 (внешний SSD, FDE, hybrid) | ✅ 2026-06-08 |
| Тесты (oksh+bash) | ✅ selftest 104, suite 238, site-validate 115, integrity 27 |
| Build-цепочка целостности (signify fw + sha256) | ✅ 2026-06-11 |
| Ворота-0 | ✅ installer framework (архив и SATYR-gateway отклонены) |

Репо: `~/Документи/_Проекты/velo` (локальный git, **без remote**, push только по явному «пуш»).

**Hard stop (не нарушать):**
- `sda` не трогать (Void-portable root);
- реальные диски — только supervised (Ворота-СТОП);
- правки в репо — под `sudo -u thx1138`, не из-под root.

---

## 3. Проблема, которую нужно решить (мотивация pivot)

### 3.1 Полевой опыт D2 (2026-06-08)

После установки velo на внешний SSD:
- UTF-8 «включён», но **кириллица в терминале не отображалась** (кракозябры);
- **только xterm** показывал кириллицу нормально;
- `xfce4-terminal` и текстовая консоль wscons — нет;
- ощущение «не daily driver» → десктоп деприоритизировали в пользу SATYR/Devuan.

### 3.1.1 Корневая причина (техническая, не «OpenBSD плохой»)

| Среда | Кириллица |
|---|---|
| wscons (Ctrl+Alt+F1, текстовая консоль) | **Нет** по дизайну OpenBSD: шрифт Spleen ISO-8859-1, не UTF-8. Не обещать. |
| xterm под X | **Работает**, если `.Xresources` + шрифт + locale правильные |
| xfce4-terminal | velo **не настроил** (в `.Xdefaults` нет utf8/locale/DejaVu) |

Текущий velo skel (дыры):
- `site/etc/skel/.Xdefaults` — `faceName: monospace`, без `utf8`/`locale`;
- `site/etc/skel/.profile` — только `LANG=en_US.UTF-8`, без `LC_CTYPE=uk_UA.UTF-8`;
- `desktop.list` — нет `noto-fonts`;
- нет pre-config XFCE panel/theme;
- профиль `desktop` = stock XFCE без «домашнего» UX.

### 3.2 Что сработало на Devuan (SATYR workstation) — эталон UX

Путь: `~/Документи/_Проекты/satyr-whonix/common-layer/site-root/`

- WM: **cwm → IceWM XP-Luna** (на Devuan); на OpenBSD-layer был **openbox + tint2**;
- терминал: **xterm** с полным UTF-8 в `.Xresources`;
- шрифты: `noto-fonts`, `dejavu`;
- локаль: `uk_UA.UTF-8` в `.xinitrc` / `.kshrc`;
- ощущение «хотя бы Windows XP» — панель, меню, файловый менеджер.

**Вывод:** XFCE не обязателен. Лучше перенести проверенный лёгкий стек, а не чинить голый XFCE.

---

## 4. Новое видение post-install (v0.2)

### 4.1 Профили установки (пересмотр)

| Профиль | Назначение | Default? |
|---|---|---|
| **`homely`** (новый, заменяет `desktop` как default) | Домашний стол: openbox+tint2 + xterm + Firefox + файловый менеджер + кириллица | **ДА** |
| **`minimal`** | CLI only, без X | нет |
| **`fortress`** | L3/Tor/hardening — только в «Дополнительно», не в простом flow | нет |
| ~~`terminal`~~ | *(backlog v0.3)* X + xterm + dev-пакеты без DE — идея хорошая, но без package list и тестов публичного обещания нет; не добавлять до явного Sprint-planing | — |

**Мастер по умолчанию:** профиль `homely`, startmode **L1** (обычная сеть), шифрование **да**.

**Минимальная цель для `homely`: 28 GiB.** Меньший или неопределимый размер
установщик обязан отклонить до destructive gate. Значение принято после того,
как 16-GiB QEMU-прогон переполнил `/usr` и `/usr/local`; 28-GiB acceptance
должен подтвердить фактический запас.

### 4.2 Стек `homely` (предпочтительный — уточнить на Воротах 1)

**Вариант A (перенос с SATYR OpenBSD-layer):**
```
openbox + tint2 + xterm + pcmanfm + firefox + noto-fonts + git curl
```
Конфиги-источник: `satyr-whonix/common-layer/site-root/home/anton/`

**Вариант B (XP-эстетика):**
```
icewm + XP-тема + xterm + firefox + noto-fonts + ...
```
Проверить наличие `icewm`, `icewm-themes` (или ручная тема) в OpenBSD 7.9 ports + offline closure.

**Общее для A и B:**
- `.xsession` → WM, не `startxfce4`;
- `.Xresources` — как SATYR (DejaVu Sans Mono, `utf8:2`, `locale:true`);
- `LANG`/`LC_CTYPE` = `en_US.UTF-8`; ввод кириллицы — раскладки us/ua/ru (Shift+Alt);
- xenodm enabled, светлый greeter;
- MOTD на первом входе: «терминал = xterm; кириллица в консоли Ctrl+Alt+F1 не работает — это норма OpenBSD».

### 4.3 Acceptance test (обязателен перед metal)

После чистой установки в qemu (потом на внешнем SSD):

1. xenodm → графический логин;
2. панель снизу, меню «как Пуск»;
3. xterm: `echo 'Привіт / Привет'` — кириллица читаема;
4. Firefox открывается;
5. файловый менеджер из меню;
6. `git --version`, сеть L1 (ping/curl);
7. скриншот для сравнения с Devuan SATYR.

**Статус §4.3 (2026-06-13 вечер):**
- ✅ **serial/qemu (автомат):** `homely-firstboot.py` → offline `pkg_add OK`;
  `homely-verify.py` EXIT=0 (пакеты homely, dotfiles, UTF-8 config, без XFCE).
  Драйвер: `bash vm/homely-accept.sh`. Журнал: `docs/WORKLOG.md` (сессия вечер).
- ⬜ **VGA/visual:** пункты 1–7 (xenodm, panel, кириллица в xterm, Firefox, thunar, скриншот).
- ⬜ **metal:** supervised re-test на внешнем SSD.

---

## 5. План работ (этапы)

### Этап 0 — Ворота 0 сессии (5 мин)

Прочитать:
- этот файл;
- `docs/HANDOFF.md` (installer baseline);
- `docs/constraints.md` (ramdisk/TUI ограничения);
- `satyr-whonix/common-layer/site-root/` (эталон dotfiles).

Подтвердить у Антона: **Вариант A (openbox+tint2) или B (icewm+XP)** для `homely`.

### Этап 1 — Быстрый фикс кириллицы (можно без смены WM)

**Цель:** даже на текущем XFCE xterm и xfce4-terminal показывают кириллицу.

Файлы:
- `site/etc/skel/.Xdefaults` — скопировать паттерн из SATYR `.Xresources`;
- `site/etc/skel/.profile`, `.kshrc` — `uk_UA.UTF-8`, `LC_CTYPE`;
- `site/usr/obj/_pkgs/desktop.list` — добавить `noto-fonts`;
- опционально: `xfconf` snippet для xfce4-terminal font (если WM пока XFCE).

Тест: `site-validate.ksh` + qemu screenshot.

### Этап 2 — Профиль `homely` (основной)

1. Новый `site/usr/obj/_pkgs/homely.list` (пакеты);
2. Обновить `install.site.velo` — профиль `homely` в whitelist;
3. Обновить `velo-install` — экран профиля: `homely` первым, `fortress` в advanced;
4. Skel dotfiles:
   - `.xsession` (openbox/tint2 или icewm);
   - `.config/openbox/`, `.config/tint2/tint2rc` (из SATYR);
   - или `~/.icewm/` с XP-темой;
5. `rcctl enable xenodm` для `homely` (как для `desktop`);
6. Пересобрать `dist/site79.tgz`, прогнать closure offline.

Тесты: расширить `site-validate.ksh` для `homely`; selftest если меняется `velo-install`.

### Этап 3 — Упростить мастер для «простого юзера»

- Default: `homely` + L1 + encrypt=yes;
- Убрать/свернуть экраны Tor/L3 из основного flow (оставить в «Дополнительно»);
- Summary-экран: человеческое описание («будет меню, файлы, терминал с украинским»).

### Этап 4 — first-boot / dev layer (после homely зелёный)

- `terminal` extras: `node`, `ripgrep`, `jq`, `tmux` в list или opt-in checklist;
- MOTD / `velo-welcome`: one-liner про установку Claude Code (`npm` или порт);
- P5 из бэклога: `velo-report` (диагностика) — по желанию.

### Этап 5 — Doc sync

- `README.md`, `PLAN.md` — позиционирование «Calamares для OpenBSD»;
- Убрать обещания privacy-дистрибутива / SecBSD parity;
- Зафиксировать: wscons без кириллицы = documented limitation.

### Этап 6 — Metal re-test (только supervised)

- Записать образ на **выделенный** внешний носитель (не sda);
- Acceptance test §4.3 на Fujitsu U748;
- Записать вердикт в `docs/WORKLOG.md`.

**НЕ в scope этой волны:** P2 Control Center, gateway profile, SATYR integration, multi-image SecBSD/FuguIta, `terminal` профиль (backlog v0.3).

---

## 6. Ключевые файлы

| Файл | Роль |
|---|---|
| `src/velo-install` | мастер, профили, `gen_install_conf` |
| `src/velo-tui.ksh` | TUI widgets |
| `site/install.site.velo` | chroot post-install |
| `site/usr/obj/_pkgs/*.list` | offline pkg lists |
| `site/etc/skel/*` | dotfiles нового пользователя |
| `build/make-site-tgz.sh` | сборка site |
| `build/assemble-media.sh` | образ install USB |
| `tests/site-validate.ksh` | валидация site |
| `satyr-whonix/common-layer/site-root/` | **эталон** UX (внешний репо) |

---

## 7. Команды для старта сессии

```sh
cd ~/Документи/_Проекты/velo
git log --oneline -5
ksh src/velo-install selftest
ksh tests/site-validate.ksh
ksh tests/velo-install-test.ksh
```

Сборка site (в среде с OpenBSD 7.9 или по runbook `docs/WORKLOG.md`):
```sh
ksh build/make-site-tgz.sh   # → dist/site79.tgz
```

---

## 8. Ворота 1 — РЕШЕНО (Антон, 2026-06-13)

1. **WM:** **openbox + tint2** (вариант A). IceWM/XP — нет.
2. **Локаль:** **`en_US.UTF-8`**; кириллица вводится через раскладки **us/ua/ru**, переключение **Shift+Alt** (`.velo-xkb`).
3. **Терминал:** **terminator + xterm** в меню (как сейчас).
4. **`desktop` (XFCE):** удалён, заменён на `homely` (коммит `3f5bd07`).
5. **Metal re-test:** после qemu-green; выделенный внешний SSD — по готовности Антона.

---

## 9. Критерий «сессия успешна»

- [ ] Кириллица в xterm после установки без ручных правок;
- [ ] Панель + меню + файловый менеджер «из коробки»;
- [ ] Ощущение «понятный домашний стол», не cwm и не stock XFCE;
- [ ] Тесты зелёные;
- [ ] WORKLOG дописан;
- [ ] (опционально) metal acceptance на внешнем SSD.

---

## 10. Контекст решений (чтобы не гонять заново)

| Тема | Решение |
|---|---|
| SecBSD как daily | Нет — слишком тяжёлый клон; velo = installer + homely desktop |
| SATYR | Отдельный проект, daily = Devuan |
| Gateway | Не роль velo |
| OpenBSD wscons кириллица | Не чинить в v0.2; документировать; работать в xterm |
| Installer arc M0–M4 | Закрыт, не ломать |
| D2 вердикт | Пересмотреть после homely+кириллица fix, не считать окончательным |
