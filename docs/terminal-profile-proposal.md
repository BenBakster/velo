# Дизайн-предложение: профиль `terminal` (backlog v0.3)

> **Статус: ПРЕДЛОЖЕНИЕ, не реализовано.** Профиль `terminal` помечен в
> `docs/SESSION-PLAN-2026-06-12.md` как «не добавлять до явного Sprint-planing».
> Этот документ готовит решение к спринту: фиксирует package list, точки
> интеграции в коде и план тестов. Кода в `src/velo-install` он НЕ меняет.
> Дата: 2026-06-14.

## 1. Зачем

Между `minimal` (CLI-only, без X) и `homely` (полный openbox-десктоп) есть
ниша: **графический терминал + dev-инструменты без оконного менеджера/DE**.
Юзкейс — рабочая станция «X11 + xterm + кириллица + dev-стек», запускаемая
через `startx` без панели/меню/файлменеджера. Легче homely (нет
openbox/tint2/thunar/firefox), но в отличие от minimal даёт UTF-8-терминал с
кириллицей (как и было доказано: кириллицу нормально показывает только xterm).

## 2. Package list (предлагаемый)

Базовый набор (`site/usr/obj/_pkgs/terminal.list`):

```
xterm
noto-fonts        # кириллица в xterm (как в homely)
git
curl
vim
tmux
```

Dev opt-in (через существующий checklist мастера, НЕ в базе):

```
ripgrep
jq
node
fzf
```

> **Решение для спринта:** что в базе, что opt-in. Предлагаю держать базу
> минимальной (то, без чего профиль не имеет смысла), а тяжёлые пакеты (`node`)
> — opt-in. `noto-fonts` обязателен в базе (иначе кириллица в xterm = кракозябры).

Профиль X11-сессии (skel): нужен `.xinitrc`/`.xsession`, который поднимает
**только** `xterm` (без openbox/tint2). Переиспользовать `.Xdefaults`/`.velo-xkb`
из homely (шрифт + UTF-8 + раскладки us/ua/ru Shift+Alt).

## 3. Точки интеграции в коде (для реализации в спринте)

| Файл / строка (на 2026-06-14) | Правка |
|---|---|
| `src/velo-install:86` `VELO_PROFILES="homely minimal fortress"` | + `terminal` |
| `src/velo-install:234-237` `profile_pkgs()` case | + ветка `terminal)` с базовым списком |
| `src/velo-install:593-594` whitelist `homely\|minimal\|fortress` | + `terminal` |
| `src/velo-install:484-489` set-mask case | `terminal` держит X-наборы (как `homely`/default `*)` — НЕ `-xbase*`) |
| `src/velo-install:1144-1146` меню профилей | + строка `"terminal -- X + xterm + dev, no DE"` (+ `idx_to_profile`) |
| `site/usr/obj/_pkgs/terminal.list` | новый файл = `profile_pkgs terminal` (1:1, см. xcheck) |
| `site/install.site.velo` whitelist `minimal\|homely\|fortress` | + `terminal`; prune-гейты: держать Xsetup_0 (нужен X), убирать torrc (если !L3) |
| skel: `.xsession`/`.xinitrc` | вариант «только xterm» для terminal (без openbox) |

## 4. Size-gate

`homely` требует ≥28 GiB (`VELO_HOMELY_MIN_BYTES`, `velo_profile_target_size_ok`,
`src/velo-install:712-721`). `terminal` легче (нет firefox/thunar/полного DE), но
X-наборы + dev-стек всё равно тяжелее minimal.

> **Решение для спринта:** либо (a) свой `VELO_TERMINAL_MIN_BYTES` (предлагаю
> **16 GiB** = 17179869184) и расширить `velo_profile_target_size_ok` на
> `terminal`, либо (b) без гейта (как minimal/fortress). Рекомендую (a) —
> 16 GiB, чтобы не повторить «16 GiB live run исчерпал /usr» из homely-истории,
> с запасом под X + dev.

## 5. План тестов (что добавить вместе с кодом)

**`tests/velo-install-test.ksh`:**
- `profile_pkgs terminal` содержит `xterm`, `noto-fonts`; НЕ содержит `openbox`/`firefox`.
- `idx_to_profile N` → `terminal` (индекс по позиции в меню).
- set-mask: `terminal` НЕ исключает `-xbase*`/`-xfont*` (держит X), но `-game*` есть.
- size-gate (если решение (a)): `velo_profile_target_size_ok DISK terminal`
  — accept ≥16 GiB, reject ниже, граница, нечитаемый label (по образцу секции 12b).
- behavioural: цель ниже порога отклоняется в `velo_execute` до confirm/crypto
  (по образцу 12c).

**`tests/site-validate.ksh`:**
- `xcheck`: `terminal.list` == `profile_pkgs terminal`; расширить цикл
  `for _p in minimal homely fortress` → добавить `terminal`.
- `VELO_PROFILES` drift-check → `"homely minimal fortress terminal"`.
- DRY-RUN: `profile=terminal` → Xsetup_0 сохранён, torrc убран при !L3.
- whitelist `install.site` содержит `terminal`.

## 6. Чего НЕ делать

- Не обещать кириллицу в wscons (текстовая консоль) — documented limitation OpenBSD.
- Не тащить openbox/tint2/панель — это уже `homely`.
- Не добавлять профиль без `terminal.list` и зелёных тестов (иначе xcheck/drift
  упадут, а публичное обещание «профиль есть» окажется непокрытым).

## 7. Оценка

Малый-средний объём: ~6 правок в `velo-install` + 1 list + skel-вариант +
~10–12 ассертов. Риск низкий (профиль аддитивен, существующие гейты
переиспользуются). Главное решение спринта — package list (§2) и size-gate (§4).
