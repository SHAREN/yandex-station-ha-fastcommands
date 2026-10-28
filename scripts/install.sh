#!/bin/sh
set -eu

REPO=SHAREN/yandex-station-ha-fastcommands
ROOT=/data/opt/alice-ha-fastcommands
INIT=/etc/init.d/S99zzalice-ha-fastcommands
VERSION=${VERSION:-latest}

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

if [ "$VERSION" = "latest" ]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

TMP="$ROOT/.install.$$"
PACKAGE=alice-ha-fastcommands-linux-arm64.tar.gz
mkdir -p "$TMP"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

wget -q -O "$TMP/$PACKAGE" "$BASE/$PACKAGE"
wget -q -O "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"
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

restore_ro() {
    sync
    mount -o remount,ro / >/dev/null 2>&1 || true
}

mount -o remount,rw /
trap 'restore_ro; rm -rf "$TMP"' EXIT HUP INT TERM
cp "$TMP/S99zzalice-ha-fastcommands" "$INIT"
chmod 755 "$INIT"
restore_ro
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

if grep -q 'CHANGE_ME_TO_A_RANDOM_ID' "$ROOT/config.json"; then
    echo "Installed, but not started: configure webhook_url in $ROOT/config.json first."
    echo "Then run: $INIT start"
    exit 0
fi

"$ROOT/alice-ha-fastcommands" -config "$ROOT/config.json" --probe
"$INIT" restart
"$INIT" status

echo "Installed successfully. Log: $ROOT/fastcommands.log"
