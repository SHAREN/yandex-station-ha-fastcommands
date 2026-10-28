# Protocol notes

This document describes only the small subset of local Quasar IPC used by this project. It is not a complete schema and may change across firmware versions.

## Transport

The tested `aliced` endpoint listens on loopback TCP port `9875`. Each frame is:

1. 4-byte little-endian signed payload length.
2. protobuf payload of that length.

The bridge enforces a 10 MiB frame limit and reconnects when the local service restarts.

## Command event

On the tested `yandexmicro` firmware, a short locally spotted command is found through these protobuf field paths:

```text
QuasarMessage field 3
  └─ state field 10
      └─ source field 6 = "command"
  └─ state field 15
      ├─ request field 1 = transcript
      └─ request field 2 != 0
```

The bridge ignores the event unless the source is exactly `command`, then normalizes the transcript and checks it against `allowed_commands`.

Some Quasar IPC variants wrap a message in an envelope with body field `252` and message-kind field `253`; the decoder unwraps that envelope before reading the command fields.

## Native dialog cancellation

When `cancel_native_dialog` is enabled, the bridge sends a fixed local remoting request to the same `aliced` endpoint:

```text
QuasarMessage.remoting (kind 210)
  └─ capability = "AliceCapability"
  └─ method = CANCEL_DIALOG (3)
```

No arbitrary local control frames are accepted from Home Assistant or from the network.

## Home Assistant payload

For an accepted command the bridge sends an HTTP `POST` with `Content-Type: application/json`:

```json
{
  "station": "bedroom",
  "command": "включи свет",
  "source": "command",
  "timestamp": "2026-10-29T00:00:00Z"
}
```

The supplied Blueprint reads `trigger.json.command` and dispatches the user-configured actions.
