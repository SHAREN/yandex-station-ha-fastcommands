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

### 1. Home Assistant

Импортируйте Blueprint:

`https://github.com/SHAREN/yandex-station-ha-fastcommands/blob/main/blueprints/automation/yandex_station_fastcommands.yaml`

Создайте automation из Blueprint и задайте:

- уникальный случайный **Webhook ID**;
- фразу включения (по умолчанию `включи свет`);
- фразу выключения (по умолчанию `выключи свет`);
- любые действия Home Assistant для каждой фразы.

Webhook в Blueprint создаётся с `local_only: true` и принимает только `POST`.

### 2. Установка на рутированную Станцию

Запустите от `root` на самой Станции:

```sh
wget -q -O /tmp/install-alice-ha-fastcommands.sh \
  https://raw.githubusercontent.com/SHAREN/yandex-station-ha-fastcommands/main/scripts/install.sh
sh /tmp/install-alice-ha-fastcommands.sh
```

Installer скачивает ARM64 release, проверяет SHA256 и встроенный self-test, кладёт программу в `/data/opt/alice-ha-fastcommands` и устанавливает отдельный init-скрипт. Существующий `config.json` при обновлении не перезаписывается.

### 3. Настройка bridge

При первой установке появится:

```text
/data/opt/alice-ha-fastcommands/config.json
```

Измените минимум `station` и `webhook_url`:

```json
{
  "station": "bedroom",
  "aliced_addr": "127.0.0.1:9875",
  "webhook_url": "http://homeassistant.local:8123/api/webhook/YOUR_RANDOM_WEBHOOK_ID",
  "cancel_native_dialog": true,
  "debounce_ms": 1200,
  "allowed_commands": [
    "включи свет",
    "выключи свет"
  ],
  "log_file": "/data/opt/alice-ha-fastcommands/fastcommands.log"
}
```

После этого:

```sh
/data/opt/alice-ha-fastcommands/alice-ha-fastcommands \
  -config /data/opt/alice-ha-fastcommands/config.json --probe
/etc/init.d/S99zzalice-ha-fastcommands start
/etc/init.d/S99zzalice-ha-fastcommands status
```

Теперь произнесите рядом со Станцией **«включи свет»**, не говоря «Алиса».

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

Скачать и выполнить uninstaller:

```sh
wget -q -O /tmp/uninstall-alice-ha-fastcommands.sh \
  https://raw.githubusercontent.com/SHAREN/yandex-station-ha-fastcommands/main/scripts/uninstall.sh
sh /tmp/uninstall-alice-ha-fastcommands.sh
```

По умолчанию config и логи сохраняются. Для полного удаления:

```sh
PURGE=1 sh /tmp/uninstall-alice-ha-fastcommands.sh
```

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
