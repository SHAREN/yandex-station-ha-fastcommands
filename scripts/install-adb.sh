#!/usr/bin/env sh
set -eu

usage() {
    echo "Usage: $0 <adb-serial> <home-assistant-base-url> [station-name] [webhook-id]" >&2
    echo "Example: $0 192.168.1.50:5555 http://192.168.1.10:8123 bedroom" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage

SERIAL=$1
HA_URL=${2%/}
STATION_NAME=${3:-Yandex Station}
WEBHOOK_ID=${4:-}
VERSION=${VERSION:-latest}
REPO=SHAREN/yandex-station-ha-fastcommands
REMOTE_ROOT=/data/opt/alice-ha-fastcommands
REMOTE_INIT=/etc/init.d/S99zzalice-ha-fastcommands
PACKAGE=alice-ha-fastcommands-linux-arm64.tar.gz
OK_MARKER=__ALICE_HA_REMOTE_OK__
FAIL_MARKER=__ALICE_HA_REMOTE_FAIL__

command -v adb >/dev/null 2>&1 || { echo "adb is required on this computer" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required on this computer" >&2; exit 1; }

if command -v curl >/dev/null 2>&1; then
    download() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    download() { wget -q -O "$2" "$1"; }
else
    echo "curl or wget is required on this computer" >&2
    exit 1
fi

adb_shell_checked() {
    command_text=$1
    if ! output=$(adb -s "$SERIAL" shell "if { $command_text; }; then echo $OK_MARKER; else echo $FAIL_MARKER; fi" 2>&1); then
        echo "$output" >&2
        echo "adb shell transport failed: $command_text" >&2
        return 1
    fi

    printf '%s\n' "$output" | grep -v -e "$OK_MARKER" -e "$FAIL_MARKER" || true
    case "$output" in
        *"$FAIL_MARKER"*)
            echo "remote command failed: $command_text" >&2
            return 1
            ;;
        *"$OK_MARKER"*) return 0 ;;
        *)
            echo "remote command returned no status marker: $command_text" >&2
            return 1
            ;;
    esac
}

if [ -z "$WEBHOOK_ID" ]; then
    WEBHOOK_ID=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
fi

if [ "$VERSION" = "latest" ]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

download "$BASE/$PACKAGE" "$TMP/$PACKAGE"
download "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"
(
    cd "$TMP"
    grep "  $PACKAGE$" SHA256SUMS | sha256sum -c -
)

mkdir "$TMP/package"
tar -xzf "$TMP/$PACKAGE" -C "$TMP/package"

adb connect "$SERIAL" >/dev/null
ROOT_ID=$(adb -s "$SERIAL" shell id 2>&1)
case "$ROOT_ID" in
    *'uid=0(root)'*) ;;
    *) echo "Root ADB is required. Received: $ROOT_ID" >&2; exit 1 ;;
esac

adb_shell_checked "mkdir -p $REMOTE_ROOT && chmod 700 $REMOTE_ROOT"
adb -s "$SERIAL" push "$TMP/package/alice-ha-fastcommands" "$REMOTE_ROOT/alice-ha-fastcommands" >/dev/null
adb -s "$SERIAL" push "$TMP/package/S99zzalice-ha-fastcommands" "$REMOTE_ROOT/S99zzalice-ha-fastcommands" >/dev/null
adb_shell_checked "chmod 700 $REMOTE_ROOT/alice-ha-fastcommands $REMOTE_ROOT/S99zzalice-ha-fastcommands"

CONFIG_PROBE=$(adb -s "$SERIAL" shell "if [ -f $REMOTE_ROOT/config.json ]; then echo __ALICE_HA_CONFIG_EXISTS__; else echo __ALICE_HA_CONFIG_MISSING__; fi" 2>&1)
case "$CONFIG_PROBE" in
    *__ALICE_HA_CONFIG_EXISTS__*)
        echo "Keeping existing $REMOTE_ROOT/config.json"
        WROTE_CONFIG=0
        ;;
    *__ALICE_HA_CONFIG_MISSING__*)
        python3 - "$TMP/config.json" "$STATION_NAME" "$HA_URL" "$WEBHOOK_ID" <<'PY'
import json, sys
path, station, base, webhook_id = sys.argv[1:]
config = {
    "station": station,
    "aliced_addr": "127.0.0.1:9875",
    "webhook_url": base.rstrip("/") + "/api/webhook/" + webhook_id,
    "cancel_native_dialog": True,
    "debounce_ms": 1200,
    "allowed_commands": ["включи свет", "выключи свет"],
    "log_file": "/data/opt/alice-ha-fastcommands/fastcommands.log",
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
        adb -s "$SERIAL" push "$TMP/config.json" "$REMOTE_ROOT/config.json" >/dev/null
        adb_shell_checked "chmod 600 $REMOTE_ROOT/config.json"
        WROTE_CONFIG=1
        ;;
    *)
        echo "$CONFIG_PROBE" >&2
        echo "Remote configuration probe returned no marker" >&2
        exit 1
        ;;
esac

adb_shell_checked "mount -o remount,rw / || exit 1; cp $REMOTE_ROOT/S99zzalice-ha-fastcommands $REMOTE_INIT || { mount -o remount,ro /; exit 1; }; chmod 755 $REMOTE_INIT || { mount -o remount,ro /; exit 1; }; sync; mount -o remount,ro /"
adb_shell_checked "$REMOTE_ROOT/alice-ha-fastcommands --self-test"
adb_shell_checked "$REMOTE_ROOT/alice-ha-fastcommands -config $REMOTE_ROOT/config.json --probe"
adb_shell_checked "$REMOTE_INIT restart"
adb_shell_checked "$REMOTE_INIT status"

echo "Installed successfully."
echo "Blueprint: https://github.com/$REPO/blob/main/blueprints/automation/yandex_station_fastcommands.yaml"
if [ "$WROTE_CONFIG" = "1" ]; then
    echo "Webhook ID for the Home Assistant Blueprint: $WEBHOOK_ID"
fi
echo "Log: $REMOTE_ROOT/fastcommands.log"
