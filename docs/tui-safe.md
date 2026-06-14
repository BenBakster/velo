# TUI-SAFE — safer disk picker before real hardware (pre-M4 safety)

**Статус:** спецификация + verify-first готовы (2026-06-06). **Код НЕ начат.** Это
узкий **safety**-пункт (НЕ косметика), который должен быть сделан **до D/M4** —
иначе на реальном железе пользователь выбирает диск по голому `sd0/sd1` и может
устроить `dd`-литургию не на тот накопитель. Идёт по дисциплине вайбкодинга
(Ворота 1→2→3→4, [[feedback-vibe-coding-gates]]), отдельным концерном.

> Решение Антона (С10): «косметика нужна, но **после TUI-SAFE**, иначе будем
> красить гильотину, у которой табличка `sd1` написана карандашом».

---

## Scope (строго)

**ТРОГАТЬ только:** экран выбора диска (`_wiz_disk`) + identity-эхо на summary и
на destroy-gate (`_wiz_summary`, `velo_confirm_destructive`).

**НЕ трогать:** L3 · boot-mode C (`VELO_S_BOOTMODE`/детект/`velo_fdisk_args`) ·
M4/`write-usb.sh` · общий дизайн TUI · `push`.

**НЕ делать сейчас** (→ TUI-POLISH, отдельный пункт): step counters · цвет
destructive-гейта · progress `[1/N]` · boxed ERROR · термин «protection profile» ·
root≠user enforcement · welcome-переработка.

---

## Цель

Перед реальной установкой пользователь видит не `sd0/sd1`, а обогащённую
идентичность диска: **name · size · type/source (если есть) · DUID (если есть) ·
маркер install-media (если надёжно) · маркер mounted/root (если надёжно) ·
warning, если диск подозрительный**.

Минимально приемлемая модель строки:
```
  sd0   29G    [install media?]    duid 9e4f…
> sd1   480G   target candidate    duid 0000… (none)
  wd0   512G   internal / mounted? duid abcd…
```

## Fail-safe (железно)

1. Диск **mounted / current root / надёжно опознанный installer media** → не давать
   выбрать ИЛИ требовать extra-danger confirm. **НЕ авто-скрывать по догадке**
   (ложное исключение прячет настоящую цель; ложный «safe» приглашает катастрофу).
2. Если свойство **определить нельзя** → писать буквально «**unknown / verify
   manually**», НЕ притворяться уверенностью, НЕ подставлять 0/имя/предыдущее значение.
3. **destroy-gate показывает ту же обогащённую идентичность**, что и summary:
   `sd1 / 480G / DUID … / target candidate` — мозг не должен терять контекст между
   экранами.

---

## Verify-first: что РЕАЛЬНО доступно в bsd.rd (recon С10, на реальных данных)

Источники: захваты `vm/*.log` (живой 7.9 RAMDISK_CD), исходники OpenBSD
(`disklabel.c`, man), `docs/constraints.md`. ramdisk-инструменты — **есть:**
`disklabel sysctl mount dmesg cat grep sed ksh(print) MAKEDEV fdisk bioctl`;
**НЕТ:** `awk tr head printf od expr basename dirname df`. Парсинг — только sed +
ksh `case`/`$(( ))`/parameter-expansion + `print`.

### SIZE + DUID — надёжность HIGH
- `disklabel <disk>` (read-only, без `-E`) печатает `bytes/sector: N` и
  `total sectors: M` → `size = M*N` байт. Формат стабилен (`disklabel.c display()`).
  Парс: `sed -n 's/^total sectors: *//p'` / `'s/^bytes\/sector: *//p'`.
- Human-формат без float/printf — ksh integer: подобрать единицу (T/G/M/K) по
  величине, десятые = `bytes*10/unit` → `$(( _t/10 )).$(( _t%10 ))$suf`. Валидировано:
  `33554432с→16.0G`, `937703088с→447.1G`, `1953525168с→931.5G`. **Это GiB
  (binary)** — меньше вендорской «480GB» наклейки; подписать честно или пометить GiB.
- Перед `disklabel` создать ноду: `( cd /dev && sh MAKEDEV "$d" ) 2>/dev/null || true`
  (rd делает ноды по требованию; velo это уже делает в `velo_run_crypto`).
- DUID: `velo_list_disks` уже парсит `sysctl -n hw.disknames` (`name:DUID,…`; DUID
  может быть пустым / имя без двоеточия). Для показа НЕ ре-стрипать: `name=${tok%%:*}`,
  `duid=${tok#*:}`; нет двоеточия/пусто/all-zero → «(none)». Или `disklabel duid:`.
- **Failure → «unknown»:** нет ноды (`No such file or directory`, exit 4) / нет
  носителя (`DIOCGPDINFO` err 4) / нечисловые поля → гейт `case ''|*[!0-9]*` → unknown.
  Имя `sdN/wdN` из `hw.disknames` — единственное всегда-надёжное поле.

### TYPE / MODEL / TRANSPORT — надёжность MIXED (только ХИНТ)
- Из dmesg (velo его уже читает в `velo_detect_bootmode`: `cat /var/run/dmesg.boot`,
  fallback `dmesg`). Attach-строка: `^sd0 at scsibus… <Vendor, Product, Rev>[ removable]`;
  size-строка: `^sd0: NNNNMB, 512 bytes/sector, N sectors`.
- model = текст между `<` и `>` (`sed 's/^[^<]*<//; s/>.*$//'`). removable = ksh
  `case *" removable"*`. USB ⇔ её `scsibusN` это `scsibusN at umassM` (`grep -q`).
- `wd*` — ДРУГАЯ грамматика (один model-стринг без запятых) → парс деградирует к
  «всё `<…>` как model». **Хинт, не авторитет:** `removable` есть и у CD; диск в
  USB-кармане может не ставить removable. Не определилось → «type unknown».

### INSTALL-MEDIA + MOUNTED/ROOT — надёжность MIXED (safety-critical)
- **rd0 = RAM-корень всегда** (`root on rd0a` в каждом логе); `velo_list_disks` его
  и так отбрасывает (только `sd*/wd*`). HIGH.
- `mount | grep "^/dev/<disk>[a-p] "` (= существующий `velo_disk_busy`) — надёжно
  для того, что **сейчас смонтировано**. HIGH для смонтированного.
- **ГЛАВНЫЙ GAP:** во время мастера/выбора/гейта смонтирован ТОЛЬКО rd0. Цель
  монтируется в `/mnt` лишь ПОСЛЕ auto-layout (на этапе install), а install-media
  (sd0) при выборе **вообще не смонтирован** → mount-«busy» install-media НЕ ловит.
  Никогда не трактовать «не busy» как «безопасно».
- Install-media опознаётся **эвристически** (НЕ авто-исключать, только warning):
  (a) уникальная disklabel-сигнатура `velo79.img` — FFS `a` + MSDOS `i` ~960 секторов
  (`disklabel sdN` → `Available … partitions are: a i`); velo владеет образом →
  сильная само-сигнатура; (b) самый маленький / removable; (c) стоковый installer
  дефолтит `[sd0]` (boot-диск) — но всплывает поздно, как corroboration.
- **Дизайн-правило: ENRICH + WARN, НЕ auto-hide.** Обогатить идентичность + пометить
  смонтированные `[MOUNTED]` + мягкий `[likely install media]` — но оставить
  pickable и опереться на typed-confirm + identity-эхо на destroy-gate (как
  host-овский `write-usb.sh` GUARD’ы, но через dmesg/disklabel, т.к. в rd нет awk/df).

---

## Definition of Done

- real oksh (`/usr/sbin/ksh`) + bash тесты зелёные (selftest + suite + site-validate
  не регрессят: сейчас 85 / 146 / 110).
- **fake-disk-inventory тесты** (инъекция через `VELO_FAKE_DISKS` + фейковые
  disklabel/dmesg/mount): показывает size; помечает/исключает mounted; не ломается
  при size/type/duid=unknown; summary И destroy-gate показывают обогащённую идентичность.
- live-VM smoke: экран выбора читаем, target **явно отличим** от install media.

## Зацепки в существующем коде (компонуем, не переписываем)

`velo_list_disks` (names+DUID) · `velo_disk_busy` (mounted) · `velo_detect_bootmode`
(уже читает `/var/run/dmesg.boot`) · `_wiz_disk`/`_wiz_summary`/`velo_confirm_destructive`
(куда встраивать) · injection-точки тестов `VELO_FAKE_DISKS` / `VELO_BOOTMODE_DETECT`.

---

## TUI-POLISH (отдельный пункт бэклога — ПОСЛЕ TUI-SAFE, но ДО D/M4 — реприор. Антона С10)

> Реприоритизация (С10): косметику тоже сделать **до записи на флешку**. Но порядок
> относительно TUI-SAFE сохраняется: **сначала TUI-SAFE** (safety-идентичность диска),
> **потом TUI-POLISH** — они правят одни экраны (пикер/summary/destroy-gate), и
> косметика впереди = двойная правка. Разделение концернов: TUI-SAFE владеет
> *содержимым* идентичности (size/type/DUID/маркеры на пикере+summary+гейте);
> TUI-POLISH владеет только *подачей* (нумерация шагов, термины, help-line, цвет/heading
> гейта, раскладка summary, welcome, root≠user) — НЕ меняет disk-safety-семантику.


Полезная косметика (снижает когнитивную нагрузку), но не safety: **step counters** в
заголовках (`Step 3/8:`); единый термин **«Protection profile»** (вместо «Start
hardening mode») + богаче описания L1/L2/L3 (`L3 — Tor-only fail-closed: only _tor …`);
единая нижняя **help-line** (`Enter=select Esc=back`), с разным смыслом Esc
(welcome→stock installer, gate→abort); **destructive-gate визуально отличить** (заголовок
в глаз; цвет если ANSI); более «карточный» **summary**; **progress `[1/N]`** (требует
обвязки парсинга stock-install — НЕ дёшево); **boxed ERROR**; продуктовый **welcome**;
**root≠user enforcement**. Всё это — **до D/M4** (реприор. С10), но **после TUI-SAFE**.
Внутри TUI-POLISH порядок: дешёвое сначала (counters, термины, help-line, summary-layout,
gate-heading), `progress [1/N]` + boxed ERROR — в конце (требуют обвязки парсинга
stock-install, НЕ дёшево; можно отложить, если расползается). БЕЗ
псевдо-иконок/Unicode/мыши/spinner/полного hw-report (box_strategy=ASCII).

---

## ЧЕКПОЙНТ — Ворота-0 done, Ворота-1 открыты (сессия С11, 2026-06-06)

> **Статус для следующей сессии (контекст НЕ сохраняется):** Ворота-0 (разведка)
> закрыты. Ворота-1 (развилки) ОТКРЫТЫ — **4 решения ОЖИДАЮТ Антона**, ниже. Код
> по-прежнему НЕ начат. Следующий шаг: собрать решения по (а)–(г) → Ворота-2 (план)
> → Ворота-3 (код) → Ворота-4 (adversarial-ревью суб-агентом). НЕ кодить до «ок».

### Ворота-0 — подтверждено на реальных данных
- **Дерево:** master, чисто; TUI-SAFE не начат (3 целевые функции — голые имена,
  ни одного size/enrich-хелпера).
- **Baseline зелёные под oksh И bash:** selftest 85/85 · velo-install-test 146/146 ·
  site-validate 110/110 · demo screenshot-parity byte-identical (`PARITY_OK`).
- **Verify-first (живой 7.9 bsd.rd, `vm/*.log`):**
  - SIZE+DUID — **HIGH, подтверждено read-only**. Plain `disklabel sd2`
    (`vm/etap4-l3-harvest.log:119-148`) печатает `duid:`, `bytes/sector: 512`,
    `total sectors: 33552847` + полную таблицу. GiB-арифметика сошлась (16.0/447.1/
    931.5G; реальные 33552847с → 15.998 ≈ 16.0G).
  - TYPE/transport — **MIXED, как заявлено**. `sd0 at scsibus2 …: <VirtIO, Block
    Device, >` (rev пуст), `sd0: 20480MB, 512 bytes/sector, 41943040 sectors`,
    `root on rd0a` в каждом логе, `removable` есть и у `cd0`.
  - MOUNT — **HIGH**. `/dev/sd0a (…​a) on /mnt type ffs` → anchor `^/dev/sd0[a-p] `
    в `velo_disk_busy` совпадает. Цель монтируется в `/mnt` ТОЛЬКО после auto-layout
    → на пикере смонтирован лишь rd0; mount-busy install-media на пикере НЕ ловит
    (как и предупреждала спека).

### ⚠️ Два честных GAP-а (нет в захватах — все ВМ на VirtIO)
1. **`wd*` нигде нет** → грамматика dmesg для wd и type-хинт НЕ проверены на реале.
   SIZE/DUID для wd должны работать (disklabel единообразен), type-хинт — нет.
2. **`umass`/USB нет** → реальная install-флешка пойдёт через umass, в захватах её
   нет → USB-transport-хинт и «removable у флешки» НЕ валидированы.

   Оба GAP-а бьют **только по type/transport-ХИНТУ** и по (рекомендованной к
   отклонению) transport-эвристике install-media — НЕ по SIZE/DUID/сигнатуре.
   DoD live-VM smoke всё равно на VirtIO. Валидацию wd/USB на железе — в будущее.

### 🔧 Коррекция спеки (важно для развилки «г»)
Спека выше предлагает ловить install-media по фразе `Available sdN partitions are:
a i`. ПРОВЕРЕНО: эта фраза в захватах исходит из контекста `disklabel -E`
(интерактив), а на кандидатах мы обязаны быть **read-only**. Надёжная сигнатура —
**из самих строк таблицы read-only `disklabel sdN`**: у velo79.img ровно два
раздела, `a: …4.2BSD` + **`i: 960 … MSDOS`** (offset 64); `i:=960-секторный MSDOS`
— КОНСТАНТА во всех сборках (`vm/etap4-l3-install.log:241-242`, `etap5-console.log:
241-242`). Детектить по **строкам таблицы (MSDOS ~960с)**, НЕ по фразе «Available…».
Это войдёт в план Ворот-2.

### Ворота-1 — 4 развилки ОЖИДАЮТ решения Антона (рекомендации мои)
- **(а) Форма строки пикера.** `tui_menu` берёт пункты как отдельные argv-слова, а
  `_wiz_disk` сейчас отдаёт `$_wd_items` без кавычек → многословный лейбл разорвётся.
  **РЕКОМ.: плотный лейбл в tui_menu** — колонки через `_pad`, подача через
  `IFS=$VELO_NL` (лейблы без \n → каждый = один argv), датум — параллельный список
  голых имён по `VELO_MENU_INDEX` (НЕ `idx_from_list` по лейблу). Альт.: кастомный
  многострочный пикер — дублирует arrow/ESC/redraw, риск parity/тестам.
- **(б) Строгость fail-safe.** **РЕКОМ.: раздельно по уверенности** — HIGH
  (mounted/current-root, авторитетно через mount) → невыбираемо, но видно `[MOUNTED]`
  (НЕ auto-hide); эвристический install-media → выбираемо + warning, НИКОГДА не
  hard-refuse. Согласовано с уже существующим hard-refuse в `velo_execute`
  (`velo-install:876`). Альт.: всё pickable + extra-danger confirm.
- **(в) Единица размера.** **РЕКОМ.: честный GiB с пометкой** (`447.1G`, как нативно
  disklabel/df; столбец помечен GiB; совпадёт с установленной системой). Альт.:
  вендорские GB (`480G`, bytes/10⁹; ближе к наклейке, но расходится с системой).
- **(г) Агрессивность метки install-media.** **РЕКОМ.: только сигнатура disklabel**
  (`i:=MSDOS ~960с` из read-only — верифицирована, transport-agnostic; без
  smallest/removable — не валидированы на USB, дают cry-wolf-метки на target).
  Диск всегда остаётся pickable. Альт.: сигнатура + smallest/removable.

### Зацепки (подтверждены чтением кода, С11)
`velo_list_disks` (`velo-install:111`, инъекция `VELO_FAKE_DISKS`) ·
`velo_disk_busy` (`:815`) · `velo_detect_bootmode` (`:252`, читает
`/var/run/dmesg.boot`) · MAKEDEV-паттерн уже в `velo_run_crypto` (`:832`,`:860`) ·
точки внедрения: `_wiz_disk` (`:530`), `_wiz_summary` (`:730`),
`velo_confirm_destructive` (`:777`). Тест-инъекции: `VELO_FAKE_DISKS` есть; под
fake-disk-inventory ПОНАДОБИТСЯ новая инъекция фейковых `disklabel`/`dmesg`/`mount`
(её спроектировать в Ворота-2 — сейчас перехвата этих команд нет).
Команды baseline: `{/usr/sbin/ksh|bash} src/velo-install selftest` ·
`… tests/velo-install-test.ksh` · `… tests/site-validate.ksh` ·
`bash↔/usr/sbin/ksh demo/tui-demo.ksh screenshot`.
