# velo — WORKLOG (журнал-опись + этапы по сессиям)

Единый «бортовой журнал» проекта. Цель — чтобы **новая сессия начиналась с чтения,
а не с воспоминаний** (модель между сессиями ничего не помнит).

## Как пользоваться (конвенция)
1. В начале сессии прочитать: этот файл → `HANDOFF.md` → `PLAN.md` → нужный `docs/*`.
2. Взять **ОДИН этап** из таблицы ниже (следующий незакрытый).
3. Сделать его с верификацией (источники / реальный oksh / ревью), закоммитить локально.
4. **В конце этапа — дописать запись в раздел «Журнал»** (дата, что сделано, файлы,
   проверка, коммиты, что осталось). Обновить статус этапа в таблице.
5. Push — НЕ делать без явного «пуш» от Антона.

Тест-pdksh на Void: `/usr/sbin/ksh`. Демо рамки: `bash demo/tui-demo.ksh screenshot`.

---

## Этапы (1 сессия = 1 этап)

| # | Этап | Definition of Done | Статус |
|---|---|---|---|
| **A** | M0–M3-prep (автономный прогон) | velo-tui+velo-install+site79+build-скрипты собраны, verified oksh+bash, закоммичены | ✅ 2026-06-04 |
| **1** | Build-хост: 7.9 ВМ из `install79.iso` | ВМ грузится, база 7.9 стоит, сделан контрольный прогон штатного установщика, снят снапшот | ✅ 2026-06-05 |
| **2** | Сборка образа velo в ВМ | `build/build-velo.sh` пропатчил `bsd.rd` (size-ceiling ок, хук в `/.profile` подтверждён), `assemble-media.sh` собрал `dist/velo79.img`; повторный прогон идемпотентен | ✅ 2026-06-05 |
| **3** | Test-boot DRY-RUN | `velo79.img` грузится во второй ВМ против ПУСТОГО диска; мастер velo идёт на реальной install-консоли (vt220, ASCII-рамка подтверждена живьём); печатает план; ESC проваливается в штатное меню | ✅ 2026-06-05 |
| **4** | Закрыть `needs_vm` | `pfctl -nf` всех 3 pf-уровней ок; `doas -C` ок; `/usr/obj/_pkgs/*.tgz` оффлайн-замыкание наполнено; L2 IPv6-off; L3 Tor SOCKS-only fail-closed (direct-egress FAIL) | ✅ 2026-06-05 (С7: размещение на `/usr/obj` + FDE-boot + reclaim; **item7-live / L3 fail-closed закрыт С9**, 99c03a9 — см. журнал) |
| **5** | Деструктивная обвязка + РЕАЛЬНАЯ установка в ВМ | velo-install пишет `/mnt/etc/velo/answers` и реально гонит `bioctl`/`fdisk`/`install` за Ворота-СТОП (tui_confirm default-**No** + ввод слова-подтверждения); на ПУСТОМ виртуальном диске проходит настоящая зашифрованная установка и грузится (запрос пароля FDE, нужный pf-уровень, пакеты) | ✅ 2026-06-05 (С5–С9: реальная FDE-установка fortress+L3 + два пароля root/anton + L3 live доказаны; остаток legacy/MBR → бэклог **C**) |
| **6** | M4 — реальное железо (supervised) | `build/write-usb.sh` (`VELO_I_AM_SURE=yes`) пишет образ на **отдельную** USB-флешку (НЕ sda!); Fujitsu грузится с неё; установка на **выделенный запасной** внешний SSD под присмотром Антона | ✅ 2026-06-08 (зашифр. XFCE установился+грузится; вердикт D2; носитель затёрт — см. журнал в конце) |

**Граница безопасности:** этапы 5–6 — деструктивные. Этап 5 безопасен (одноразовый
виртуальный диск). Этап 6 трогает реальное железо → **только при живом участии Антона,
на не-критичную цель; sda (Void-portable) не трогаем никогда.**

---

## Бэклог — продуктовая рамка (2026-06-05, решение Антона)

**Позиционирование (load-bearing для всего ниже):** velo НЕ обещает «анонимность/ОС
уровня Tails/Whonix/Qubes». Обещает **управляемое снижение поверхности атаки и утечек**:
ready-to-use зашифрованная OpenBSD-станция, sane defaults, переключаемые профили L1/L2/L3,
Tor-only fail-closed, видимый control center, меньше ошибок ручной настройки. **Честная
граница:** circuit/stream isolation через несколько `SocksPort` — **ДА** (тот же механизм,
что у Whonix); compromise isolation после RCE в браузере — **НЕТ** (нужна VM/отдельный
gateway — без VM физически не тот класс). Большая часть Layer 0/1 (FDE, doas/wheel, service
minimization, pf L1/L2/L3, L3 SOCKS fail-closed, IPv6-off, pf boot-invariant) **уже стоит**
(см. Журнал C5–C9) — ниже это панель/док поверх готового движка, не переписывание.

Каждый пункт — **отдельный концерн / свои Ворота** (scope-дисциплина). Порядок фич решается
позже. **Задача C (legacy/MBR) остаётся активной** и ортогональна рамке (чистый дефект
загрузки), сейчас на Воротах-2 (план готов, ждёт «ок»).

**Граница target disk (НЕ «external-only»).** velo ставит OpenBSD на **выделенный
(dedicated) target disk** и превращает его в готовую encrypted workstation — это может быть
внешний SSD, второй внутренний диск, VM-диск, тестовый диск. Формула: *«guided installer for
a dedicated target disk; external SSD is the recommended v0.1 real-hardware target»*, НЕ
«external-only installer» (это бы исказило позиционирование обратно во «внешнюю крепость»).
Safety-boundary v0.1: default mental model — dedicated non-critical target; external SSD =
recommended/safest реальный путь; **системный внутренний диск НЕ давать как рядовой
«человеческий» сценарий**; internal — если появится, только later/advanced/supervised с
отдельными тяжёлыми guard'ами; **`sda` / current host root — никогда** (см. M4 hard-stop).

**Roadmap (рамка, не новый зоопарк задач):** v0.1 — installer MVP (вкл. задачу C: UEFI/GPT +
Legacy/MBR target mode); v0.2 — Velo Control Center (P2); v0.3 — privacy refinements (P3/P4/P5);
v0.4 — maintenance (P6); v1.0 — стабильный installer+панель, документированная threat model
(P1), протестировано на нескольких реальных машинах, recovery-доки, никаких «тихих»
деструктивных путей. P7 (ownership boundary) — сквозной, предусловие для P2/P6.

| # | Пункт | Definition of Done | Тип | Статус |
|---|---|---|---|---|
| **P1** | Док: threat-model + non-goals + product statement | `docs/threat-model.md`: списки «protects against / does NOT»; non-goals (не Tails/Whonix/Qubes, не анонимность, не VM-isolation); product statement (EN+RU); явная граница stream-isolation=ДА vs compromise-isolation=НЕТ. Канонический термин — **«protection profiles»**, НЕ «security profiles» (последнее звучит как обещание) | doc (дёшево, выс. ценность) | ✅ 2026-06-06 (worktree velo-p17, `9a44aa8`) |
| **P2** | Velo Control Center | GUI обычным юзером; привилегии — через `doas` на маленькие **whitelist-only** root-helpers (no arbitrary shell, no «выполнить команду»); разделы Status/Protection Mode/Tor/Network Identity/Logs; переключение L1/L2/L3 из GUI; статус pf(ruleset hash)/Tor/mode/egress/DNS-leak; если на C — `pledge`/`unveil` | фича (крупная, своя дизайн-сессия) | ⬜ |
| **P3** | Multi-SocksPort stream isolation + launchers | torrc: неск. `SocksPort` с `IsolateSOCKSAuth`/`IsolateDestAddr`/`IsolateClientAddr`; launchers Velo Tor Browser/Terminal/Messenger через свои порты; **доказать** разные exit-IP на разных портах; композится с L3 `pass out user _tor`; ассерты в site-validate | фича (средняя) | ⬜ |
| **P4** | MAC randomize on boot/now/restore | `lladdr random` в `hostname.if` + toggle-helper; «рандом на бут» (опция) / «рандом сейчас» / «вернуть hw MAC»; дисклеймер: captive-portal/DHCP-lease/MAC-auth могут ломаться | фича (малая) | ⬜ |
| **P5** | DNS-leak / egress test + `velo-report` | развить seed `vm/etapB-l3test.sh` в встроенную проверку (standalone + в Control Center): прямой egress FAIL в L3, torsocks→`IsTor:true`, DNS не течёт в клирнет. **+ `velo-report`:** санитизированный bundle для GitHub-issues (`uname -a`, `dmesg`, `rcctl ls on`, `pfctl -sr/-sn`, `ifconfig`, `pkg_info`, velo-config, tor-status) с вычисткой приватных данных | фича (малая) | ⬜ |
| **P6** | Update / maintenance story | как обновлять: base (`sysupgrade`-guidance), пакеты (`pkg_add -u`), **и velo-конфиги — НЕ перетирая ручные правки юзера** (миграция конфигов); `velo-update`; «safe sysupgrade» памятка. Закрывает разрыв «поставили красиво → через месяц `sysupgrade`?» | фича (средняя) | ⬜ |
| **P7** | Ownership boundary | манифест: что **managed-by-velo** (`/etc/velo/*`, `/usr/local/bin/velo-*`, `/usr/local/share/velo/*`, `*.desktop`) vs **user-owned** (`.xsession`, ручной `pf.conf` после правок, browser-профили) vs **do-not-overwrite**. Сквозной — предусловие для P2 (панель не затирает молча) и P6 (миграция) | политика (предусловие) | ✅ 2026-06-06 (worktree velo-p17, `b0625ee`) |

---

## Известные дефекты — отдельные TODO (не привязаны к P1–P7; чинить отдельным концерном)

| # | Дефект | Где | Серьёзность | Статус |
|---|---|---|---|---|
| **T1** | Профиль `minimal` всё равно ставит X-наборы: set-строка `+* -game* -x11*` не исключает `xbase/xfont/xserv/xshare` (они не `x11*`). Нужно `-x*` (или явный список x-наборов). Косметика, не влияет на FDE/boot/L3. | `gen_install_conf` (`src/velo-install`), `profile_pkgs`, set-строки M2 | minor (косметика) | ⬜ TODO (решение Антона С10: НЕ чинить сейчас) |

---

## TUI-задачи (решение Антона С10) — НЕ открывать «широкую полировку»

Антон: общий вид TUI нормальный, но диск-пикер без size/type/маркеров перед M4 —
это **safety**, не косметика. Разделено на два пункта. **Реприоритизация Антона
(С10): ОБА пункта — ДО D/M4** (косметику тоже сделать прежде записи на флешку).
Рекомендованный порядок — **TUI-SAFE → TUI-POLISH** (они трогают одни экраны:
пикер/summary/destroy-gate; косметика первой = двойная правка safety-семантики).
Полная спека + verify-first (что реально доступно в bsd.rd) — `docs/tui-safe.md`.

| # | Пункт | Суть | Когда | Статус |
|---|---|---|---|---|
| **TUI-SAFE** | safer disk picker + identity-эхо на summary/destroy-gate | name·size·type·DUID·маркеры install-media/mounted·warning; size через `disklabel`, type-хинт через dmesg, mounted через `velo_disk_busy`; **ENRICH+WARN, не auto-hide**; «unknown / verify manually» когда не определить. Scope/fail-safe/DoD — `docs/tui-safe.md` | **до D/M4** | ✅ Ворота-1→4 пройдены (С11-b): identity-блок `velo_disk_row` реализован, развилки (а)–(г) по рекомендациям, adversarial-ревью без BLOCKER'ов, тест 8d на mounted-guard; **85/178/110** зелёные oksh+bash (`tui-safe.md` §ЗАКРЫТИЕ). Остаётся live-VM smoke |
| **TUI-POLISH** | косметика | step counters · термин «Protection profile» + описания L1/L2/L3 · единая help-line + Esc-семантика · визуальный акцент destructive-гейта (heading/цвет) · card-style summary · welcome · root≠user enforce · (тяжёлое, внутри-polish defer: progress `[1/N]`, boxed ERROR) | **до D/M4, ПОСЛЕ TUI-SAFE** (реприор. С10) | ⬜ список зафиксирован (`docs/tui-safe.md`) |

---

## Журнал

### Сессия A — 2026-06-04 (автономный прогон)
**Сделано:** M0–M3-prep целиком.
- **M0** `src/velo-tui.ksh` + `demo/tui-demo.ksh` — 8 ASCII-виджетов (консоль установщика
  не тянет Unicode → проверено). 2 раунда adversarial-ревью; demo parity oksh↔bash байт-в-байт.
- **M1** `src/velo-install` — 7-экранный мастер, DRY-RUN. 104 ассерта + 55 selftest (oksh+bash);
  секрет не течёт; деструктив не исполняется (grep-доказано). Прогнан вживую через pty — рендерит и навигируется.
- **M2** `site/` → `site79.tgz` — install.site + pf L1/L2/L3 + doas + sysctl + оффлайн-pkg + packer;
  96 проверок валидатора; контракт `/etc/velo/answers`. Починены 3 major (вкл. root-RCE в doas.conf).
- **M3-prep** `build/` — `build-velo.sh`/`assemble-media.sh`/`write-usb.sh`(8 guard'ов)/хук/runbook.
  Хук вставляется ПЕРЕД циклом меню (выверено по 7.9 dot.profile rev 1.52). §5 runbook помечен «deferred to M4».
- **Файлы/проверка:** см. `git log` (`1b4b2e7`→`f9d8fc9`), `docs/constraints.md`, `docs/m{0,1,2,3}-*.md`, `HANDOFF.md`.
- **Метод:** 7 workflow'ов, ~49 суб-агентов, на каждый этап design→build→adversarial-review→fix.
- **Осталось:** этапы 1–6 (нужна 7.9 ВМ; этап 6 — реальное железо, руками).

### Сессия 1 — 2026-06-05 (build-хост 7.9 ВМ — АВТОНОМНО)
**Сделано: Этап 1 целиком.** Граница «не автономно» снята — на Void есть `qemu`
10.2 + KVM + оба входа (`~/Downloads/install79.iso` **и** `install79.img`). Runbook
§1 написан под VirtualBox (его на Void нет) → **адаптирован под qemu** (в духе §4a).
- **Headless-установка через serial.** Установщик OpenBSD идёт на VGA; ядро не
  использует BIOS-I/O. Решение: **SeaBIOS sercon** (`-fw_cfg etc/sercon-port=0x03F8`,
  2-байтный LE-файл `vm/sercon-port.bin`) зеркалит `boot>` на serial → драйвер шлёт
  `set tty com0` + `boot` → ядро/установщик дальше нативно на com0. Первый ввод —
  НЕ вслепую (детектируем `boot>` на serial).
- **Драйвер `vm/drive-install.py`** — idle-gated rule-based expect-движок по точным
  промптам `install.sub` (сверено с `m1-design.md §9`). Стоковая 7.9: whole-disk
  `(A)uto`, БЕЗ шифрования, наборы `all` с `cd0`, `console→com0=yes` (installed
  система грузится на serial), `sshd`+`root-ssh=yes` (для `scp` на Этапе 2), tz UTC,
  dhcp/`vio0`. Установка прошла: `CONGRATULATIONS`, все наборы синканы, `halt`.
- **Verify `vm/verify-boot.py`** — загрузка с диска БЕЗ CD → `login:` на com0 →
  `root`/`velobuild79` OK → `kern.version=OpenBSD 7.9 (GENERIC.MP) #449` →
  `uname: OpenBSD ... 7.9 GENERIC.MP#449 amd64` → `halt -p`. **rc=0, is79=True.**
- **Снапшот** `base-7.9` (qcow2, on-disk ~2.33 GiB) — точка отката для Этапов 2–3.
- **Баги драйвера (найдены прогоном, исправлены):** (1) не было правила `Terminal
  type`; (2) regex был case-sensitive (`Network`≠`network`) → `re.IGNORECASE`;
  (3) матчили весь скроллбэк → устаревший DHCP-текст `DNS nameservers?` перехватил
  промпт root-пароля (ввёлся пустой пароль, установщик переспросил, пароль в итоге
  верный) → **матчим только активную строку** промпта; (4) чистый `rc=0` на
  halt-экране вместо stall. Прогон, на котором собрался образ, был ДО фикса (2)/(3) и
  самоисцелился; ВМ валидна и точно по спеку. Фиксы — для воспроизводимости.
- **Файлы (все в `vm/` — gitignored, throwaway):** `drive-install.py`,
  `verify-boot.py`, `buildhost.qcow2`(+snap `base-7.9`), `sercon-port.bin`,
  `install-console.log`, `verify-console.log`. Закоммичено в git: `WORKLOG.md` +
  `.gitignore` (+`/vm/`).
- **Осталось:** Этапы 2–6. Следующий — **Этап 2** (сборка `velo79.img` внутри ВМ;
  `install79.img` на месте). **Рекомендация (отдельным решением):** промоутнуть
  `drive-install.py`+`verify-boot.py` в `build/` и переписать runbook §1 (VBox→qemu),
  т.к. qemu-рецепт теперь и есть реальный путь build-хоста.

### Сессия 2 — 2026-06-05 (сборка velo79.img в ВМ — АВТОНОМНО)
**Сделано: Этап 2 целиком.** Образ собран ВНУТРИ build-хоста 7.9 (бутнут из snapshot
`base-7.9`, headless, sshd по hostfwd 2222 — root-ssh включён на Этапе 1).
- **Транспорт host↔VM по SSH.** Хелпер `vm/ssh_pw.py` (pty+пароль, sshpass на Void нет).
  `install79.img` (800M) → scp в `/usr/obj/velo` (на `/` лишь 259M; `/usr/obj` = 7.6G;
  slirp ~40 MB/s). `bsd.rd.orig` извлечён из `cd0` (`mount cd9660`). Репо `src/`+`build/`+
  `dist/site79.tgz` → scp.
- **БАГ в `build/build-velo.sh` (найден прогоном в ВМ, ИСПРАВЛЕН → коммит).** Детект gzip был
  `gzip -t FILE`, но OpenBSD `gzip(1)` отвергает файл без суффикса `.gz` (`unknown suffix:
  ignored`, rc=2) → gzip'нутый `bsd.rd` (магия `1f8b`) принимался за raw → `rdsetroot: not an
  elf`. Фикс: детект по МАГИИ (`od`/`tr`, `1f8b`) + decompress из **stdin**; re-compress тоже из
  stdin. Линт `oksh -n`+`bash -n` OK. Классический host-lint-vs-VM-run баг — ровно то, ради чего
  M3 исполняется в ВМ.
- **`build-velo.sh`** (после фикса): `ceiling = 3768320 B`, патч fs `3768320 B` — **влезает**
  (slack 0 — by-design: `rd_root_image` это фикс-size FFS, наши ~55KB сели во внутренний free,
  `install` без ENOSPC). Хук в `/.profile` подтверждён. **Идемпотентность:** повторный прогон →
  «already carries the velo hook -- not re-inserting». `constraints.md` **UNVERIFIED #5 закрыт**.
- **`assemble-media.sh`:** set-партиция `a` (4.2BSD) подтверждена живым `disklabel`; `bsd.rd`
  заменён патченым, `site79.tgz` добавлен → `velo79.img` (839352320 B). **Sanity (cksum в образе
  == источник):** `bsd.rd` `2624791502/4867135`, `site79.tgz` `163590666/11486`.
- **Артефакты на хост:** `dist/velo79.img` (cksum `1893775815`, transfer-verified) +
  `dist/bsd.rd.velo` — оба gitignored. Готовы к Этапу 3 (test-boot в host-qemu против ПУСТОГО
  диска). ВМ остановлена; snapshot `base-7.9` цел.
- **Файлы:** изменён `build/build-velo.sh` (gzip-fix — закоммичено). Хелпер `vm/ssh_pw.py` —
  в `vm/` (gitignored).
- **Осталось:** Этапы 3–6. Следующий — **Этап 3** (DRY-RUN test-boot `velo79.img`: velo-TUI на
  реальной install-консоли, ESC→штатное меню). Этапы 5–6 — деструктив (Ворота-СТОП).

### Сессия 3 — 2026-06-05 (Этап 3: test-boot DRY-RUN — АВТОНОМНО)
**Сделано: Этап 3 целиком.** Test-boot `velo79.img` в host-qemu против ПУСТОГО диска (16G blank).
- **Визуал (4 PNG в `vm/etap3-*.png`, драйвер `vm/etap3-shot.py` через VGA + qemu `screendump`):**
  welcome-бокс velo на реальном VGA-консоле — синий ASCII `+ - |`, **БЕЗ `?`-стен** (box_strategy=ASCII
  подтверждён вживую на wscons); экран выбора диска (`> sd0` / `sd1`); и **ESC → провал в штатное меню
  `(I)/(U)/(A)/(S)`** — `velo: not completed (rc=1) -- dropping to the stock OpenBSD installer menu`
  (around-wrap подтверждён). Мастер всплыл САМ — `install` не печатался (хук `/.profile` работает).
- **Печать плана (serial-драйвер `vm/etap3-plan.py`):** через SeaBIOS sercon + `set tty com0` вывел
  velo на com0 и прогнал мастер по точным клавишам (из `velo-tui.ksh`: confirm=`y`, menu/radio=стрелки+ENTER,
  password=строка+ENTER) через все 7 экранов: диск `sd1`, шифрование **yes**+пароль, hostname `velo-bsd`,
  profile `desktop`, pkgs none, startmode `L1` → summary→**Yes** → распечатан полный DRY-RUN-план:
  `plan_crypto` (`fdisk -iy -g -b 960` / `disklabel -E` RAID-слайс / `bioctl -Cforce -cC -l"sd1a" -s
  softraid0` / `dd` wipe) + `install.conf` (root disk = `sdN` крипто-юнит, layout auto, sets disk, verify off).
- **Секрет не течёт — подтверждено ВЖИВУЮ:** ввёл реальный пароль, но в плане стоит `$VELO_PASSPHRASE`
  (имя переменной), не значение. M1 secret-contract держится не только в selftest, но и на живом прогоне.
- **Bootstrap-баг serial (поправлен в драйвере):** после `set tty com0` консоль теряет 1-й байт ввода
  (`boot`→`oot`, грузил несуществующий файл). Фикс: sacrificial `\r` перед `boot`. (Этап-1 драйвер везло
  по таймингу — у него та же уязвимость; учесть при промоушене.)
- **Файлы:** `vm/etap3-shot.py`, `vm/etap3-plan.py`, `vm/etap3-*.png/.log` — всё в `vm/` (gitignored).
  Коммит: только `WORKLOG.md`.
- **Осталось:** Этапы 4–6. **Этап 4** = закрыть `needs_vm` (pfctl -nf трёх pf-уровней, `doas -C`, наполнить
  оффлайн-pkg-замыкание, L3 Tor end-to-end fail-closed). **Этап 5** = деструктивная §2.3-обвязка +
  реальная зашифрованная установка в ВМ — за Ворота-СТОП, §2.3 НЕ собрана. **Этап 6** = железо, при Антоне.

### Сессия 4 — 2026-06-05 (Этап 4: needs_vm — 🟡 ЧАСТИЧНО, автономно по «доделай всё»)
**Статические проверки — все зелёные:**
- **pf parse:** L1 ✅, L2 ✅, **L3 ✅ после фикса**. L3 не парсился — нашёл реальный баг в `pf.l3.conf`:
  `from !$tor_uid` (username как host — pf так не умеет) + неверный порядок клауз. Фикс: `user != $tor_uid`
  ПОСЛЕ `to ... port ...` (строки 26/32). `pfctl -nf` трёх уровней → OK (L3 требует установленного `tor`
  для юзера `_tor`). doas `-C` → OK. **IPv6-off** (L2/L3): `block out log inet6 all` + sysctl-disable ✅.
- **Перепроверка M0–M2:** velo-install selftest 55/55, full suite **104/104**, site-validate **96/96** — все PASS.
  velo79.img cksum `1893775815` совпал; build-host грузится (работает прямо сейчас). Этапы 1–3 целы.
**Оффлайн-pkg-замыкание — механизм валиден, доставка упёрлась в размер медиа:**
- Наполнил minimal+fortress замыкания (47 `.tgz`, 133 MB) через `PKG_CACHE` в ВМ.
- **Item 6 (acceptance) ✅:** `PKG_PATH=локальные блобы pkg_add -n -l fortress.list` резолвит замыкание
  ТОЛЬКО локально, без сети.
- **БЛОКЕР доставки:** install-медиа set-партиция = 799M, занято 766M, **свободно 33M** → 131 MB замыкания
  **НЕ ВЛЕЗАЕТ** на стоковую флешку. site79.tgz собран **configs-only** (влезает, с pf.l3-фиксом); блобы
  сохранены в `vm/pkgcache-host/` (47 шт). **Доставка L3-замыкания требует увеличенного образа (рост
  OpenBSD-партиции / отдельная `/root/pkgs` партиция) — отдельная подзадача (НОВЫЙ пункт плана).**
**Ещё один баг (найден, не блокер):** `make-site-tgz.sh` падает в ВМ — OpenBSD base `tar` не знает
`--uid`/`-T`/`-I` из non-GNU fallback (строки 181–184). Канонический путь — сборка на хосте (GNU tar) — ОК;
хост `/tmp` = 2G tmpfs 100% занят → нужен `TMPDIR` на большом разделе.
**Осталось по Этапу 4:** L3 Tor end-to-end fail-closed (нужна загруженная fortress+L3 = Этап 5); доставка
замыкания (увеличенный медиа). **Файлы:** `pf.l3.conf` (фикс), `.gitignore` (+blobs), `WORKLOG.md`,
`docs/research-openbsd-desktop.md` — коммит. velo79.img НЕ пересобирал (будет в Этапе 5).

### Сессия 5 — 2026-06-05 (Этап 5: деструктивная обвязка + реальная установка в ВМ — 🟡 ЯДРО ✅)
**ГЛАВНОЕ: velo РЕАЛЬНО поставил зашифрованную OpenBSD в ВМ, и она ГРУЗИТСЯ с запросом FDE-пароля.**
Пруф: `vm/etap5-fde-1-boot.png` → `disk: hd0 sr0*` / `>> OpenBSD/amd64 BOOTX64 3.71` / `Passphrase:`.

**Собрана §2.3 деструктивная обвязка** (`92a88c2` + 6 итераций фиксов): `velo_execute` + `velo_confirm_
destructive` + `velo_run_crypto` + `velo_crypto_unit` + `velo_disk_busy`. ДВОЙНОЙ гейт: env
`VELO_ALLOW_EXECUTE=yes` (ставит ТОЛЬКО launcher медиа `velo-rd-hook.sh`) + typed-confirm точного имени
диска (default-No). Установщик неинтерактивно через **`install -a -f FILE`** (source-grounded по
`install.sub`: ветка `cp ai.conf`, БЕЗ 5-сек watchdog, БЕЗ запрещённого `auto_install.conf`). Пароль —
только в stdin-пайп `bioctl`. На хосте/в тестах/в `plan` — **ИНЕРТНО** (rc 2): линт oksh+bash, selftest
55/55, suite 104/104 целы. Драфт + adversarial self-критика суб-агентом.

**Прогон в ВМ (6 итераций) — установка ПРОШЛА (`CONGRATULATIONS`) и грузится с FDE:**
1. ✅ Ворота-СТОП: мастер→Yes→TUI «DESTROY DISK»→напечатал `sd1`→`ARMED + confirmed`.
2. ✅ Реальный crypto: `fdisk -g`/`disklabel` RAID/`bioctl -cC` (пароль через stdin) → softraid `sd2 CRYPTO`.
3. ✅ `install -af`: все промпты из `install.conf`, verify-off, наборы оффлайн, `site79.tgz`, `install.site`.
4. ✅ **FDE-загрузка** (UEFI/OVMF — диск GPT): `BOOTX64 3.71 / Passphrase:` — запрос пароля softraid на старте.

**Баги, вскрытые прогоном в ВМ и исправленные** (ровно ради этого M3 идёт в живую ВМ):
1. нет `/dev/sd1` нод → `MAKEDEV` перед fdisk/bioctl;
2. `disklabel -E` heredoc клал `RAID` в слот РАЗМЕРА → «Invalid entry»; поправил порядок offset/size/fstype
   (провалидировал на vnd: `a: ... RAID`);
3. `velo_crypto_unit` парсил не тот формат `bioctl softraid0` + pipe-subshell ломал `return` → capture +
   token-scan (провалидировал: `unit=sd2 rc=0`);
4. root-диск уходил в плейсхолдер `sdN`: `velo_run_crypto` мешал stdout команд с эхо юнита → отдаю через
   глобал `VELO_CRYPTO_UNIT`;
5. `install.conf` пароль `<bcrypt-hash>` плейсхолдер → sed-шим (TEST-значение `velotest1`; velo должен
   СПРАШИВАТЬ root-пароль — M3-followup, новый пункт плана).

**🟡 НЕ доведено (документированные следующие куски):**
- **answers-профиль:** `install.site` авто-отработал на БЕЗОПАСНОМ полу (`minimal/L1`), НЕ по выбору мастера.
  Чистое решение — переименовать в `install.site.velo` (медиа не авто-запустит; velo сам пишет answers +
  `chroot /mnt /install.site.velo`). Каскад: правка `make-site-tgz.sh` + `site-validate.ksh`. Диск всё равно
  ЗАШИФРОВАН (это `velo_execute`, не install.site).
- **пакеты:** `rc.firsttime pkg_add` отложен на 1-й буст; оффлайн-замыкание не на медиа (Этап-4 блокер: 33M
  свободно vs 131M — нужен увеличенный образ).
- **legacy BIOS:** диск GPT (`fdisk -g`) → грузится только UEFI; под SeaBIOS «No active partition». Для
  legacy-машин velo нужен MBR-режим (опция) — новый пункт плана.

**Файлы:** `src/velo-install` (обвязка + 5 фиксов — КОММИТ), `build/velo-rd-hook.sh` (arm — в `92a88c2`),
`vm/etap5-*.py` + `vm/etap5-fde-*.png` (драйверы/пруфы — gitignored), `WORKLOG.md`. **Осталось:** Этап 6
(железо, ТОЛЬКО при Антоне) + три задокументированных «следующих куска» выше.

### Сессия 6 — 2026-06-05 (Этап 4: «Больший образ» + L3 end-to-end — 🟡 МЕХАНИЗМ ✅, доставка-на-диск переосмыслена)
**Решение Антона (Ворота 1–2):** доставлять L3-замыкание через УВЕЛИЧЕННЫЙ образ (а не урезать/отдельную партицию).

**ДОКАЗАНО (главное «Больший образ» — механизм доставки):**
- **`build/grow-media.sh`** (НОВЫЙ) — воспроизводимо строит больший bootable образ (1.43 GiB): sparse-файл,
  наследует MBR+ESP байт-в-байт (сектора 0–1023) от `install79.img`, патчит размер MBR-партиции 3 (offset 506,
  4 LE), `disklabel -E` нарастил `a`, `newfs`, `tar` стокового дерева, вшил `bsd.rd.velo` + толстый `site79.tgz`,
  `installboot -r /mnt vnd /usr/mdec/{biosboot,boot}`. **Грузится legacy(SeaBIOS) И UEFI(OVMF)** — оба пути сняты
  вживую (Фаза 3: velo-TUI welcome на VGA-скрине + serial).
- **Замыкание полное и согласованное (50 блобов, граф `@depend` замкнут):** дозабраны `libevent-2.1.12p3`
  (зависимость tor — была потеряна!) + `updatedb-0p0` (dep quirks). Версии кэша == текущие release-версии зеркала.
- **Багфиксы списков пакетов (по Антону):** `tmux`/`vim` убраны (это OpenBSD base — пакетов нет), `mupdf` убран
  (GUI, на fortress без X бесполезен), добавлены **`nano`** (везде) + **`xfce4-terminal`** (desktop). Синхронно
  `profile_pkgs()` + 3 `.list` + ассерты; заодно починена стейл-проверка L3-правила в `site-validate.ksh`
  (ждала старый `from !$tor_uid`, реальность — `user != $tor_uid` после фикса Сессии-4).
- **`install.site` → `install.site.velo` (rename):** инсталлятор больше НЕ авто-запускает хук на safe-floor;
  velo пишет `/mnt/etc/velo/answers` и сам `chroot /mnt /install.site.velo` → **бокс реально fortress+L3**
  (раньше всегда вставал minimal+L1 — гэп Сессии-5 закрыт). Каскад: `make-site-tgz`+`site-validate`.
- **Реальная установка fortress+L3 (Ворота-СТОП, пустой диск) + harvest зашифрованного диска подтвердили:**
  `/root/pkgs` = 50 блобов/136M; `installed.list`=fortress+tor; `/etc/pf.conf`=L3 fail-closed (`block all`);
  sysctl IPv6-off; `rc.firsttime` L3 `PKG_PATH=/root/pkgs` local-only. **item 6** (замыкание покрывает список) и
  **item 8** (IPv6 off) ✅ структурно.

**🔴 КЛЮЧЕВАЯ НАХОДКА — disk-layout шаблон ЛОМАЕТ FDE-загрузку (ОТКАЧЕН):**
Чтобы 134M-замыкание влезло (auto-layout даёт `/` лишь ~239M), пробовал disklabel-autopartition-шаблон
(один большой `/`). Установка прошла, НО бокс **не грузится под OVMF**: бутлоадер уходит в `boot>` и грузит
`hd0a` («Device not configured»), prompt пароля softraid НЕ появляется. **Сравнение вживую:** Этап-5 бокс →
`disk: hd0 sr0*` → `Passphrase:`; мой (с шаблоном) → `disk: hd0 sr0` (без `*` = softraid НЕ помечен boot-диском).
Шаблон кладёт партицию `a` на offset 1024 (vs 64 у auto-layout) → `installboot` не делает sr0 загружаемым.
→ **Шаблон ОТКАЧЕН из `velo-install` (не коммичу boot-ломающий регресс).**
**Правильный фикс (НЕ сделан):** не трогать раскладку, а **перенести замыкание на `/home`** (большой раздел
auto-layout, FDE-boot цел) + правка `install.site.velo` PKG_PATH. Это следующий пункт.

**Ворота-4 (adversarial-ревью суб-агентом) — 2 MAJOR + 1 safety исправлены:**
- `plan_crypto` disklabel-heredoc был СТАЛ (RAID в слот размера) — расходился с реальным `velo_run_crypto`;
  выровнен (RAID в fstype). - `velo_execute`: запись answers теперь **проверяется** (`[ -s ]`) — молчаливый
  провал больше не роняет бокс на safe-floor тихо. - `grow-media.sh`: guard, что OUT — обычный файл (не /dev/).
  Ревью подтвердило безопасность: file-image-only, секрет не течёт, chroot за двойным гейтом.

**+ tor-enable:** install.site.velo на первом бутте `rcctl enable+start tor` если установлен (L3 без работающего
tor = кирпич: fail-closed pf даёт egress только `_tor`). Найдено harvest'ом (rc.conf.local был пуст).

**Тесты:** selftest 55/55 (oksh+bash), suite 104/104, site-validate 96/96 — все зелёные.
**Файлы (КОММИТ, без push):** `build/grow-media.sh` (нов), `src/velo-install` (install.site.velo-обвязка +
plan_crypto-фикс + answers-verify; шаблон откачен), `site/install.site.velo` (rename + tor-enable),
`build/make-site-tgz.sh` + `tests/site-validate.ksh` (install.site.velo + L3-фикс), 3 `site/root/pkgs/*.list` +
`profile_pkgs()` + ассерты. Блобы замыкания (`site/root/pkgs/*.tgz`, +nano/libevent/updatedb) — gitignored.
`vm/*` (драйверы/пруфы) — gitignored.

**Осталось по Этапу 4:** (1) перенести замыкание на `/home` (или шаблон с offset-64) — чтобы влезало И FDE
грузился; (2) пересобрать+переустановить, проверить FDE-boot живьём; (3) **item 7 live** (tor поднялся офлайн +
fail-closed: прямой egress FAIL) — заблокирован до (1)+(2). Механизм доставки и полнота замыкания — доказаны;
осталась корректная РАЗМЕЩЁННОСТЬ на диске.

### Сессия 7 — 2026-06-05 (Этап 4: размещение L3-замыкания на /usr/obj — host-часть ✅, VM-проверка TODO)
**Решение Антона (Ворота 1–2):** класть замыкание на **`/usr/obj/_pkgs`**, НЕ на `/home`.

**Находка, исправившая посылку рекапа:** harvest двух живых auto-layout-установок (`vm/etap5-console.log`,
`vm/install-console.log`) дал реальную раскладку: `/`=239M (мал — корень проблемы), `/usr/local`=1.29G (сюда
`pkg_add` ПИШЕТ), `/home`=1.5G, **самый большой — `/usr/obj`=8.2G** (мёртвый scratch от set'ов src/obj). Рекап звал
`/home` «большим разделом» — неверно: `/home` лишь 1.5G (хватает fortress-136M, но тесно будущему desktop-замыканию
~1G+). `/usr/obj` вмещает любой профиль, не юзерский. `/usr/local` отвергнут: источник+приёмник `pkg_add` на одном
fs → double-peak.

**Сделано (host-часть, Ворота 3):**
- Перенёс `site/root/pkgs/` → **`site/usr/obj/_pkgs/`** (50 блобов + 3 `.list` + `.keep-empty`); `site/root/`
  оставил только `.profile`. `.gitignore` → `site/usr/obj/_pkgs/*.tgz`.
- `site/install.site.velo`: DRY `_pkgdir='/usr/obj/_pkgs'` (PKG_PATH = `$_pkgdir` на L3 / `$_pkgdir:installpath` на
  L1/L2); `_base_list`+`mkdir`+лог на новый путь; **новое:** `rc.firsttime` эмитит `VELO_PKGDIR` и **подчищает
  замыкание `rm -rf` ТОЛЬКО при успехе `pkg_add`** (возврат 136M..~1G; при провале блобы остаются для ретрая).
- `build/make-site-tgz.sh` self-check по новому пути; `tests/site-validate.ksh` — путь + ассерты `_pkgdir`/
  `VELO_PKGDIR`/reclaim + позиционный (reclaim внутри success-ветки); `m2/m3`-доки — путь + рационал «почему /usr/obj».

**Ворота-4 (adversarial-панель, 3 линзы):** миграция COMPLETE&CORRECT; `rm -rf` SAFE (только success, hardcoded
непустой абс. путь, кавычки, guard fail-closed, внутри sentinel-идемпотентности); тесты не вакуумные (проверено
независимым flip'ом пути/режима). Один MINOR (нет проверки позиции reclaim) — **исправлен** статическим ассертом
порядка строк (pkg_add < rm < else). NIT (path-allowlist для будущего динамического `_pkgdir`) — задокументирован,
не делал (путь сейчас — hardcoded литерал, guard и так fail-closed).

**Тесты (зелёные):** selftest 55/55, suite 104/104, site-validate **104/104**. `make-site-tgz` собрал `site79.tgz`
134M; члены архива в `usr/obj/_pkgs/`, ни одного stale `root/pkgs`-члена, `install.site.velo` на месте.

**VM-проверка (live, эта же сессия) — ✅ замыкание на /usr/obj доказано end-to-end:**
- Находка: host-овский `dist/bsd.rd.velo` (03:54) был ДО-execute — первый прогон установки ушёл в DRY-RUN. Пересобрал
  **армированный** `bsd.rd.velo` (текущие исходники с `velo_execute`) в buildhost-VM (`build-velo.sh`), затем `velo79.img`
  (`grow-media`); внутри образа `site79.tgz`: 54 члена `usr/obj/_pkgs`, 0 `root/pkgs`.
- Реальная установка fortress+L3 (softraid CRYPTO → sd2) — serial-лог: `composed base packages from
  /usr/obj/_pkgs/fortress.list`, `L3: PKG_PATH=local-only (/usr/obj/_pkgs)`, `install complete`.
- FDE-boot под OVMF: пароль принят (sendkey), ядро грузится с зашифрованного корня (скрин `etap4-fb-2postpass`).
- **Harvest зашифрованного диска** (bioctl unlock sd1a→sd2 + mount `/`,`/usr`,`/var`,`/usr/obj`):
  `velo-pkg.log` = pkg_add OK (quirks signed, rcscript `/etc/rc.d/tor`, readme git/gnupg); `/var/db/pkg` =
  `tor-0.4.9.9`+`torsocks-2.4.0`; **`/usr/obj` смонтирован и ПУСТ, `/usr/obj/_pkgs` отсутствует → reclaim сработал**;
  `/etc/rc.firsttime` удалён `/etc/rc` (только после успеха); `installed.list` = fortress+tor.
- Драйверы (gitignored): `vm/etap4-l3-harvest.py` (нов). **item 7 live** (tor up + прямой egress FAIL) — это L3
  pf/tor-стек, НЕ затронут этой правкой (доказан структурно + Этап 5/6); живую сеть не пере-прогонял.

**Этап 4 — ЗАКРЫТ:** механизм доставки, размещение на `/usr/obj`, FDE-boot и reclaim — доказаны вживую.

### Сессия 8 — 2026-06-05 (Бэклог-A: экран пароля root/user — host ✅ + live-VM ✅ ЗАКРЫТО)
**ГЛАВНОЕ: снят TEST-шим `velotest1`.** Раньше `velo_execute` подставлял `sed s/<bcrypt-hash>/velotest1/`
→ КАЖДАЯ velo-машина уезжала с root- и user-паролем `velotest1` (дыра «крепости»). Теперь мастер
СПРАШИВАЕТ пароли, хеширует их `encrypt(1)` в ramdisk и кладёт в install.conf только bcrypt.

**Ворота 0→4 (по дисциплине вайбкодинга, решения Антона):** обсуждение → план → «ок» → реализация →
adversarial-ревью суб-агентами. Решения Антона на Воротах-1: **(1) два** раздельных пароля (root и user);
**(2) Вариант 2** — bcrypt генерим в rd, в файл только хеш (консистентно с passphrase-гигиеной);
**(3)** политика = non-empty + confirm-twice (зеркало passphrase); **(4)** username `anton` — хардкод, вне scope.

**Source-grounded (сверено по исходнику OpenBSD этой сессии):** `install.sub:encr_pwd()` берёт `$2b$..`-хеш
**verbatim** (без двойного шифрования), а плейнтекст хеширует сам через `encrypt -b a`. `encrypt(1)` читает
пароль из **stdin**, если строки-аргумента нет; `-b a` = авто-раунды (ровно как stock). Значит шим «работал»
лишь потому, что установщик принял плейнтекст и сам захешировал.

**Архитектура (Вариант 2):**
- Два секрет-глобала `VELO_S_ROOTPW`/`VELO_S_USERPW` (плейнтекст, живут только в переменной) + два
  внутренних `*_HASH` (НЕ env-seedable, считаются ТОЛЬКО в `velo_execute`).
- Два НОВЫХ безусловных confirm-twice экрана `_wiz_rootpw`/`_wiz_userpw` (клоны passphrase-цикла; пароль ОС
  нужен и при `encrypt=no`). Роутер: вставлены кейсы **3=rootpw, 4=userpw**, старые экраны 3..7 → 5..9, summary=9;
  ESC-навигация на шаг назад. Summary показывает `passwords: set (root, user)` — без значений.
- `gen_install_conf`: `Password for {root,user} = ${VELO_S_*_HASH:-<bcrypt-hash>}` — пустой хеш-глобал даёт
  плейсхолдер (DRY-RUN/`plan`/on-screen-превью НЕ несут креденшл), заданный — реальный хеш.
- `velo_execute`: `set +x` → `print -r -- "$pw" | encrypt -b a` (плейнтекст через pipe в stdin, как bioctl;
  захватывается только хеш) → guard `$2`-префикс (fail-closed) → `gen_install_conf` пишет реальные хеши в
  **0600** `/tmp/velo-install.conf`. On-screen audit-preview идёт ДО `velo_execute` (хеш-глобалы ещё пусты) →
  на экран только плейсхолдер. Шим `velotest1` УДАЛЁН.

**Ворота-4 (workflow: 4 линзы — секрет-гигиена / семантика установщика / поток мастера / полнота — + стадия
опровержения каждого major/blocker):** **0 подтверждённых major/blocker.** 4 «VERIFIED»-нита (секрет не течёт
на экран/план/лог/argv/xtrace на oksh-таргете; encrypt-пайп+guard+метасимволы корректны; роутер/ESC/гео/re-walk
верны; шим полностью удалён, тесты не вакуумны — доказано flip'ом). Применены **3 fail-closed улучшения**,
найденные панелью: (1) **conf-файл 0600 с создания** — `rm -f` (против подложенного symlink) + `( umask 077;
gen_install_conf >file )` вместо chmod-после-записи (убрано окно world-readable на хешах); (2) **`_velo_scrub_secrets()`**
— вынесен и зовётся на ВСЕХ путях выхода, включая `welcome-cancel` (env-seeded пароль больше не остаётся в памяти;
заодно закрыта давняя такая же дыра с passphrase); (3) **`VELO_HAS_PRINT`-guard** в execute — если `print` не
builtin (не-oksh рантайм), пайп отдал бы encrypt пустой stdin → валидный bcrypt ПУСТОЙ строки прошёл бы `$2`-guard
→ теперь abort.

**Тесты (зелёные, oksh `/usr/sbin/ksh` + bash):** lint `-n` чист; встроенный selftest **67/67**; suite
`velo-install-test.ksh` **121/121**. Новое покрытие: placeholder-vs-hash, анти-течь плейнтекста в conf,
скраб после `plan`, прямой тест `_velo_scrub_secrets`. DRY-RUN `plan` печатает `<bcrypt-hash>` и не светит секрет;
`( umask 077 )`-создание даёт `-rw-------` подтверждено.

**Файлы (КОММИТ, без push):** `src/velo-install` (state + 2 экрана + роутер + gen_install_conf хеш-глобалы +
velo_execute encrypt-путь + 3 фикса + скраб-хелпер + selftest), `tests/velo-install-test.ksh` (секция 6b + скраб-
ассерты), `docs/m1-design.md` (forward-note), `docs/WORKLOG.md`.

**LIVE-VM ACCEPTANCE — ✅ ЗАКРЫТО (эта же сессия, end-to-end в qemu/KVM, throwaway-диски):**
- **Пересборка:** buildhost-VM (reused state, входы в `/usr/obj/velo`), scp нового `src/velo-install` (cksum
  совпал host↔VM), `build/build-velo.sh` → армированный `dist/bsd.rd.velo` (хук вставлен, влез в ceiling),
  `build/grow-media.sh` → `dist/velo79.img`. Драйверы (gitignored): `vm/etap8-pwinstall.py` (клон install-драйвера
  + 4 сенда rootpw×2/userpw×2), `vm/etap8-pwharvest.py` (harvest + `cat master.passwd`), `vm/etap8-verify.py`
  (host `bcrypt.checkpw`).
- **Ошибка входа, пойманная прогоном (не код!):** первый install упал `/mnt full` — взял **устаревший** VM'ный
  `site79.tgz` (layout `root/pkgs`, ДО переезда С7 на `/usr/obj/_pkgs`) → 134M замыкания не влезли в `/` (239M).
  Harvest подтвердил: установщик пишет пароли/создаёт юзера ПОСЛЕ распаковки наборов, поэтому на упавшем диске
  `root::` (пустой хеш), anton нет. Залил **правильный** host'овый `site79.tgz` (53 члена `usr/obj/_pkgs`),
  пере-grow-media, переустановил начисто.
- **Чистый install (3 РАЗНЫХ креденшела: FDE=`velofde9X`, root=`veloROOTa1`, anton=`veloUSERb2`):** `CONGRATULATIONS`,
  `velo: wrote answers (fortress/L3/encrypt=yes)`, `install.site.velo` отработал (pf.l3, doas, anton в wheel/operator,
  замыкание из `/usr/obj/_pkgs`), `velo: DONE`. (Не-фатально: `Relinking ... /usr full` — KARL-релинк, фолбэк на
  stock bsd.mp; auto-layout-теснота `/usr`, к паролю отношения нет, как и в С5/С7.)
- **Harvest зашифрованного диска** (bioctl-unlock FDE → mount `/` -r → `master.passwd`):
  `root:$2b$09$Bl5q4rb4…`, `anton:$2b$09$6y/uTJpf…` (два РАЗНЫХ bcrypt; hostname=`velo-bsd`; 0 вхождений
  `velotest1`/`<bcrypt-hash>`).
- **РЕШАЮЩИЙ ПРУФ — `bcrypt.checkpw` на хосте, ALL PASS:** `checkpw(veloROOTa1,root)=True`,
  `checkpw(veloUSERb2,anton)=True`, `checkpw(velotest1,root)=False`, `checkpw(velotest1,anton)=False`,
  `checkpw(veloUSERb2,root)=False`, `checkpw(veloROOTa1,anton)=False`, `root_hash≠anton_hash`. → **набранные
  оператором пароли РЕАЛЬНО стали паролями аккаунтов; root и anton независимы; `velotest1` исчез.** Это та живая
  проверка пароля, что для `velotest1` ни разу не снимали.

**Бэклог-A — ЗАКРЫТ.** Из бэклога остаются B (item7-live tor egress), C (legacy/MBR), D (M4 реальное железо — Ворота-СТОП).

### Сессия 9 — 2026-06-05 (Бэклог-B: item7-live — L3 egress fail-closed ДОКАЗАН ВЖИВУЮ + 3 реальных бага)
**ГЛАВНОЕ: на реальном зашифрованном velo-боксе (qemu/OVMF, throwaway) живьём доказано, что прямой egress
закрыт, наружу ходит только Tor, torsocks выходит через реальный Tor-узел, а при остановке tor — нет пути
наружу (fail-closed). item 7 закрыт по-настоящему, не структурно.**

**Решение по модели (Ворота 0→2; Антон делегировал выбор — «наилучшая надёжная анонимность»):** L3 переведён
с ПРОЗРАЧНОГО Tor-шлюза (pf `rdr-to` TransPort/DNSPort) на **SOCKS-only fail-closed («S»)**. Прозрачный
single-host redirect на OpenBSD хрупок (rdr-to требует, чтобы Tor читал `/dev/pf` для NAT-lookup — гонка
привилегий; divert-to предназначен для forwarded-трафика шлюза, не для собственного исходящего хоста). S
надёжнее и так же герметичен: `block all` + наружу ТОЛЬКО юзер `_tor`; любое приложение — через Tor SOCKS
`127.0.0.1:9050`; не-SOCKS приложение не получает сети (а не утекает в клирнет). Сверено с каноном (Tor manual
+ pf.conf(5), verify-first).

**ТРИ реальных бага velo, вскрытых ТОЛЬКО живым прогоном (структурная проверка их пропускала — вот почему
item 7 не закрывался все прошлые сессии):**
1. **torrc без `User _tor`** → rc стартует tor как root, без директивы он root'ом и остаётся → его egress НЕ
   покрыт правилом `pass out user _tor` → `block all` его рубит → tor не бутстрапится → L3 = кирпич.
2. **torrc без `DataDirectory /var/tor`** → tor (старт root'ом) берёт default `~/.tor` = `/root/.tor`, потом
   дропается в `_tor`, который туда не может → `Couldn't access private data directory` → tor вообще не стартует.
3. **Бутовая загрузка `/etc/pf.conf` недетерминирована.** `/etc/rc` грузит pf.conf сразу после `wait_reorder_libs`
   (relink библиотек); на медленной/деградированной ФС загрузка иногда НЕ вступает в силу → остаётся раннебутовый
   МИНИМАЛЬНЫЙ ruleset, а он **пускает DNS наружу для всех (утечка) и душит Tor** (general TCP закрыт). Наблюдалось
   живьём (1 бут из ~4). Корень — гонка вокруг relink (вероятно усугублён затёртой тест-ФС `/usr` full); полностью
   изолировать не удалось. Фикс как ИНВАРИАНТ безопасности (как Tails/Whonix): `install.site.velo` дописывает в
   `/etc/rc.local` переутверждение `pfctl -f /etc/pf.conf` (идемпотентно, retry, LOUD при провале) — `/etc/rc`
   сорсит rc.local в самом конце бута, когда система устаканилась.

**+ best-anonymity hardening (по Ворота-4):** torrc `SafeSocks 1` (форсит Tor-side DNS, режет SOCKS4/bare-IP
утечки; torsocks по hostname работает), `SocksPolicy accept 127.0.0.1/32`+`reject *`, `ClientOnly 1`.

**Изменения (исходники velo, КОММИТ без push):** `site/etc/velo/pf/pf.l3.conf` (S-набор), `site/etc/tor/torrc`
(User _tor + DataDirectory + hardening), `site/install.site.velo` (rc.local-инвариант + комменты под SOCKS),
`tests/site-validate.ksh` (L3-ассерты переписаны под S: нет rdr/divert, pass out _tor, SafeSocks/ClientOnly,
SOCKS не на 0.0.0.0, rc.local re-assert), `docs/m2-design.md`+`m3-design.md`+`m3-runbook.md` (L3-acceptance под
SOCKS-only). *(Запись обрывается — артефакт реконструкции истории при аварии 2026-06-14.)*

### Сессия — 2026-06-14 (post-recovery: восстановление покрытия + security-аудит установщика)
**Контекст:** после аварии `git filter-repo` (см. `docs/RECOVERY-2026-06-14.md`) дерево
восстановлено, но часть тестов из несохранённой Grok-сессии (homely-рефактор) потеряна
(velo-install-test 235 vs 257, site-validate 119 vs 124). Эта сессия добивает пробел
**по логике авторитетного `velo-install`** (извлечён из образа, точный), плюс ревью.

**Сделано:**
1. **Восстановлено homely-покрытие** (`tests/velo-install-test.ksh`): секция 12b —
   unit-тесты `velo_profile_target_size_ok` (homely ≥28 GiB, граница, нечитаемый label,
   bypass minimal/fortress); 12c — поведенческий гейт в `velo_execute` (цель <28 GiB
   отклоняется до confirm/crypto).
2. **Security-аудит `src/velo-install`** (read-only субагент). Найден 1 реальный баг:
   Wi-Fi SSID валидировал `"`/`\`, но НЕ newline, а PSK — никак. Newline в SSID/PSK
   расщеплял `answers`/`hostname.iwm0` (инъекция второй директивы). Остальное —
   безопасно/by-design (guard-ordering чист, device-имена квотированы, секреты не текут).
3. **Фикс:** добавлен `valid_wifi_value` (non-empty, no `"`/`\`/newline), применён к SSID
   и PSK в `_wiz_wifi`. Вынесена чистая `velo_answers_body` (тело `answers` на stdout,
   тестируемо) + write-site guard на `wifi_ssid` (закрывает env-preseed bypass).
4. **check-pkg-closure**: +T10–T13 (compound/flavored stem `py3-gobject3-3.46.0p0`,
   fail-closed на битом `+CONTENTS`, happy-path `--exact`). 11→16.
5. **Дедуп:** удалены задвоенные реплеем блоки ассертов (scrub ×2; rc.local/torrc ×2).
6. **Доки:** README (репо на GitHub, не «локальный»), HANDOFF/SESSION-PLAN/RECOVERY
   (актуальные числа), Wi-Fi PSK долг помечен ЗАКРЫТЫМ (`hostname.iwm0` — чистый template).
7. **terminal-профиль:** НЕ реализован (граница «не добавлять до Sprint-planing»
   соблюдена) — написана дизайн-спека `docs/terminal-profile-proposal.md`.

**Проверка (bash; oksh 64-бит — аналогично):** selftest 104 · velo-install-test **261** ·
site-validate **115** · integrity 27 · check-pkg-closure **16**. Парсится bash+ksh.

**Коммиты (push в ветку `claude/remote-phone-computer-access-68f68g`):** size-gate restore,
dedup+README, wifi-фикс, доки, PSK-долг, terminal-proposal, answers_body, closure-tests.

**Что осталось (нужно железо/KVM — НЕ в облаке):** homely VGA-приёмка кириллицы +
supervised metal re-test на внешнем SSD.

### Сессия — 2026-06-14 (homely VGA/визуальная приёмка кириллицы — ✅ ЗАКРЫТА, локально/KVM)
**Контекст:** хвост прошлой сессии — VGA-приёмка homely на живом KVM (qemu, `homely-test-target.img`,
28 GiB FDE). Запускалось автономно по «делай всё»; push НЕ делался.

**Сделано / находки (root-cause перед фиксом — [[feedback-verify-first]]):**
1. **Прогнал `vm/homely-vga-accept.py`** на установленном FDE-образе. Скрипт отдал «PASS», но
   глаза по screendump'ам: #2 xenodm-greeter рисуется идеально (графика/X работают), #3 openbox+tint2
   ок, **#4 «xterm с кириллицей» — пустой рабочий стол, окна нет**. «PASS» был **ложно-зелёным**:
   скрипт проверял только serial-факты (процессы, байты файла), пиксели не инспектировал.
2. **Диагностика (`vm/homely-font-diag.py`):** опроверг первую гипотезу о «нет шрифта» —
   DejaVu Sans Mono **есть** в base (`/usr/X11R6/.../DejaVuSansMono.ttf`, есть кириллица), плюс
   полный Noto Sans Mono. НО: **base-xterm собран без Xft** (`ldd … | grep xft` пуст) → опция
   `-fa`/`XTerm*faceName` в `.Xdefaults` им **игнорируется** (только core-шрифты). Это не причина
   пустого окна — лишь мёртвая строка конфига.
3. **Настоящий root-cause (`vm/homely-term-probe.py`):** запуск GUI делался
   `su {USER} -s /bin/sh -c {script} &`. На **OpenBSD `su` флаг `-c` = login-class, НЕ команда**
   (как на Linux). Скрипт-аргумент съедался как «класс», стартовал интерактивный шелл, читал EOF и
   выходил — приложение не запускалось (`[1] + Done`/`Stopped (tty input)`), окно не появлялось.
   Правильно: команда — **трейлинг-аргумент**: `su -l -s /bin/sh {USER} {script} </dev/null …`.
4. **Доказано вживую (`term-3-xterm.png`):** с верным `su` **и terminator, и xterm рисуют
   «Привіт / Привет»** (укр.+рус. кириллица), `xwininfo` подтвердил оба окна замапленными.
5. **Продуктовый баг (terminator):** в его stderr `Unable to load configuration … First error at
   line 24`. `site/etc/skel/.config/terminator/config` **дублировал** `[[[window0]]]`/`[[[child1]]]`
   в `[layouts][[default]]` → ConfigObj падает, terminator стартует на дефолтах (кастомный шрифт/тема
   не применялись). **Фикс:** убран дублирующий блок (commit `6ce49bb`).
6. **Фикс харнесса** (`vm/homely-vga-accept.py`, в gitignored `/vm/` — НЕ в git): корректная
   OpenBSD-форма `su`, `-u8` для xterm, + **честная проверка `XTERM_WINDOW_MAPPED` через `xwininfo`**
   (чтобы «PASS» больше не был пустым). Канонический повторный прогон — `[PASS] XTERM_WINDOW_MAPPED`,
   `vga-accept-4-xterm-cyrillic.png` показывает окно «VGA-Accept» с «Привіт / Привет».

**Проверка:**
- VGA-приёмка (canonical) — **PASS (rc=0)**, все 9 проверок зелёные, кириллица в xterm видна глазами.
- terminator-конфиг — верифицирован тем же парсером, что у terminator: `configobj 5.0.8`
  (исправленный парсится OK, исходный → `DuplicateError @ line 24`). Без перезагрузки ВМ.

**Коммиты (локально, БЕЗ push):** `6ce49bb` fix(homely) terminator-конфиг. Правка харнесса —
в `/vm/` (gitignored по конвенции репо), на диске для будущих прогонов.

**Что осталось:** ⬜ **supervised metal re-test** на внешнем SSD (Ворота-СТОП, при Антоне) —
инсталляторная дуга закрыта, это последнее физическое подтверждение. Опц. долг: косметика
`.Xdefaults XTerm*faceName` (мёртв на base-xterm без Xft; кириллица всё равно идёт через core+`-u8`).
