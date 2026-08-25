# Laser Tag

Командный лазерный шутер для Roblox в стиле **Lego + Roblox + CS2**.
A team laser-tag FPS for Roblox in a **Lego + Roblox + CS2** style.

Весь проект — это код: карты, интерфейс и модели оружия строятся скриптами при запуске.
Никаких `.rbxm`-ассетов, никакого ручного редактирования в Studio — `rojo build` собирает готовое место.

Everything here is code: maps, UI and weapon models are all built by scripts at runtime.
No `.rbxm` assets, no manual Studio editing — `rojo build` produces a complete place.

---

## Об игре / About the game

Готов к вызову? Эта игра проверит твою ловкость и реакцию.

Две команды — **Alpha** (зелёные) и **Bravo** (розовые) — сражаются **10 минут** в режиме
Team Deathmatch. Побеждает команда, набравшая больше убийств. Между матчами все игроки находятся
в **хабе**, где можно выбрать карту, зайти в магазин, сменить скин или крутануть колесо наград.

Two teams — **Alpha** (green) and **Bravo** (pink) — fight a **10-minute** team deathmatch.
The team with more kills wins. Between matches everyone waits in the **hub**, where they pick a map,
visit the shop, change a skin or spin the reward wheel.

### Карты / Maps

| Карта | Стиль | Расположение |
|---|---|---|
| **Dust** | Песчаная арена в пустынном стиле | симметричная, три линии атаки |
| **Mirage** | Неоновая арена: фиолетовые стены, белый кант, зелёные комнаты | симметричная, узкие коридоры |

Каждая карта симметрична, полностью закрыта и имеет две защищённые комнаты спавна с
односторонними энергетическими дверями: своя команда проходит насквозь, чужая упирается в барьер.

### Оружие / Weapons

| Оружие | Режим | Урон | Магазин | Перезарядка | Характер |
|---|---|---|---|---|---|
| **Pulse Rifle** | автоматический, 600 в/мин | 22 (голова ×2) | 30 | 2.2 с | спрей как в CS2: подъём → снос вправо → снос влево |
| **Ion Pistol** | полуавтоматический | 34 (голова ×1.75) | 12 | 1.4 с | почти вертикальная отдача, сильный первый выстрел |

Отдача **детерминированная**: одинаковый номер выстрела всегда даёт одинаковый толчок камеры, поэтому
паттерн можно выучить и «прожимать» вниз, как в CS2. При этом разброс, который влияет на попадание,
считает **сервер** — он растёт, пока вы удерживаете спуск, и сбрасывается, если сделать паузу.
Поэтому стрельба короткими очередями точнее, чем непрерывный спрей.

Recoil is **deterministic** — the same shot index always kicks the camera the same way, so the
pattern is learnable. The spread that actually decides whether you hit is computed by the **server**,
grows while you hold the trigger and resets when you pause: tapping beats spraying at range.

### Экономика / Economy

- Убийство — **+25** монет, в голову — **+35**.
- Победа в матче — **+150**, участие — **+50**, ничья — **+75**.
- Магазин продаёт **только косметику** — цвета и узоры лазера. Никакого pay-to-win в PvP.
- Колесо наград: бесплатный прокрут раз в 20 часов, дополнительный — 300 монет.
  **Все шансы выпадения показаны в интерфейсе**, плюс защита от невезения: после 10 прокрутов
  без скина следующий гарантированно даст скин.

---

## Управление / Controls

### Компьютер / PC

| Действие | Клавиша |
|---|---|
| Передвижение | **W, A, S, D** |
| Прыжок | **Пробел** |
| Поворот камеры | Движение мышью |
| Стрелять | **Левая кнопка мыши** (удерживать для автомата) |
| Перезарядка | **R** |
| Смена оружия | **1** / **2** |
| Экипировка | **E** |
| Магазин | **Q** |
| Друзья | **F** |
| Колесо наград | **P** |
| Освободить курсор | **Right Ctrl** |

### Телефон / Mobile

- Джойстик слева и кнопки на экране — передвижение
- Зажать и двигать в правой части экрана — вращение камерой
- Кнопка выстрела справа — стрельба; рядом кнопки перезарядки и смены оружия
- Меню открываются касанием кнопок слева

---

## Архитектура / Architecture

```
src/shared/     ReplicatedStorage.Shared — общий контракт клиента и сервера
  Constants, Types, RemoteNames        константы, типы, имена remote-ов
  Config/                              WeaponConfig, SprayPatterns, GameConfig,
                                       EconomyConfig, SkinCatalog, SpinConfig
  Util/                                TableUtil, MathUtil, Signal, Trove
  MapDefs/                             декларативные описания карт (Hub, Dust, Mirage)
  GunModelFactory                      программная сборка моделей оружия
  Loader                               двухпроходная загрузка модулей: init() → start()

src/server/     ServerScriptService.Server
  Net/          Remotes, RateLimiter, RateLimiterCore, Validators
  Services/     DataService, TeamService, WorldService, PlayerService,
                QueueService, MatchService, CombatService,
                ShopService, SpinService, FriendsService, LeaderboardService
  Match/        MatchStateMachine (чистая FSM), MatchRuntime
  Combat/       DamageCalc, ShootValidation, WeaponState
  Economy/      ShopLogic, SpinLogic
  World/        MapBuilder, LightingSetup, SpawnDoors
  Vendor/       ProfileService (MIT, вендорено)

src/client/     StarterPlayer.StarterPlayerScripts.Client
  ClientState                          единое хранилище состояния клиента + сигналы
  Controllers/                         Input, MouseLock, Camera, CharacterVisuals,
                                       Viewmodel, Recoil, WeaponClient, VFX,
                                       Spectator, MobileControls
  UI/                                  UIController, UITheme, Components/, Screens/

tests/          юнит-тесты чистых модулей, запускаются вне Roblox через Luau CLI
```

### Принципы / Design rules

- **Сервер решает всё.** Клиент отправляет намерение выстрела, сервер заново трассирует луч от
  известной ему позиции игрока, применяет собственный разброс и только тогда наносит урон.
  Монеты, скины и счёт матча существуют только на сервере.
- **Валидация каждого remote:** проверка типов (и запрет лишних аргументов), кулдаун по скорострельности,
  проверка живости и дистанции, защита от повторов по номеру выстрела, ограничение частоты запросов
  с киком за систематические нарушения.
- **Без утечек памяти:** каждое подключение события живёт в `Trove` и очищается при выходе игрока
  или смерти персонажа.
- **Никаких зависаний:** тела модулей и `init()` не блокируются; всё ожидание — в `start()`,
  `WaitForChild` всегда с таймаутом.
- **Чистые модули:** логика спрея, урона, магазина, колеса, лимитера и описания карт не используют
  Roblox API и покрыты тестами, которые гоняются вне Roblox.

---

## Сборка / Building

Нужен [Aftman](https://github.com/LPGhatguy/aftman) (версии инструментов закреплены в `aftman.toml`):

```bash
aftman install                                  # rojo, selene, stylua
rojo build default.project.json -o LaserTag.rbxlx
```

Полная проверка перед коммитом:

```bash
stylua --check src/ tests/     # форматирование
selene src/ tests/             # линт (использует lasertag.yml, сеть не нужна)
luau tests/run.luau            # юнит-тесты чистых модулей
rojo build default.project.json -o /tmp/check.rbxlx
```

`luau` — CLI из [luau-lang/luau](https://github.com/luau-lang/luau).
Те же четыре шага выполняет GitHub Actions (`.github/workflows/ci.yml`).

### Разработка вживую / Live sync

```bash
rojo serve
```

Затем в Roblox Studio: плагин Rojo → **Connect**. Изменения в файлах попадают в Studio сразу.

---

## Публикация в Roblox / Publishing

1. Соберите место: `rojo build default.project.json -o LaserTag.rbxlx`.
2. Откройте `LaserTag.rbxlx` в Roblox Studio.
3. **File → Publish to Roblox As...**, создайте новый опыт.
4. **Home → Game Settings → Security** → включите **Enable Studio Access to API Services**.
   Без этого не работают DataStore: не сохранятся монеты, скины и глобальная таблица TOP KILLS.
5. **Game Settings → Permissions** → сделайте опыт публичным, когда будете готовы.

### Проверка перед публикацией / Smoke test

В Studio: **Test → Clients and Servers → 2 players → Start**.

- [ ] Оба игрока появляются в хабе, видна панель монет и кнопки слева
- [ ] В хабе видна доска **TOP KILLS**
- [ ] Оба встали на пад портала `Dust` → пошёл отсчёт → телепорт на карту, команды разные
- [ ] Стрельба: луч, вспышка, отдача поднимает камеру, счётчик патронов уменьшается
- [ ] Перезарядка по **R**, смена оружия **1**/**2**
- [ ] Попадание по своему не наносит урона, по чужому — наносит и попадает в килл-фид
- [ ] После смерти — камера смерти и респавн через 3 секунды в своей комнате
- [ ] Таймер идёт от 10:00, счёт команд растёт
- [ ] По окончании матча — экран результатов и возврат в хаб
- [ ] Магазин: покупка скина списывает монеты; после перезахода скин на месте (нужен пункт 4 выше)

---

## Лицензии / Licenses

Код проекта — см. [LICENSE](LICENSE).
[ProfileService](https://github.com/MadStudioRoblox/ProfileService) — MIT, см.
`src/server/Vendor/ProfileService-LICENSE.txt`.
