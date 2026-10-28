# yandex-station-ha-fastcommands

Локальный мост из штатных **быстрых команд Яндекс Станции** в Home Assistant.

Он предназначен для рутированных Станций, где `aliced` публикует локальные события command spotter. Фразы вроде **«включи свет»** и **«выключи свет»** можно произносить **без слова «Алиса»**: Станция распознаёт короткую команду своим штатным локальным spotter'ом, а этот bridge перехватывает событие и вызывает LAN-only webhook Home Assistant.

> **Статус:** experimental. Проверено на Яндекс Станции Лайт 1 (`yandexmicro`), ARM64, firmware `0.369.1.46.4778262442.20261013.297`. Другие модели и прошивки пока считаются непроверенными.

## Что это даёт

```text
микрофоны станции
      ↓
штатный Yandex VQE / command spotter
      ↓
локальный aliced IPC (127.0.0.1:9875)
      ↓
alice-ha-fastcommands
      ↓ HTTP POST, LAN
Home Assistant webhook
      ↓
любые HA actions
```

Для этого пути не нужны Whisper, SpeechKit, Gemini или токен Home Assistant. Bridge не записывает аудио и не отправляет аудиопоток наружу. В Home Assistant уходит только совпавшая короткая команда, имя станции и timestamp.

## Важное ограничение

`allowed_commands` — это **фильтр**, а не обучение распознавателя. Новая строка в config не добавляет новую фразу в локальную модель Яндекса. Работать могут только те короткие команды, которые уже умеет распознавать command spotter конкретной прошивки.

## Быстрый старт

### 1. Установка с компьютера по root ADB

Это основной способ установки: release скачивается **на компьютер**, поэтому Станции не нужен HTTPS-клиент. Некоторые прошивки имеют BusyBox `wget` без поддержки HTTPS.

#### Windows PowerShell

```powershell
Invoke-WebRequest `
  https://raw.githubusercontent.com/SHAREN/yandex-station-ha-fastcommands/main/scripts/install-adb.ps1 `
  -OutFile "$env:TEMP\install-alice-ha-fastcommands.ps1"

powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-alice-ha-fastcommands.ps1" `
  -Serial 192.168.1.50:5555 `
  -HomeAssistantUrl http://192.168.1.10:8123 `
  -StationName bedroom
```

#### Linux / macOS / WSL

```sh
curl -fsSL \
  https://raw.githubusercontent.com/SHAREN/yandex-station-ha-fastcommands/main/scripts/install-adb.sh \
  -o /tmp/install-alice-ha-fastcommands.sh
chmod +x /tmp/install-alice-ha-fastcommands.sh
/tmp/install-alice-ha-fastcommands.sh \
  192.168.1.50:5555 \
  http://192.168.1.10:8123 \
  bedroom
```

Installer скачивает ARM64 release, проверяет SHA256, проверяет root ADB, запускает self-test и IPC probe, устанавливает bridge и автозапуск. При первой установке он также генерирует случайный **Webhook ID** и выводит его в конце. Существующий `config.json` при обновлении сохраняется.

### 2. Home Assistant

Импортируйте Blueprint:

`https://github.com/SHAREN/yandex-station-ha-fastcommands/blob/main/blueprints/automation/yandex_station_fastcommands.yaml`

Создайте automation из Blueprint и вставьте **Webhook ID**, который вывел installer. Затем выберите:

- фразу включения (по умолчанию `включи свет`);
- фразу выключения (по умолчанию `выключи свет`);
- любые действия Home Assistant для каждой фразы.

Webhook в Blueprint создаётся с `local_only: true` и принимает только `POST`.

Если хотите заранее выбрать Webhook ID сами, передайте его installer'у параметром `-WebhookId` в PowerShell или четвёртым аргументом в `install-adb.sh`.

### 3. Проверка

```sh
/etc/init.d/S99zzalice-ha-fastcommands status
tail -n 50 /data/opt/alice-ha-fastcommands/fastcommands.log
```

Теперь произнесите рядом со Станцией **«включи свет»**, не говоря «Алиса».

### Установка прямо со Станции

`scripts/install.sh` тоже поддерживается, но только если на самой Станции есть HTTPS-capable `curl` или `wget`. На части прошивок штатный BusyBox `wget` HTTPS не поддерживает, поэтому ADB installer выше считается рекомендуемым вариантом.

## Диагностика

```sh
/data/opt/alice-ha-fastcommands/alice-ha-fastcommands --self-test
/data/opt/alice-ha-fastcommands/alice-ha-fastcommands \
  -config /data/opt/alice-ha-fastcommands/config.json --probe
tail -n 50 /data/opt/alice-ha-fastcommands/fastcommands.log
```

Нормальный старт выглядит примерно так:

```text
start version=v0.x.x station="bedroom" aliced=127.0.0.1:9875 commands=2
aliced connected
HA webhook ok command="включи свет"
```

## `cancel_native_dialog`

По умолчанию после совпадения bridge отправляет локальному `aliced` фиксированную команду `CANCEL_DIALOG`, чтобы штатная Алиса не выполняла то же действие второй раз.

Это режим **Home Assistant first**: если Home Assistant недоступен, а `cancel_native_dialog=true`, штатный путь уже мог быть отменён. Если нужен fail-open в сторону штатной Алисы, установите `cancel_native_dialog=false`, но тогда возможно двойное выполнение при доступном интернете.

## Безопасность

Webhook Home Assistant не требует bearer token, поэтому Webhook ID нужно считать секретом: используйте уникальное непредсказуемое значение и не публикуйте свой реальный `config.json`. Blueprint оставляет webhook LAN-only.

Проект обрабатывает только локальные IPC-события с `source=command`. Обычная длинная речь (`source=voice`) игнорируется. В репозитории нет кода записи микрофона или отправки аудио.

Не используйте webhook такого типа для опасных действий вроде открытия замков, ворот или отключения защитных систем.

## Файлы на Станции

```text
/data/opt/alice-ha-fastcommands/alice-ha-fastcommands
/data/opt/alice-ha-fastcommands/config.json
/data/opt/alice-ha-fastcommands/fastcommands.log
/data/opt/alice-ha-fastcommands/alice-ha-fastcommands.pid
/etc/init.d/S99zzalice-ha-fastcommands
```

Bridge автоматически переподключается к `aliced`, поэтому безопасно стартует даже если локальный IPC ещё не готов во время загрузки системы.

## Удаление

С компьютера с ADB:

```sh
adb -s 192.168.1.50:5555 shell '/etc/init.d/S99zzalice-ha-fastcommands stop; mount -o remount,rw /; rm -f /etc/init.d/S99zzalice-ha-fastcommands; sync; mount -o remount,ro /'
```

После этого bridge больше не стартует, а config и логи остаются в `/data/opt/alice-ha-fastcommands`. Для полного удаления данных:

```sh
adb -s 192.168.1.50:5555 shell 'rm -rf /data/opt/alice-ha-fastcommands'
```

В репозитории также есть `scripts/uninstall.sh`, если на Станцию удобнее заранее передать готовый uninstaller через ADB/SSH.

## Сборка

```sh
go test ./...
go run . --self-test
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o alice-ha-fastcommands .
```

Теги `v*` автоматически создают GitHub Release с ARM64 tarball и `SHA256SUMS`.

## Совместимость и исследования

Реализация протокола написана отдельно для этого проекта по наблюдаемому поведению локального Quasar IPC и публичным техническим материалам сообщества. Полезные проекты для исследования рутированных Яндекс Станций: [Yandex Station Extended / HackAlice](https://github.com/Marker284/yandex-station-extended), [YAM](https://github.com/nyakokitsu/yam) и [Quasar Bridge](https://github.com/skrashevich/quasar-bridge).

Проект не связан с Яндексом или Home Assistant.

## License

MIT. См. [LICENSE](LICENSE).
