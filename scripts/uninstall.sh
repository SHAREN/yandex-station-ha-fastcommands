#!/bin/sh
set -eu

ROOT=/data/opt/alice-ha-fastcommands
INIT=/etc/init.d/S99zzalice-ha-fastcommands

if [ "$(id -u)" != "0" ]; then
    echo "Run this uninstaller as root on the Yandex Station." >&2
    exit 1
fi

if [ -x "$INIT" ]; then
    "$INIT" stop || true
fi

restore_ro() {
    sync
    mount -o remount,ro / >/dev/null 2>&1 || true
}

mount -o remount,rw /
trap 'restore_ro' EXIT HUP INT TERM
rm -f "$INIT"
restore_ro
trap - EXIT HUP INT TERM

if [ "${PURGE:-0}" = "1" ]; then
    rm -rf "$ROOT"
    echo "Removed service and data directory."
else
    echo "Removed autostart. Configuration and logs remain in $ROOT"
    echo "Run with PURGE=1 to remove the data directory too."
fi
