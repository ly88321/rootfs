#!/bin/bash

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TOOLS_DIR/utils.sh"

SRC_BIN="$TOOLS_DIR/rootfs_tools/build/bin/rootfs"
DST_BIN="$TOOLS_DIR/rootfs"

ensure_rootfs_tool() {
    if [ ! -f "$DST_BIN" ] || [ "$SRC_BIN" -nt "$DST_BIN" ]; then
        log INFO "Building rootfs tools..."

        make -C "$TOOLS_DIR/rootfs_tools"
        if [ $? -ne 0 ]; then
            log ERROR "make failed!"
            exit 1
        fi

        cp "$SRC_BIN" "$DST_BIN"
        if [ $? -ne 0 ]; then
            log ERROR "Failed to copy rootfs binary!"
            exit 1
        fi

        log INFO "rootfs tools built successfully."
    fi

    if [ ! -f "$DST_BIN" ]; then
        log ERROR "Compile rootfs fail!"
        exit 1
    fi
}

clean_rootfs_tool() {
    log INFO "Clean build tools"
    make -C "$TOOLS_DIR/rootfs_tools" clean
    if [ $? -ne 0 ]; then
        log ERROR "Clean rootfs tools fail!"
        exit 1
    fi

    if [ -f "$DST_BIN" ]; then
        rm -f "$DST_BIN"
    fi
}
