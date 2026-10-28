#!/bin/sh
set -eu

REPO=SHAREN/yandex-station-ha-fastcommands
ROOT=/data/opt/alice-ha-fastcommands
INIT=/etc/init.d/S99zzalice-ha-fastcommands
VERSION=${VERSION:-latest}
ROOT_RW=0
INSTALL_STATUS=1

if [ "$(id -u)" != "0" ]; then
    echo "Run this installer as root on the Yandex Station." >&2
    exit 1
fi

case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
        echo "Unsupported architecture: $(uname -m). This release currently ships ARM64 only." >&2
        exit 1
        ;;
esac

download() {
    url=$1
    output=$2
    rm -f "$output"

    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL "$url" -o "$output" && [ -s "$output" ]; then
            return 0
        fi
        rm -f "$output"
    fi

    if command -v wget >/dev/null 2>&1; then
        if wget -q -O "$output" "$url" 2>/dev/null && [ -s "$output" ]; then
            return 0
        fi
        rm -f "$output"
    fi

    echo "No working HTTPS downloader was found on the Station." >&2
    echo "Use scripts/install-adb.ps1 (Windows) or scripts/install-adb.sh (Linux/macOS/WSL) from a computer instead." >&2
    return 1
}

if [ "$VERSION" = "latest" ]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

TMP="$ROOT/.install-tmp"
PACKAGE=alice-ha-fastcommands-linux-arm64.tar.gz
rm -rf "$TMP"
mkdir -p "$TMP"
chmod 700 "$TMP"

cleanup() {
    trap - EXIT HUP INT TERM
    if [ "$ROOT_RW" = "1" ]; then
        sync
        mount -o remount,ro / >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
    exit "$INSTALL_STATUS"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

download "$BASE/$PACKAGE" "$TMP/$PACKAGE"
download "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"
(
    cd "$TMP"
    grep "  $PACKAGE$" SHA256SUMS | sha256sum -c -
)

tar -xzf "$TMP/$PACKAGE" -C "$TMP"
"$TMP/alice-ha-fastcommands" --self-test

mkdir -p "$ROOT"
chmod 700 "$ROOT"
cp "$TMP/alice-ha-fastcommands" "$ROOT/alice-ha-fastcommands"
cp "$TMP/S99zzalice-ha-fastcommands" "$ROOT/S99zzalice-ha-fastcommands"
chmod 700 "$ROOT/alice-ha-fastcommands" "$ROOT/S99zzalice-ha-fastcommands"

if [ ! -f "$ROOT/config.json" ]; then
    cp "$TMP/config.example.json" "$ROOT/config.json"
    chmod 600 "$ROOT/config.json"
    echo "Created $ROOT/config.json from the example. Edit webhook_url before starting the service."
else
    chmod 600 "$ROOT/config.json"
    echo "Keeping existing $ROOT/config.json"
fi

mount -o remount,rw /
ROOT_RW=1
cp "$TMP/S99zzalice-ha-fastcommands" "$INIT"
chmod 755 "$INIT"
sync
mount -o remount,ro /
ROOT_RW=0

if grep -q 'CHANGE_ME_TO_A_RANDOM_ID' "$ROOT/config.json"; then
    echo "Installed, but not started: configure webhook_url in $ROOT/config.json first."
    echo "Then run: $INIT start"
    INSTALL_STATUS=0
    exit 0
fi

"$ROOT/alice-ha-fastcommands" -config "$ROOT/config.json" --probe
"$INIT" restart
"$INIT" status

echo "Installed successfully. Log: $ROOT/fastcommands.log"
INSTALL_STATUS=0
