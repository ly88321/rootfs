#!/bin/bash

. utils.sh

SRC_BIN="rootfs_tools/build/bin/rootfs"
DST_BIN="./rootfs"

if [ ! -f "$DST_BIN" ] || [ "$SRC_BIN" -nt "$DST_BIN" ]; then
    log INFO "Building rootfs tools..."

    make -C rootfs_tools
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
